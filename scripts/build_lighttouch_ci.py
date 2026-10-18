#!/usr/bin/env python3
"""Build the pinned LightTouch engine for an Apple SDK using a prebuilt UTM sysroot."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tarfile
import urllib.request

PINS = {
    "slirp": ("https://gitlab.freedesktop.org/slirp/libslirp/-/archive/v4.9.4/libslirp-v4.9.4.tar.gz", "3998863b020aeda34bddc567097c6efba55a78cdf6eeee6bcd42c11ef23967da", "libslirp-v4.9.4"),
    "ffmpeg": ("https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz", "cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635", "ffmpeg-9.0.1"),
}


def run(argv, cwd, env):
    print(shlex.join(map(str, argv)), flush=True)
    subprocess.run(list(map(str, argv)), cwd=cwd, env=env, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", required=True, choices=["macosx", "iphoneos", "xros"])
    parser.add_argument("--arch", default="arm64", choices=["arm64", "x86_64"])
    parser.add_argument("--sysroot", required=True, type=Path)
    parser.add_argument("--work", required=True, type=Path)
    parser.add_argument("--interpreter", action="store_true")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    work, sysroot = args.work.resolve(), args.sysroot.resolve()
    if work.exists():
        parser.error("work directory must be new")
    work.mkdir(parents=True)
    source, build, prefix = work / "qemu-ios", work / "qemu-build", work / "prefix"
    build.mkdir(); prefix.mkdir()
    env = os.environ.copy()
    run(["git", "init", source], work, env)
    run(["git", "remote", "add", "origin", "https://github.com/samhenrigold/qemu-ios.git"], source, env)
    run(["git", "fetch", "--depth=1", "origin", "2bd551a3b88d453e81e9a24d401a1cc7ec411690"], source, env)
    run(["git", "checkout", "--detach", "FETCH_HEAD"], source, env)
    sdk = subprocess.check_output(["xcrun", "--sdk", args.sdk, "--show-sdk-path"], text=True).strip()
    target = {"macosx": "macos14.4", "iphoneos": "ios15.0", "xros": "xros1.0"}[args.sdk]
    compiler = f"xcrun --sdk {args.sdk} clang -target {args.arch}-apple-{target} -isysroot {shlex.quote(sdk)}"
    cxx = compiler.replace(" clang ", " clang++ ")
    env.update(CC=compiler, CXX=cxx, OBJC=compiler,
               PKG_CONFIG_LIBDIR=f"{prefix}/lib/pkgconfig:{sysroot}/lib/pkgconfig", PKG_CONFIG_PATH="")
    # Relocate pkg-config metadata from upstream's artifact checkout path.
    for pc in (sysroot / "lib/pkgconfig").glob("*.pc"):
        text = pc.read_text()
        for line in text.splitlines():
            if line.startswith("prefix=") and line[7:].startswith("/"):
                text = text.replace(line[7:], str(sysroot))
                break
        pc.write_text(text)
    for name, (url, digest, directory) in PINS.items():
        archive = work / (name + ".tar")
        urllib.request.urlretrieve(url, archive)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
            raise RuntimeError("source checksum mismatch: " + name)
        with tarfile.open(archive) as data:
            data.extractall(work, filter="data")
    slirp = work / PINS["slirp"][2]
    run(["patch", "-p1", "-i", source / "subprojects/packagefiles/libslirp-set-restricted.patch"], slirp, env)
    cross = work / "target.meson"
    cross.write_text("\n".join([
        "[binaries]", "c = " + repr(shlex.split(compiler)), "cpp = " + repr(shlex.split(cxx)),
        "objc = " + repr(shlex.split(compiler)), "pkg-config = " + repr(shutil.which("pkg-config")),
        "[host_machine]", "system = 'darwin'", "cpu_family = " + repr("aarch64" if args.arch == "arm64" else "x86_64"),
        "cpu = " + repr(args.arch), "endian = 'little'", "[properties]", "needs_exe_wrapper = true", ""]))
    run(["meson", "setup", work / "slirp-build", slirp, "--cross-file", cross,
         "--prefix=" + str(prefix), "--buildtype=release", "-Ddefault_library=static", "--wrap-mode=nofallback"], work, env)
    run(["ninja", "-C", work / "slirp-build", "install"], work, env)
    ffmpeg = work / PINS["ffmpeg"][2]
    for patch in ["h264-chunk-er.patch", "h264-cavlc-pcm-offset.patch"]:
        run(["patch", "-p1", "-i", source / "contrib/ffmpeg" / patch], ffmpeg, env)
    flags = f"-target {args.arch}-apple-{target} -isysroot {shlex.quote(sdk)}"
    run([ffmpeg / "configure", "--prefix=" + str(prefix), "--enable-cross-compile", "--arch=" + ("aarch64" if args.arch == "arm64" else "x86_64"),
         "--target-os=darwin", "--cc=" + compiler, "--cxx=" + cxx,
         "--disable-everything", "--disable-autodetect", "--disable-programs", "--disable-doc",
         "--disable-avdevice", "--disable-avformat", "--disable-avfilter", "--disable-swscale", "--disable-swresample",
         "--enable-decoder=aac,mp3,alac,h264", "--enable-static", "--disable-shared", "--enable-pic",
         "--extra-cflags=" + flags, "--extra-ldflags=" + flags], ffmpeg, env)
    run(["make", "-j3"], ffmpeg, env)
    run(["make", "install"], ffmpeg, env)
    # An untracked device selection file keeps the pinned source unchanged.
    (source / "configs/devices/arm-softmmu/utm-mobile.mak").write_text(
        "CONFIG_IPOD_TOUCH_1G=y\nCONFIG_IPOD_TOUCH_2G=y\nCONFIG_IPAD1=y\nCONFIG_USB_EHCI=y\n")
    configure = [source / "configure", "--target-list=arm-softmmu", "--with-devices-arm=utm-mobile",
                 "--without-default-features", "--enable-pixman", "--enable-slirp", "--disable-pie", "--disable-hvf",
                 "--cc=" + compiler, "--cxx=" + cxx, "--objcc=" + compiler, "--host-cc=clang", "--cross-prefix=",
                 "--cpu=" + ("aarch64" if args.arch == "arm64" else "x86_64"),
                 f"--extra-cflags=-I{prefix}/include -I{sysroot}/include",
                 f"--extra-ldflags=-L{prefix}/lib -L{sysroot}/lib -lcrypto"]
    if args.interpreter:
        configure.append("--enable-tcg-interpreter")
    run(configure, build, env)
    run(["ninja", "-j3", "qemu-system-arm"], build, env)
    relink = ["python3", repo / "scripts/relink_lighttouch.py", source, build, work / "stage"]
    if args.interpreter:
        relink.append("--require-interpreter")
    run(relink, repo, env)
    run(["python3", repo / "scripts/package_lighttouch_runtime.py", work / "stage",
         "--library-root", sysroot / "lib", "--library-root", prefix / "lib", "--library-root", sysroot / "Frameworks"], repo, env)
    licenses = work / "stage/licenses"
    licenses.mkdir()
    shutil.copyfile(source / "COPYING", licenses / "QEMU-COPYING")
    shutil.copyfile(ffmpeg / "COPYING.LGPLv2.1", licenses / "FFmpeg-COPYING.LGPLv2.1")
    shutil.copyfile(slirp / "COPYRIGHT", licenses / "libslirp-COPYRIGHT")
    shutil.copyfile(repo / "Documentation/MobileGuests.sources.json", licenses / "sources.json")
    (licenses / "native-sources.json").write_text(json.dumps(PINS, indent=2))
    for patch in [source / "subprojects/packagefiles/libslirp-set-restricted.patch", *list((source / "contrib/ffmpeg").glob("*.patch"))]:
        shutil.copyfile(patch, licenses / patch.name)
    print("Built LightTouch stage:", work / "stage")


if __name__ == "__main__":
    main()

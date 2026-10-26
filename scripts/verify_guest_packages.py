#!/usr/bin/env python3
"""Validate installable guest editions and write their SHA256SUMS manifest."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import zipfile


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def fingerprint(bundle):
    return {str(path.relative_to(bundle)): ("link", os.readlink(path)) if path.is_symlink()
            else ("file", digest(path)) for path in bundle.rglob("*")
            if path.is_symlink() or path.is_file()}


def verify_ipa(path):
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise RuntimeError(f"Corrupt IPA: {path}")
        infos = [name for name in archive.namelist()
                 if name.startswith("Payload/") and name.count("/") == 2 and name.endswith(".app/Info.plist")]
        if len(infos) != 1:
            raise RuntimeError(f"Expected one app in {path}")
        app = infos[0].removesuffix("Info.plist")
        info = plistlib.loads(archive.read(infos[0]))
        for name in [app + info["CFBundleExecutable"], app + "Frameworks/LightTouchQEMU.framework/LightTouchQEMU"]:
            if archive.getinfo(name).file_size == 0:
                raise RuntimeError(f"Empty executable {name} in {path}")


def verify_mac_app(app, arch, reference):
    for binary in [app / "Contents/MacOS/UTM",
                   app / "Contents/Frameworks/LightTouchQEMU.framework/LightTouchQEMU"]:
        subprocess.run(["lipo", binary, "-verify_arch", arch], check=True)
    if not (app / "Contents/Frameworks/LightTouchQEMU.framework/Versions/Current/Resources/Info.plist").is_file():
        raise RuntimeError("Mac LightTouch framework is not versioned")
    subprocess.run(["codesign", "--verify", "--strict", app], check=True)
    if reference is not None:
        bundle = app / "Contents/Resources/VPhone.bundle"
        if fingerprint(bundle) != reference:
            raise RuntimeError("Packaging changed the signed VPhone.bundle")
        for name in ["vphone-cli", "vphone-vm"]:
            executable = bundle / "Contents/MacOS" / name
            if not os.access(executable, os.X_OK):
                raise RuntimeError(f"Missing vphone executable: {name}")
            subprocess.run(["codesign", "--verify", "--strict", executable], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("packages", type=Path)
    parser.add_argument("--arch", required=True, choices=["arm64", "x86_64"])
    parser.add_argument("--platform", required=True, choices=["macosx", "iphoneos", "xros"])
    parser.add_argument("--edition", required=True)
    parser.add_argument("--vphone-reference", default="")
    args = parser.parse_args()
    root = args.packages.resolve()
    files = sorted(path for path in root.rglob("*") if path.suffix in [".ipa", ".deb", ".dmg", ".zip"])
    required = {".dmg", ".zip"} if args.platform == "macosx" else {".ipa"}
    if args.platform == "iphoneos" and args.edition == "Full-TrollStore-JB":
        required.add(".deb")
    if not required.issubset({path.suffix for path in files}):
        raise RuntimeError(f"Missing packages: expected {sorted(required)}, found {files}")
    reference = fingerprint(Path(args.vphone_reference)) if args.vphone_reference else None
    if reference is not None and not reference:
        raise RuntimeError("Missing reference VPhone.bundle")
    for path in files:
        if path.suffix == ".ipa":
            verify_ipa(path)
        elif path.suffix == ".deb":
            subprocess.run(["dpkg-deb", "--info", path], check=True)
            with tempfile.TemporaryDirectory(prefix="utm-deb-check-") as directory:
                subprocess.run(["dpkg-deb", "--extract", path, directory], check=True)
                verify_ipa(Path(directory) / "var/tmp/com.utmapp.UTM/UTM.ipa")
        elif path.suffix == ".zip":
            with tempfile.TemporaryDirectory(prefix="utm-app-check-") as directory:
                subprocess.run(["ditto", "-x", "-k", path, directory], check=True)
                verify_mac_app(Path(directory) / "UTM.app", args.arch, reference)
        elif path.suffix == ".dmg":
            subprocess.run(["hdiutil", "verify", path], check=True)
            with tempfile.TemporaryDirectory(prefix="utm-dmg-check-") as directory:
                subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
                                "-mountpoint", directory, path], check=True)
                try:
                    verify_mac_app(Path(directory) / "UTM.app", args.arch, reference)
                finally:
                    subprocess.run(["hdiutil", "detach", directory], check=True)
    (root / "SHA256SUMS").write_text("".join(f"{digest(path)}  {path.relative_to(root)}\n" for path in files))
    print(f"Verified {len(files)} packages; SHA256SUMS written to {root}")


if __name__ == "__main__":
    main()

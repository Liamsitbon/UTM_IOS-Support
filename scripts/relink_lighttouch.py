#!/usr/bin/env python3
"""Relink an already configured qemu-ios build using its own Ninja commands.

Works with the compiler/SDK/TCI configuration in that build; it never substitutes
host headers or changes the configured accelerator. Dependencies must already be
built for that SDK. See Documentation/MobileGuests.md.
"""
import argparse
import hashlib
import json
import pathlib
import plistlib
import shlex
import subprocess

PIN = "2bd551a3b88d453e81e9a24d401a1cc7ec411690"
EXPORTS = ["qemu_ios_main", "qemu_ios_api_version", "qemu_ios_device_info_at",
           "qemu_ios_ui_ready", "qemu_ios_ui_frame", "qemu_ios_ui_touch",
           "qemu_ios_ui_button", "qemu_ios_ui_attach", "qemu_ios_ui_pause",
           "qemu_ios_ui_resume", "qemu_ios_ui_quit", "qemu_ios_set_foreground",
           "qemu_ios_utm_is_interpreter"]


def run(args, cwd):
    return subprocess.check_output(args, cwd=cwd, text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("build", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path, help="New staging directory (must not exist)")
    parser.add_argument("--require-interpreter", action="store_true")
    args = parser.parse_args()
    source, build, output = [p.resolve() for p in (args.source, args.build, args.output)]
    if run(["git", "rev-parse", "HEAD"], source).strip() != PIN:
        parser.error("qemu-ios checkout differs from the integration pin")
    diff = subprocess.check_output(["git", "diff", "HEAD", "--binary"], cwd=source)
    provenance = {}
    if diff:
        record = build / "utm-source.json"
        patch = pathlib.Path(__file__).resolve().parent.parent / "patches/lighttouch/qemu-ios-apple-gles.patch"
        if not record.is_file():
            parser.error("patched qemu-ios build has no source provenance record")
        provenance = json.loads(record.read_text())
        if provenance.get("diff_sha256") != hashlib.sha256(diff).hexdigest() or \
           provenance.get("patch_sha256") != hashlib.sha256(patch.read_bytes()).hexdigest():
            parser.error("qemu-ios modifications differ from the recorded portability patch")
    if output.exists():
        parser.error("choose a new output directory; existing artifacts are never overwritten")
    config = (build / "config-host.h").read_text()
    interpreter = "#define CONFIG_TCG_INTERPRETER 1" in config
    if args.require_interpreter and not interpreter:
        parser.error("this QEMU build uses JIT, not the TCG interpreter")
    subprocess.run(["ninja", "qemu-system-arm"], cwd=build, check=True)
    commands = [shlex.split(line) for line in run(["ninja", "-t", "commands", "qemu-system-arm-unsigned"], build).splitlines()]
    compile_main = next(c for c in commands if "-c" in c and any(v.endswith("system/main.c") for v in c))
    link = commands[-1]
    if not any(v.endswith("system_main.c.o") for v in link):
        parser.error("unrecognized QEMU link command (system/main.c object missing)")
    marker = build / "utm-lighttouch-interpreter.c"
    marker.write_text('''#include "qemu/osdep.h"
#include <stdbool.h>
bool qemu_ios_utm_is_interpreter(void);
bool qemu_ios_utm_is_interpreter(void) {
#ifdef CONFIG_TCG_INTERPRETER
    return true;
#else
    return false;
#endif
}
''')
    objects = []
    for path in [source / "contrib/ios-app/qemu-ios-entry.c", source / "contrib/ios-app/qemu-ios-ui.c",
                 source / "contrib/macos-app/qemu-macos-extras.c", marker]:
        command = list(compile_main)
        obj = "utm-" + path.stem + ".o"
        command[command.index("-o") + 1] = obj
        command[command.index("-c") + 1] = str(path)
        # Don't overwrite Ninja's original depfile or object bookkeeping.
        for flag in ["-MQ", "-MF"]:
            if flag in command:
                command[command.index(flag) + 1] = obj + (".d" if flag == "-MF" else "")
        # system/main.c has no CPU internals, so Meson does not give it the
        # target include paths. The UI adapter includes ARM CPU/page headers.
        command += ["-I" + str(build / "target/arm"), "-I" + str(source / "target/arm"),
                    "-I" + str(source / "contrib/ios-app"), "-I" + str(source / "contrib/macos-app")]
        subprocess.run(command, cwd=build, check=True)
        objects.append(obj)
    framework = output / "LightTouchQEMU.framework"
    framework.mkdir(parents=True)
    binary = framework / "LightTouchQEMU"
    exports = build / "utm-lighttouch.exports"
    exports.write_text("\n".join("_" + name for name in EXPORTS) + "\n")
    final = []
    skip = False
    for word in link:
        if skip:
            skip = False
            continue
        if word == "-o":
            skip = True
        elif word.endswith("system_main.c.o"):
            final += objects
        elif word.startswith("@") or word == "-pie":
            continue
        else:
            final.append(word)
    final += ["-dynamiclib", "-Wl,-headerpad_max_install_names", "-o", str(binary), "-install_name", "@rpath/LightTouchQEMU.framework/LightTouchQEMU",
              "-Wl,-exported_symbols_list," + str(exports)]
    subprocess.run(final, cwd=build, check=True)
    plist = {"CFBundleIdentifier": "com.utmapp.LightTouchQEMU", "CFBundleName": "LightTouchQEMU",
             "CFBundleExecutable": "LightTouchQEMU", "CFBundlePackageType": "FMWK",
             "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0"}
    platform_lines = run(["/usr/bin/vtool", "-show-build", str(binary)], build).splitlines()
    platform = next(line.split()[1] for line in platform_lines if line.strip().startswith("platform "))
    minimum = next(line.split()[1] for line in platform_lines if line.strip().startswith("minos "))
    names = {"MACOS": "MacOSX", "IOS": "iPhoneOS", "IOSSIMULATOR": "iPhoneSimulator",
             "VISIONOS": "XROS", "VISIONOSSIMULATOR": "XRSimulator"}
    plist["CFBundleSupportedPlatforms"] = [names[platform]]
    plist["LSMinimumSystemVersion" if platform == "MACOS" else "MinimumOSVersion"] = minimum
    (framework / "Info.plist").write_bytes(plistlib.dumps(plist))
    (output / "runtime.json").write_text(json.dumps({"source": PIN, "interpreter": interpreter, **provenance}, indent=2) + "\n")
    # These are build artifacts, not yet a distributable closure. Rejecting any
    # external load path is the embed step's responsibility.
    print(binary)


if __name__ == "__main__":
    main()

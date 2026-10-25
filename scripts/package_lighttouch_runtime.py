#!/usr/bin/env python3
"""Stage a LightTouch framework's native load closure without host paths.

Use only on a fresh relink_lighttouch.py output. Non-system dylibs are copied
into separately named sibling frameworks, then all load commands are rewritten.
"""
import argparse
import hashlib
import json
import pathlib
import plistlib
import shutil
import subprocess


def output(*args):
    return subprocess.check_output(args, text=True)


def version_macos_framework(framework):
    name = framework.stem
    version = framework / "Versions/A"
    resources = version / "Resources"
    resources.mkdir(parents=True)
    (framework / name).rename(version / name)
    (framework / "Info.plist").rename(resources / "Info.plist")
    (framework / "Versions/Current").symlink_to("A", target_is_directory=True)
    (framework / name).symlink_to("Versions/Current/" + name)
    (framework / "Resources").symlink_to("Versions/Current/Resources", target_is_directory=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", type=pathlib.Path)
    parser.add_argument("--library-root", type=pathlib.Path, action="append", default=[])
    args = parser.parse_args()
    stage = args.stage.resolve()
    engine = stage / "LightTouchQEMU.framework/LightTouchQEMU"
    if not engine.is_file():
        parser.error("not a relinked LightTouch stage")
    engine_plist = plistlib.loads((engine.parent / "Info.plist").read_bytes())
    platform_info = {key: engine_plist[key] for key in ["CFBundleSupportedPlatforms", "MinimumOSVersion", "LSMinimumSystemVersion"] if key in engine_plist}
    known = {str(engine): (engine, "@rpath/LightTouchQEMU.framework/LightTouchQEMU")}
    pending = [engine]
    records = []
    while pending:
        binary = pending.pop()
        lines = output("/usr/bin/otool", "-L", str(binary)).splitlines()[2:]
        for line in lines:
            dependency = line.strip().split(" (", 1)[0]
            if dependency.startswith(("/System/Library/", "/usr/lib/")):
                continue
            if dependency not in known:
                origin = pathlib.Path(dependency)
                if not origin.is_file():
                    choices = []
                    for root in args.library_root:
                        choices += [root / origin.name, root / dependency.removeprefix("@rpath/")]
                    origin = next((p for p in choices if p.is_file()), origin)
                if not origin.is_file():
                    parser.error("missing dependency: " + dependency)
                origin = origin.resolve()
                digest = hashlib.sha256(origin.read_bytes()).hexdigest()
                name = "LTM_" + origin.name.removesuffix(".dylib").replace(".", "_").replace("-", "_")
                framework = stage / (name + ".framework")
                if framework.exists():
                    parser.error("dependency framework collision: " + name)
                framework.mkdir()
                copied = framework / name
                shutil.copyfile(origin, copied)
                copied.chmod(0o755)
                install_name = "@rpath/" + name + ".framework/" + name
                subprocess.run(["/usr/bin/install_name_tool", "-id", install_name, str(copied)], check=True)
                (framework / "Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleIdentifier": "com.utmapp.lighttouch." + name.replace("_", "-"),
                    "CFBundleExecutable": name, "CFBundlePackageType": "FMWK",
                    "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0", **platform_info}))
                known[dependency] = (copied, install_name)
                pending.append(copied)
                records.append({"origin": str(origin), "sha256": digest, "framework": name})
            subprocess.run(["/usr/bin/install_name_tool", "-change", dependency, known[dependency][1], str(binary)], check=True)
    if platform_info.get("CFBundleSupportedPlatforms") == ["MacOSX"]:
        for framework in sorted({binary.parent for binary, _ in known.values()}):
            version_macos_framework(framework)
    for binary, _ in known.values():
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(binary.parent)], check=True)
    path = stage / "runtime.json"
    manifest = json.loads(path.read_text())
    manifest["dependencies"] = records
    path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(stage)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Exercise real Mac framework closure packaging, signatures and embedding."""
from pathlib import Path
import json
import os
import plistlib
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[2]
for arch in ["arm64", "x86_64"]:
    with tempfile.TemporaryDirectory(prefix="utm-frameworks-") as directory:
        root = Path(directory)
        stage = root / "stage"
        framework = stage / "LightTouchQEMU.framework"
        framework.mkdir(parents=True)
        dependency = root / "libfixture.dylib"
        (root / "dependency.c").write_text("int fixture_value(void) { return 42; }\n")
        (root / "engine.c").write_text("extern int fixture_value(void); int engine_value(void) { return fixture_value(); }\n")
        compiler = ["xcrun", "clang", "-dynamiclib", "-target", arch + "-apple-macos12.0",
                    "-Wl,-headerpad_max_install_names"]
        subprocess.run([*compiler, root / "dependency.c", "-install_name", dependency,
                        "-o", dependency], check=True)
        subprocess.run([*compiler, root / "engine.c", dependency,
                        "-install_name", "@rpath/LightTouchQEMU.framework/LightTouchQEMU",
                        "-o", framework / "LightTouchQEMU"], check=True)
        (framework / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "LightTouchQEMU", "CFBundleIdentifier": "org.utm.fixture",
            "CFBundlePackageType": "FMWK", "CFBundleVersion": "1",
            "CFBundleSupportedPlatforms": ["MacOSX"], "LSMinimumSystemVersion": "12.0"}))
        (stage / "runtime.json").write_text(json.dumps({"interpreter": False}))
        subprocess.run(["python3", repo / "scripts/package_lighttouch_runtime.py", stage], check=True)
        frameworks = sorted(stage.glob("*.framework"))
        assert len(frameworks) == 2
        for item in frameworks:
            assert not (item / "Info.plist").exists()
            assert (item / "Versions/Current").readlink() == Path("A")
            assert (item / "Resources/Info.plist").is_file()
            assert (item / item.stem).is_symlink()
            assert (item / item.stem).is_file()
            subprocess.run(["codesign", "--verify", "--strict", item], check=True)
        loads = subprocess.check_output(["otool", "-L", framework / "LightTouchQEMU"], text=True)
        assert "@rpath/LTM_libfixture.framework/LTM_libfixture" in loads
        assert str(dependency) not in loads
        environment = dict(os.environ, SRCROOT=str(repo), SYSROOT_DIR="unused",
                           LTM_RUNTIME_DIR=str(stage), LTM_REQUIRED="1", ARCHS=arch,
                           PLATFORM_NAME="macosx", CODE_SIGNING_ALLOWED="NO",
                           TARGET_BUILD_DIR=str(root / "products"),
                           FRAMEWORKS_FOLDER_PATH="UTM.app/Contents/Frameworks")
        subprocess.run(["sh", repo / "scripts/embed_lighttouch.sh"], env=environment, check=True)
        copied = root / "products/UTM.app/Contents/Frameworks/LightTouchQEMU.framework"
        assert (copied / "Versions/Current/Resources/Info.plist").is_file()
print("Mac arm64/x86_64 framework closure, signature and embedding checks passed")

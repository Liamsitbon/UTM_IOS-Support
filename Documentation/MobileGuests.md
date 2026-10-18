# Experimental mobile guests

This branch starts from UTM main `535d6592` (5.0.8). Source commits are pinned in
[MobileGuests.sources.json](MobileGuests.sources.json). The upstream USB feature
branch is 231 commits behind main and is not used as the base; LightTouch's
`parked/ipad-3g` branch is parked. Experimental features are not selected by
replacing current UTM with an older branch.

## Implemented paths

Create a VM and choose **iPhone, iPod touch and iPad (Experimental)** in the OS
picker. The same SwiftUI entry is compiled into macOS, iOS, iOS-SE and iOS-Remote,
including their visionOS builds. TrollStore and jailbroken distributions use the
iOS adapter, with the existing UTM JIT admission check. This does not introduce
new signing, installation or host-security changes.

LightTouch runs the separate qemu-ios engine in a background thread, with a BGRA
display, normalized single-touch input, Home/Power, pause/resume and stop. It
uses LightTouch's actual prepared-device boot recipes and supported board table
from the loaded engine. A prepared base (an unpacked firmwarekit device with
`device.lock.json`) and matching boot ROM are selected through file pickers.
UTM owns a separate writable NOR/overlay and storage lease; original base images
are not overwritten. A generation change refuses overlay reuse. Networking and
audio playback are currently disabled in this adapter. IPA installation,
firmware preparation inside UTM, multitouch and the LightTouch services helper
are not integrated. Prepare firmware using upstream firmwarekit on a Mac first.
No firmware, keys, prepared NAND or boot ROM is included in this fork.

On iOS, QEMU and LightTouch share a one-launch-per-process exclusion gate; reopen
UTM before changing guests. Backgrounding pauses LightTouch and disables its
host GL executor. SE accepts only a runtime whose compiled interpreter marker is
true; a JIT engine is refused before launch, even if incorrectly staged in a SE
sysroot. This uses QEMU's ordinary TCG interpreter, not UTM's custom TCTI patch.

On Apple Silicon macOS 15+, the vphone adapter launches an existing machine using
a user-selected complete `VPhone.bundle` and VM library. Arguments are passed as
an array, and the original CLI performs its own host preflight. Display/input
are in vphone's own native window, not UTM's SPICE/Virtualization display. This is
a CLI integration, not a new `UTMAppleVirtualMachine` implementation. The adapter
does not install helpers, alter SIP/boot-args or arrange private-entitlement
admission. A refused launch writes a log under UTM's MobileGuests directory.

On every other host, including TrollStore/JB iOS, a read-only dynamic probe checks
for `VZVirtualMachine` and `_VZMacHardwareModelDescriptor`. Missing runtime classes
are reported. Even if both classes exist, a native vphone VM service/display
port is still required; the probe does not claim guest support. QEMU HVF access
and vphone's PV=3 Research Guests are different capabilities. Local vphone guest
execution on iOS/visionOS has **not** been implemented or demonstrated.

## Building the engine

UTM's ordinary QEMU sysroot cannot supply LightTouch's boards/API. Build the
pinned **qemu-ios** checkout with its patched dependencies for each host SDK.
The source already includes an EAGL executor for iOS. Use its documented native
build/vendor recipes as the reference. No prebuilt iOS engine is included here.
QEMU configure rejects source/build paths containing spaces: use a separate
scratch checkout in such a path, keeping the pinned source unchanged.

Configure `arm-softmmu` with the desired SDK and existing platform dependencies.
For SE, add `--enable-tcg-interpreter`; disable HVF and other JIT-only engines.
The matching patched libslirp is needed even for the restricted guest netdev;
stock libslirp is insufficient. The patched FFmpeg described by upstream is
needed for the full hardware video decoder. Cross-compiled dependencies must
match the target SDK; Homebrew host libraries are not iOS libraries.

After QEMU has been configured and built:

```sh
python3 scripts/relink_lighttouch.py /path/to/qemu-ios /path/to/qemu-build /new/staging-dir
# For SE, additionally pass --require-interpreter above.
python3 scripts/package_lighttouch_runtime.py /new/staging-dir
```

The relinker reuses Ninja's real compile/link commands, preserves its compiler,
SDK and interpreter setting, replaces QEMU's standalone main with the upstream
embedding entry and adds a compiled interpreter marker. It packages C API 2.x
as `LightTouchQEMU.framework`. The second script copies non-system dependencies
into uniquely named sibling frameworks and rewrites their load commands. An
unresolved `@rpath` dependency is an error; use a fully resolved build closure.
Distributable builds must also retain the corresponding dependency licenses and
source records. Do not treat a host-linked probe engine as an installable IPA.

Place the staging directory at `${SYSROOT_DIR}/LightTouch` for each existing UTM
sysroot, or set `LTM_RUNTIME_DIR` to the staging path. The Xcode embed phase checks
the Mach-O SDK, architecture, dependency closure and SE interpreter metadata,
then copies/signs the frameworks. Set `LTM_REQUIRED=1` to fail a build if the
runtime is missing. Without staging, ordinary UTM still builds and the new UI
reports that the engine is absent. No startup is simulated.

## Validation and remaining gates

```sh
swift test --package-path Packages/UTMMobileGuestKit -j 2
swift run --package-path Packages/UTMMobileGuestKit utm-mobile-guest-probe --host
swift run --package-path Packages/UTMMobileGuestKit utm-mobile-guest-probe /path/to/LightTouchQEMU
# Add --require-interpreter to exercise SE admission.
```

Tests cover storage exclusion, immutable base NOR, overlay generation mismatch,
and rejection of JIT/old-ABI engines by the actual C loader in child processes.
The adapter can be compiled independently with an iOS or visionOS SDK. These are
source/adapter checks, not proof of a complete UTM build, valid distribution,
firmware boot, rendered frames, audio or real-device input. Those require the
matching built engines, prepared firmware and physical host tests. The existing
UTM native-dependency sysroots remain required for a full app build.

## GitHub Actions

`Build Experimental iOS Guests` runs on every push to
`codex/ios-support-experimental` and can also be started with Run workflow.
It builds eight app targets independently (fail-fast is off) and publishes
LightTouch engine archives, UTM xcarchives, IPAs and JB DEBs. Mac arm64 also
builds the pinned VPhone.bundle and includes it in the app's Resources.
Build logs are uploaded even on failure. No Release or external distribution
is created. Guest firmware is not downloaded or booted by this workflow.

UTM native dependencies come from upstream run `38996133972`, built from the
exact UTM base commit above, via the `Sysroot-*` artifacts. Only the modified
LightTouch dependency and its patched libslirp/FFmpeg are built from source.
If upstream artifacts expire or cross-repository artifact access is refused,
the download step fails explicitly; restore matching sysroots before rerunning.
The hosted runner builds vphone but cannot establish physical-Mac guest boot
support. iOS vphone remains the runtime-capability probe described above.

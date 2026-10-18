# Source provenance

LightTouchHostRuntime is vendored from:
https://github.com/samhenrigold/LightTouchMac/tree/d34c3dc7a0870c82ac43241e1ded7c6105e76e44/Packages/HostRuntime/Sources/HostRuntime

License: GPL-2.0-or-later, reproduced in LightTouch-LICENSE.

Local portability changes: helper-process enumeration is macOS-only in
DeviceInfo.swift; NSLock-backed UTMPortableLock replaces OSAllocatedUnfairLock
in PipeOutput.swift, Storage/HeldLease.swift and Storage/StorageLease.swift for
macOS 12 and iOS 15 support. No upstream firmware patch is changed.

CMobileGuest/include/qemu-ios-ui.h is copied unchanged from:
https://github.com/samhenrigold/qemu-ios/blob/2bd551a3b88d453e81e9a24d401a1cc7ec411690/contrib/ios-app/qemu-ios-ui.h

The C bridge binds API 2.x. qemu-ios is QEMU 11.0.3; it must remain a separate
runtime from UTM's QEMU 10.0.12 engine. A standard UTM sysroot is not a substitute.

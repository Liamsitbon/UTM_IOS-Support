import XCTest
import Foundation
import LightTouchHostRuntime
@testable import UTMMobileGuestKit

final class MobileGuestTests: XCTestCase {
    func testOwnershipAllowsSameBackendAndRejectsSwitchingEngines() async throws {
        try await MainActor.run {
            try MobileGuestProcessOwnership.claim("QEMU")
            try MobileGuestProcessOwnership.claim("QEMU")
            XCTAssertThrowsError(try MobileGuestProcessOwnership.claim("LightTouch"))
        }
    }

    func testLeaseExcludesAnotherWriterAndPreservesInode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("lease")
        let first = try StorageLease(path)
        XCTAssertThrowsError(try StorageLease(path))
        first.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        let second = try StorageLease(path)
        second.close()
    }

    func testOverlayCannotBeReusedForDifferentPreparedGeneration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(try PreparedDeviceBoot.pinOverlay(root, toBase: "first"))
        XCTAssertTrue(try PreparedDeviceBoot.pinOverlay(root, toBase: "first"))
        XCTAssertFalse(try PreparedDeviceBoot.pinOverlay(root, toBase: "replacement"))
    }

    func testPreparedNORIsPrivateAndBaseRemainsUnmodified() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("base")
        let overlay = root.appendingPathComponent("work/overlay")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("nand"), withIntermediateDirectories: true)
        let original = Data(repeating: 0x42, count: 1_048_576)
        try original.write(to: base.appendingPathComponent("nor.bin"))
        try Data([0]).write(to: base.appendingPathComponent("iBoot.bin"))
        try Data([0]).write(to: base.appendingPathComponent("gid-blobs.bin"))
        let privateNOR = root.appendingPathComponent("work/nor.bin")
        _ = try PreparedDeviceBoot.prepare(board: .n72, base: base, overlay: overlay,
                                          writableNOR: privateNOR, storageKey: "fixture", bootrom: "/fixture/rom")
        try Data([0x11]).write(to: privateNOR)
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent("nor.bin")), original)
    }

    #if os(macOS)
    func testSERejectsJITAndAcceptsInterpreterMarker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("engine.c")
        try """
        #include <stdbool.h>
        #include <stdint.h>
        uint32_t qemu_ios_api_version(void) { return API_VERSION; }
        bool qemu_ios_utm_is_interpreter(void) { return INTERPRETER; }
        int qemu_ios_main(int n, char **v) { return 0; }
        void *qemu_ios_device_info_at(int n) { return 0; }
        bool qemu_ios_ui_ready(void) { return false; }
        bool qemu_ios_ui_frame(void *a, void *b, void *c, void *d) { return false; }
        void qemu_ios_ui_touch(int a, int b, double c, double d) {}
        void qemu_ios_ui_button(int a, bool b) {}
        void qemu_ios_ui_attach(void *a, void *b) {}
        void qemu_ios_ui_pause(void) {}
        void qemu_ios_ui_resume(void) {}
        void qemu_ios_ui_quit(void) {}
        void qemu_ios_set_foreground(bool active) {}
        """.write(to: source, atomically: true, encoding: .utf8)
        let probe = Bundle(for: MobileGuestTests.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("utm-mobile-guest-probe")
        for (interpreter, version, expected) in [(0, 131072, 1), (1, 131072, 0), (1, 65536, 1)] {
            let dylib = root.appendingPathComponent("engine-\(interpreter)-\(version).dylib")
            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            compiler.arguments = ["clang", "-dynamiclib", "-DINTERPRETER=\(interpreter)", "-DAPI_VERSION=\(version)", source.path, "-o", dylib.path]
            try compiler.run(); compiler.waitUntilExit()
            XCTAssertEqual(compiler.terminationStatus, 0)
            let process = Process()
            process.executableURL = probe
            process.arguments = [dylib.path, "--require-interpreter"]
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, Int32(expected))
        }
    }
    #endif
}

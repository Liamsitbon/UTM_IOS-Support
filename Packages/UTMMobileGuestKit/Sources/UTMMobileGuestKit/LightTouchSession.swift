import Foundation
import CoreGraphics
import CryptoKit
import CMobileGuest
import LightTouchHostRuntime

public enum MobileGuestError: LocalizedError {
    case unavailable(String)
    public var errorDescription: String? {
        switch self { case .unavailable(let reason): return reason }
    }
}

@MainActor public final class LightTouchSession: ObservableObject {
    @Published public private(set) var image: CGImage?
    @Published public private(set) var status = "Choose a prepared LightTouch device."
    @Published public private(set) var isRunning = false
    @Published public private(set) var isPaused = false
    @Published public private(set) var hasStarted = false
    private static var processUsed = false
    private var serial: UInt64 = 0
    private var timer: Timer?
    private var lease: StorageLease?
    private var scopedURLs: [URL] = []
    private var hardware: [DeviceInfo] = []
    private var loaded = false
    private var worker: Thread?

    public static let shared = LightTouchSession()
    private init() {}

    public func loadEngine(requireInterpreter: Bool) throws {
        guard !loaded else { return }
        guard !Self.processUsed else {
            throw MobileGuestError.unavailable("Reopen UTM before starting another LightTouch device.")
        }
        let frameworks = Bundle.main.privateFrameworksURL ?? Bundle.main.bundleURL.appendingPathComponent("Frameworks")
        let library = frameworks.appendingPathComponent("LightTouchQEMU.framework/LightTouchQEMU")
        guard FileManager.default.fileExists(atPath: library.path) else {
            throw MobileGuestError.unavailable("This build does not include the LightTouch engine for this platform. See Documentation/MobileGuests.md.")
        }
        if let failure = utm_ltm_load(library.path, requireInterpreter) {
            throw MobileGuestError.unavailable(String(cString: failure))
        }
        var index: Int32 = 0
        while let pointer = utm_ltm_machine(index) {
            let d = pointer.pointee
            hardware.append(DeviceInfo(
                machine: String(cString: d.machine), board: String(cString: d.board),
                screenWidth: Int(d.screen_width), screenHeight: Int(d.screen_height),
                screenScale: Int(d.screen_scale), defaultOrientation: Int(d.default_orientation),
                hasCellular: d.has_cellular, hasUSBHost: d.has_usb_host, hasCompass: d.has_compass,
                panelMin: Int(d.panel_min), panelMaxWidth: Int(d.panel_max_width),
                panelMaxHeight: Int(d.panel_max_height), panelWidthStep: Int(d.panel_width_step),
                panelMaxPixels: Int(d.panel_max_pixels)))
            index += 1
        }
        loaded = true
    }

    public func start(base: URL, bootROM: URL, work: URL, requireInterpreter: Bool) throws {
        guard !Self.processUsed else {
            throw MobileGuestError.unavailable("QEMU can start only once per process. Reopen UTM first.")
        }
        try loadEngine(requireInterpreter: requireInterpreter)
        for url in [base, bootROM] where url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
        do {
            guard let record = try DeviceLock.read(base: base), let id = record.board,
                  let board = Board(rawValue: id), let device = hardware.first(where: { $0.board == id }) else {
                throw MobileGuestError.unavailable("Choose an unpacked firmwarekit device with a supported device.lock.json.")
            }
            guard FileManager.default.fileExists(atPath: bootROM.path) else { throw CocoaError(.fileNoSuchFile) }
            lease = try StorageLease(work.appendingPathComponent("lease"))
            let prepared = try PreparedDeviceBoot.prepare(
                board: board, base: base, overlay: work.appendingPathComponent("overlay"),
                writableNOR: work.appendingPathComponent("nor.bin"), storageKey: SHA256.hash(data: try Data(contentsOf: base.appendingPathComponent(DeviceLock.fileName))).map { String(format: "%02x", $0) }.joined(),
                bootrom: bootROM.path)
            var config = try prepared.configuration(
                hardware: device, bootArgs: "amfi_allow_any_signature=1 cs_enforcement_disable=1", usbAddress: nil, wifi: false,
                guestPackage: nil, serial: "file:\(work.appendingPathComponent("serial.log").path)",
                audio: ["-audiodev", "none,id=audio0"],
                netdev: "user,id=wifi0,restrict=on,lan=off")
            config.argv += ["-accel", "tcg"]
            for (key, value) in config.environment { setenv(key, value, 1) }
            let arguments = config.argv
            #if !os(macOS)
            try MobileGuestProcessOwnership.claim("LightTouch")
            #endif
            Self.processUsed = true
            hasStarted = true
            isRunning = true
            status = "Starting \(board.facts.marketingName)…"
            worker = Thread { [self] in
                var argv = arguments.map { strdup($0) }
                argv.append(nil)
                defer { for pointer in argv { free(pointer) } }
                let result = utm_ltm_run(Int32(arguments.count), &argv)
                Task { @MainActor in self.didExit(result) }
            }
            worker?.name = "UTM LightTouch QEMU"
            worker?.stackSize = 8 * 1024 * 1024
            worker?.start()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        } catch {
            releaseStorage()
            throw error
        }
    }

    private func refresh() {
        guard isRunning else { return }
        if utm_ltm_ready() { status = isPaused ? "Paused" : "Running" }
        var pixels: UnsafeRawPointer?
        var width: Int32 = 0, height: Int32 = 0
        guard utm_ltm_frame(&pixels, &width, &height, &serial), let pixels,
              width > 0, height > 0, width <= 8192, height <= 8192 else { return }
        let count = Int(width) * Int(height) * 4
        let data = Data(bytes: pixels, count: count)
        guard let provider = CGDataProvider(data: data as CFData) else { return }
        image = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: Int(width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public func touch(phase: Int32, x: Double, y: Double) {
        utm_ltm_touch(phase, min(1, max(0, x)), min(1, max(0, y)))
    }
    public func button(_ button: Int32, down: Bool) { utm_ltm_button(button, down) }
    public func setPaused(_ paused: Bool) { utm_ltm_pause(paused); isPaused = paused }
    public func stop() { status = "Stopping…"; utm_ltm_quit() }
    private func didExit(_ code: Int32) {
        timer?.invalidate(); timer = nil
        isRunning = false; isPaused = false
        status = "LightTouch exited (\(code)). Reopen UTM to start another device."
        releaseStorage()
    }
    private func releaseStorage() {
        lease?.close(); lease = nil
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }; scopedURLs = []
    }
}

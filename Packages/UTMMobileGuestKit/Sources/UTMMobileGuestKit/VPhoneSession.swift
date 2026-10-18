import Foundation
import Darwin

public struct VPhoneHostReport: Equatable {
    public let hasVirtualizationFramework: Bool
    public let hasResearchDescriptor: Bool
    public let reason: String

    public static func inspect() -> Self {
        let framework = dlopen("/System/Library/Frameworks/Virtualization.framework/Virtualization", RTLD_LAZY | RTLD_LOCAL)
        // Keep the framework loaded: Objective-C classes cannot be safely unloaded.
        let hasFramework = framework != nil && NSClassFromString("VZVirtualMachine") != nil
        let hasResearch = hasFramework && NSClassFromString("_VZMacHardwareModelDescriptor") != nil
        #if os(macOS) && arch(arm64)
        let reason: String
        if #available(macOS 15, *) {
            reason = hasResearch ? "Select a VPhone.bundle and an existing VM library. vphone's own host preflight will check Research Guests and the VM executable's admission before launch." : "This host has no vphone Research Guest descriptor."
        } else {
            reason = "vphone requires macOS 15 or newer."
        }
        #else
        let reason = hasResearch
            ? "Research Guest classes were found. This platform still needs a native vphone VM service and display port; hypervisor access alone does not provide them."
            : "This host does not expose the Virtualization.framework Research Guest runtime used by vphone. TrollStore/JB signing and hypervisor access alone do not supply that runtime."
        #endif
        return Self(hasVirtualizationFramework: hasFramework, hasResearchDescriptor: hasResearch, reason: reason)
    }
}

@MainActor public final class VPhoneSession: ObservableObject {
    @Published public private(set) var status = VPhoneHostReport.inspect().reason
    @Published public private(set) var isRunning = false
    #if os(macOS)
    private var process: Process?
    private var scopedURLs: [URL] = []
    private var executable: URL?
    private var library: URL?
    private var name: String?
    #endif

    public static let shared = VPhoneSession()
    private init() {}

    public func launch(bundle: URL, library: URL, name: String) throws {
        #if os(macOS) && arch(arm64)
        guard #available(macOS 15, *) else { throw MobileGuestError.unavailable("vphone requires macOS 15 or newer.") }
        guard !isRunning, !name.isEmpty, !name.hasPrefix("-"), !name.contains("/"), name != ".", name != ".." else {
            throw MobileGuestError.unavailable("Choose a valid existing VM name.")
        }
        let executable = bundle.appendingPathComponent("Contents/MacOS/vphone-cli")
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.isExecutableFile(atPath: bundle.appendingPathComponent("Contents/MacOS/vphone-vm").path) else {
            throw MobileGuestError.unavailable("Choose the complete VPhone.bundle, including vphone-cli and vphone-vm.")
        }
        for url in [bundle, library] where url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
        do {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["vm", "launch", "--library-root", library.path, "--", name]
            // Stream to a file rather than a bounded pipe: a running guest writes serial output continuously.
            let logs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("UTM/MobileGuests", isDirectory: true)
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let log = logs.appendingPathComponent("vphone-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            process.standardOutput = output
            process.standardError = output
            process.terminationHandler = { [weak self] finished in
                try? output.close()
                let code = finished.terminationStatus
                Task { @MainActor in
                    self?.isRunning = false
                    self?.status = "vphone exited (\(code)). Log: \(log.path)"
                    self?.releaseStorage()
                }
            }
            try process.run()
            self.process = process
            self.executable = executable
            self.library = library
            self.name = name
            isRunning = true
            status = "vphone is starting. Its native VM window opens separately. Log: \(log.path)"
        } catch {
            releaseStorage()
            throw error
        }
        #else
        throw MobileGuestError.unavailable(VPhoneHostReport.inspect().reason)
        #endif
    }

    public func stop() throws {
        #if os(macOS)
        guard isRunning, let executable, let library, let name else { return }
        let stop = Process()
        stop.executableURL = executable
        stop.arguments = ["vm", "stop", "--library-root", library.path, "--", name]
        try stop.run()
        status = "Requesting vphone shutdown…"
        #endif
    }

    #if os(macOS)
    private func releaseStorage() {
        process = nil
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }; scopedURLs = []
    }
    #endif
}

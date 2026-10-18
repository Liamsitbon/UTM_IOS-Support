import SwiftUI
import UniformTypeIdentifiers

public struct MobileGuestView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var lightTouch = LightTouchSession.shared
    @StateObject private var vphone = VPhoneSession.shared
    @State private var picker: Selection?
    @State private var isChoosingFile = false
    @State private var base: URL?
    @State private var bootROM: URL?
    @State private var vphoneBundle: URL?
    @State private var vphoneLibrary: URL?
    @State private var vmName = ""
    @State private var error: String?
    @State private var touching = false
    @State private var backgroundPaused = false
    private let requireInterpreter: Bool
    private let includesVPhone: Bool
    private enum Selection { case base, bootROM, bundle, library }

    public init(requireInterpreter: Bool, includesVPhone: Bool) {
        self.requireInterpreter = requireInterpreter
        self.includesVPhone = includesVPhone
    }

    public var body: some View {
        NavigationView {
            VStack {
                if lightTouch.isRunning || lightTouch.image != nil {
                    display
                    HStack {
                        guestButton("Home", code: 0)
                        guestButton("Power", code: 1)
                        Button(lightTouch.isPaused ? "Resume" : "Pause") { lightTouch.setPaused(!lightTouch.isPaused) }
                            .disabled(!lightTouch.isRunning)
                        Button("Stop") { lightTouch.stop() }.disabled(!lightTouch.isRunning)
                    }.padding(.horizontal)
                    Text(lightTouch.status).font(.caption).padding(.bottom)
                } else {
                    Form {
                        Section("Classic iPhone, iPod touch and iPad") {
                            Text("Import an unpacked device prepared with LightTouch's firmwarekit and its matching boot ROM. Guest changes are stored in UTM's own overlay.")
                            Button(base?.lastPathComponent ?? "Choose prepared device…") { choose(.base) }
                            Button(bootROM?.lastPathComponent ?? "Choose matching boot ROM…") { choose(.bootROM) }
                            Button("Start LightTouch") { startLightTouch() }
                                .disabled(base == nil || bootROM == nil || lightTouch.hasStarted)
                            Text(lightTouch.status).font(.caption)
                        }
                        if includesVPhone {
                        Section("iPhone and iPad virtualization") {
                            #if os(macOS) && arch(arm64)
                            if #available(macOS 15, *) {
                                Button(vphoneBundle?.lastPathComponent ?? "Choose VPhone.bundle…") { choose(.bundle) }
                                Button(vphoneLibrary?.lastPathComponent ?? "Choose VM library…") { choose(.library) }
                                TextField("Existing VM name", text: $vmName)
                                Button("Start vphone") { startVPhone() }
                                    .disabled(vphone.isRunning || vphoneBundle == nil || vphoneLibrary == nil || vmName.isEmpty)
                                Button("Stop vphone") { do { try vphone.stop() } catch { self.error = error.localizedDescription } }
                                    .disabled(!vphone.isRunning)
                            }
                            #endif
                            Text(vphone.status).font(.caption).textSelection(.enabled)
                        }
                        }
                    }
                }
            }
            .navigationTitle("iOS Guests — Experimental")
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }.disabled(lightTouch.isRunning || vphone.isRunning)
            } }
            .fileImporter(isPresented: $isChoosingFile,
                          allowedContentTypes: picker == .bootROM ? [.data, .item] : [.folder, .bundle],
                          allowsMultipleSelection: false) { result in
                let selection = picker
                picker = nil
                do {
                    guard let url = try result.get().first else { return }
                    switch selection {
                    case .base: base = url
                    case .bootROM: bootROM = url
                    case .bundle: vphoneBundle = url
                    case .library: vphoneLibrary = url
                    case nil: break
                    }
                } catch { self.error = error.localizedDescription }
            }
            .alert("iOS Guest", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
        .onAppear {
            if includesVPhone { vphone.inspectHost() }
            #if os(macOS)
            if let resources = Bundle.main.resourceURL {
                let candidate = resources.appendingPathComponent("VPhone.bundle")
                if FileManager.default.fileExists(atPath: candidate.path) { vphoneBundle = candidate }
            }
            #endif
        }
        .interactiveDismissDisabled(lightTouch.isRunning || vphone.isRunning)
        .onChange(of: scenePhase) { phase in
            if phase != .active, lightTouch.isRunning, !lightTouch.isPaused {
                backgroundPaused = true
                lightTouch.setPaused(true)
            } else if phase == .active, backgroundPaused {
                backgroundPaused = false
                lightTouch.setPaused(false)
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 640)
        #endif
    }

    private var display: some View {
        GeometryReader { geometry in
            if let image = lightTouch.image {
                let scale = min(geometry.size.width / CGFloat(image.width), geometry.size.height / CGFloat(image.height))
                let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                Image(decorative: image, scale: 1).resizable().interpolation(.none)
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            lightTouch.touch(phase: touching ? 1 : 0,
                                             x: value.location.x / size.width, y: value.location.y / size.height)
                            touching = true
                        }.onEnded { value in
                            lightTouch.touch(phase: 2, x: value.location.x / size.width, y: value.location.y / size.height)
                            touching = false
                        })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ProgressView(lightTouch.status).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.background(Color.black)
    }

    private func guestButton(_ title: String, code: Int32) -> some View {
        Button(title) {
            lightTouch.button(code, down: true)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                lightTouch.button(code, down: false)
            }
        }.disabled(!lightTouch.isRunning)
    }

    private func choose(_ selection: Selection) {
        picker = selection
        isChoosingFile = true
    }

    private func startLightTouch() {
        guard let base, let bootROM else { return }
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("UTM/MobileGuests", isDirectory: true)
            // Key the overlay by a bookmark of the selected base, not by its display name.
            let key = "LightTouchWork-" + base.absoluteString
            let id = UserDefaults.standard.string(forKey: key) ?? UUID().uuidString
            UserDefaults.standard.set(id, forKey: key)
            try lightTouch.start(base: base, bootROM: bootROM, work: root.appendingPathComponent(id), requireInterpreter: requireInterpreter)
        } catch { self.error = error.localizedDescription }
    }

    private func startVPhone() {
        guard let vphoneBundle, let vphoneLibrary else { return }
        do { try vphone.launch(bundle: vphoneBundle, library: vphoneLibrary, name: vmName) }
        catch { self.error = error.localizedDescription }
    }
}

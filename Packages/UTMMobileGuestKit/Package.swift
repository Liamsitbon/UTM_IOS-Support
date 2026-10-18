// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UTMMobileGuestKit",
    platforms: [.macOS(.v12), .iOS(.v15), .visionOS(.v1)],
    products: [.library(name: "UTMMobileGuestKit", targets: ["UTMMobileGuestKit"]),
               .executable(name: "utm-mobile-guest-probe", targets: ["MobileGuestProbe"])],
    targets: [
        .target(name: "LightTouchHostRuntime"),
        .target(name: "CMobileGuest"),
        .target(name: "UTMMobileGuestKit", dependencies: ["LightTouchHostRuntime", "CMobileGuest"]),
        .executableTarget(name: "MobileGuestProbe", dependencies: ["CMobileGuest", "UTMMobileGuestKit"]),
        .testTarget(name: "UTMMobileGuestKitTests", dependencies: ["UTMMobileGuestKit", "LightTouchHostRuntime", "MobileGuestProbe"])
    ],
    swiftLanguageModes: [.v5]
)

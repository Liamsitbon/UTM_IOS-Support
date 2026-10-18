import Foundation

@MainActor public enum MobileGuestProcessOwnership {
    private static var owner: String?

    public static func claim(_ engine: String) throws {
        if let owner {
            throw MobileGuestError.unavailable("\(owner) has already used this app process. Reopen UTM before starting another emulator.")
        }
        owner = engine
    }
}

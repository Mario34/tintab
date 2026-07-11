import Foundation

enum DebugLogger {
    static let isEnabled = ProcessInfo.processInfo.environment["TINTAP_DEBUG"] == "1"

    static func log(_ message: String) {
        guard isEnabled else { return }
        print("[Tintap] \(message)")
    }
}

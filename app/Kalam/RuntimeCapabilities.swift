import Foundation
import Security

struct RuntimeCapabilities: Equatable {
    var appSandbox: Bool
    var audioInput: Bool
    var accessibility: Bool
    var outgoingNetworkClient: Bool

    var isNetworkConstrained: Bool {
        appSandbox && !outgoingNetworkClient
    }

    var sandboxedAudioCaveat: String? {
        guard appSandbox else { return nil }
        guard audioInput else { return "App Sandbox is enabled without the audio-input entitlement." }
        return nil
    }

    static func current() -> RuntimeCapabilities {
        let reader = EntitlementReader.current
        return RuntimeCapabilities(
            appSandbox: reader.bool("com.apple.security.app-sandbox"),
            audioInput: reader.bool("com.apple.security.device.audio-input"),
            accessibility: reader.bool("com.apple.security.accessibility"),
            outgoingNetworkClient: reader.bool("com.apple.security.network.client")
        )
    }
}

private struct EntitlementReader {
    static let current = EntitlementReader()

    func bool(_ key: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil)
        else {
            return false
        }
        return (value as? Bool) == true
    }
}

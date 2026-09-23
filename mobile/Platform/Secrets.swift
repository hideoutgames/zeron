import Foundation
import SkipKeychain

/// Platform-secure key/value storage: Keychain on iOS, EncryptedSharedPreferences on Android.
public enum Secrets {
    public static func read(_ key: String) -> String? {
        try? Keychain.shared.string(forKey: key)
    }

    public static func write(_ value: String?, for key: String) {
        if let value {
            try? Keychain.shared.set(value, forKey: key)
        } else {
            try? Keychain.shared.removeValue(forKey: key)
        }
    }
}

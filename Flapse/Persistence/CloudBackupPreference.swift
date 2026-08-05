import Foundation

enum CloudBackupPreference {
    static let activeKey = "icloud.backup.active"
    static let restartRequiredKey = "icloud.backup.restartRequired"

    private static var preferenceKey: String {
        PremiumFeature.cloudBackupPreferenceKey
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: preferenceKey)
    }

    static func prepareForLaunch() {
        let store = NSUbiquitousKeyValueStore.default
        store.synchronize()

        if let cloudValue = store.object(forKey: preferenceKey) as? Bool {
            UserDefaults.standard.set(cloudValue, forKey: preferenceKey)
        } else if UserDefaults.standard.object(forKey: preferenceKey) != nil {
            store.set(isEnabled, forKey: preferenceKey)
            store.synchronize()
        }

        UserDefaults.standard.set(false, forKey: restartRequiredKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: preferenceKey)
        let store = NSUbiquitousKeyValueStore.default
        store.set(enabled, forKey: preferenceKey)
        store.synchronize()
    }

    @discardableResult
    static func refreshFromCloud() -> Bool {
        let store = NSUbiquitousKeyValueStore.default
        store.synchronize()
        guard let cloudValue = store.object(forKey: preferenceKey) as? Bool else {
            return isEnabled
        }
        let changed = cloudValue != isEnabled
        UserDefaults.standard.set(cloudValue, forKey: preferenceKey)
        if changed {
            UserDefaults.standard.set(true, forKey: restartRequiredKey)
        }
        return cloudValue
    }
}

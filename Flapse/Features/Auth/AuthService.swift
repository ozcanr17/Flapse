import Foundation
import AuthenticationServices

/// Apple ile Giriş akışını yönetir ve kullanıcının oturum bilgisini cihazda güvenli saklar.
@MainActor
@Observable
final class AuthService {

    private enum Key {
        static let userID = "auth.appleUserID"
        static let email = "auth.email"
        static let name = "auth.name"
    }

    init() {
        userID = Self.loadAndMigrate(Key.userID)
        email = Self.loadAndMigrate(Key.email)
        displayName = Self.loadAndMigrate(Key.name)
    }

    private(set) var userID: String?
    private(set) var email: String?
    private(set) var displayName: String?

    var isSignedIn: Bool { userID != nil }

    /// Anlık, önbelleksiz kontrol: başka bir ekrandan (ör. Ayarlar) yapılan giriş
    /// buradan hemen görünür.
    static var isSignedInNow: Bool {
        SecureStore.string(forKey: Key.userID) != nil
            || UserDefaults.standard.string(forKey: Key.userID) != nil
    }

    /// Apple'ın döndürdüğü yetkiyi işler ve kimliği saklar.
    /// (E-posta ve ad Apple tarafından YALNIZCA ilk girişte verilir; geldiğinde saklarız.)
    func handle(_ authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            return
        }
        userID = credential.user
        SecureStore.set(credential.user, forKey: Key.userID)
        UserDefaults.standard.removeObject(forKey: Key.userID)

        if let email = credential.email {
            self.email = email
            SecureStore.set(email, forKey: Key.email)
            UserDefaults.standard.removeObject(forKey: Key.email)
        }
        if let full = credential.fullName {
            let name = [full.givenName, full.familyName].compactMap { $0 }.joined(separator: " ")
            if !name.isEmpty {
                displayName = name
                SecureStore.set(name, forKey: Key.name)
                UserDefaults.standard.removeObject(forKey: Key.name)
            }
        }
    }

    func signOut() {
        userID = nil
        email = nil
        displayName = nil
        [Key.userID, Key.email, Key.name].forEach {
            SecureStore.set(nil, forKey: $0)
            UserDefaults.standard.removeObject(forKey: $0)
        }
    }

    func deleteAccountData() {
        signOut()
    }

    private static func loadAndMigrate(_ key: String) -> String? {
        if let secured = SecureStore.string(forKey: key) { return secured }
        guard let legacy = UserDefaults.standard.string(forKey: key) else { return nil }
        if SecureStore.set(legacy, forKey: key) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        return legacy
    }
}

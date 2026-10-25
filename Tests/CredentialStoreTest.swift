import Foundation
import Security

@main struct CredentialStoreTest {
    static func main() throws {
        let missing = try CredentialStore.decode(status: errSecItemNotFound, data: nil)
        precondition(missing == nil)
        for status in [errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed] {
            do {
                _ = try CredentialStore.decode(status: status, data: nil)
                fatalError("Denied Keychain access must not look like a missing password")
            } catch { precondition((error as NSError).code == Int(status)) }
        }
        do {
            _ = try CredentialStore.decode(status: errSecSuccess, data: Data("corrupt".utf8))
            fatalError("Corrupt saved credentials must not look missing")
        } catch {}
        let fixture = Credentials(username: "fixture-user", password: UUID().uuidString)
        let saved = try CredentialStore.decode(status: errSecSuccess, data: JSONEncoder().encode(fixture))
        precondition(saved?.username == fixture.username && saved?.password == fixture.password)
        print("PASS: missing, denied, cancelled, unavailable and corrupt Keychain results")
    }
}

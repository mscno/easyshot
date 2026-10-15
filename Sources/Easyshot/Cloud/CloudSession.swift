import AppKit
import EasyshotCore

/// Sign-in state and upload orchestration. The session token lives in the Keychain, never in preferences.
@MainActor final class CloudSession: ObservableObject {
    static let shared = CloudSession()
    /// The Mac App Store edition is sandboxed without a network entitlement and promises no accounts,
    /// so Easyshot Cloud exists only in the direct-download edition.
    static var isAvailable: Bool { !Distribution.isAppStore }
    @Published private(set) var user: CloudUser?
    @Published private(set) var busy = false
    @Published var error: String?
    private var token: String?
    private var loadedFor: String?
    private let preferences = Preferences.shared

    var baseURL: URL? { Preferences.validatedServerURL(preferences.cloudBaseURL) }
    var isSignedIn: Bool { guard Self.isAvailable else { return false }; loadIfNeeded(); return token != nil }
    var client: CloudClient? { loadIfNeeded(); return baseURL.map { CloudClient(baseURL: $0,token: token) } }

    private var account: String { baseURL?.absoluteString ?? "" }
    private func loadIfNeeded() {
        guard loadedFor != account else { return }
        loadedFor = account
        token = CloudKeychain.read(account)
        user = UserDefaults.standard.data(forKey: "cloudUser:\(account)").flatMap { try? JSONDecoder().decode(CloudUser.self,from: $0) }
    }
    /// A server change must not send the old server's token to the new one.
    func serverChanged() { loadedFor = nil; loadIfNeeded(); objectWillChange.send() }

    func signIn(email: String,password: String,register: Bool) async {
        guard let url = baseURL else { error = "Enter a valid server address (https://…)."; return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@"),!password.isEmpty else { error = "Enter your email and password."; return }
        busy = true; error = nil; defer { busy = false }
        do {
            let result = try await CloudClient(baseURL: url).authenticate(register: register,email: address,password: password,deviceName: Host.current().localizedName ?? "Mac")
            finish(result)
        } catch { self.error = error.localizedDescription }
    }
    private func finish(_ result: CloudClient.AuthResult) {
        CloudKeychain.write(result.token,account: account)
        UserDefaults.standard.set(try? JSONEncoder().encode(result.user),forKey: "cloudUser:\(account)")
        token = result.token; user = result.user; loadedFor = account
    }
    /// Runs a server call that doesn't sign in, surfacing the server's message. Returns success.
    @discardableResult private func attempt(_ work: (CloudClient) async throws -> Void) async -> Bool {
        guard let url = baseURL else { error = "Enter a valid server address (https://…)."; return false }
        busy = true; error = nil; defer { busy = false }
        do { try await work(CloudClient(baseURL: url,token: token)); return true }
        catch CloudError.notSignedIn where token != nil { sessionExpired(); return false }
        catch { self.error = error.localizedDescription; return false }
    }
    private func validEmail(_ email: String) -> String? {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.contains("@") { error = "Enter your email address."; return nil }
        return address
    }
    /// Emails a 6-digit code for sign-in (`reset: false`) or a password reset.
    func requestCode(email: String,reset: Bool) async -> Bool {
        guard let address = validEmail(email) else { return false }
        return await attempt { try await $0.requestCode(email: address,reset: reset) }
    }
    func signIn(email: String,code: String) async {
        guard let address = validEmail(email) else { return }
        await attempt { self.finish(try await $0.signIn(email: address,code: code.trimmingCharacters(in: .whitespaces))) }
    }
    func resetPassword(email: String,code: String,newPassword: String) async -> Bool {
        guard let address = validEmail(email) else { return false }
        return await attempt { try await $0.resetPassword(email: address,code: code.trimmingCharacters(in: .whitespaces),newPassword: newPassword) }
    }
    func sendVerification() async -> Bool { await attempt { try await $0.sendVerification() } }
    func confirmEmail(code: String) async -> Bool {
        let ok = await attempt { try await $0.confirmEmail(code: code.trimmingCharacters(in: .whitespaces)) }
        if ok,var current = user {
            current.emailVerified = true; user = current
            UserDefaults.standard.set(try? JSONEncoder().encode(current),forKey: "cloudUser:\(account)")
        }
        return ok
    }
    /// Refresh the cached profile (e.g. email confirmation state) from the server.
    func refreshUser() async {
        guard let client,token != nil else { return }
        do {
            let fresh = try await client.me()
            user = fresh; UserDefaults.standard.set(try? JSONEncoder().encode(fresh),forKey: "cloudUser:\(account)")
        } catch CloudError.notSignedIn { sessionExpired() } catch {}
    }
    func signOut() {
        let client = self.client
        Task { await client?.logout() }
        CloudKeychain.delete(account)
        UserDefaults.standard.removeObject(forKey: "cloudUser:\(account)")
        token = nil; user = nil
    }
    /// The server rejected our token (expired or revoked).
    func sessionExpired() {
        CloudKeychain.delete(account); UserDefaults.standard.removeObject(forKey: "cloudUser:\(account)")
        token = nil; user = nil; error = "Your session expired. Sign in again."
    }

    /// Reserve → PUT to storage → confirm. Returns the confirmed screenshot with its share link.
    func upload(_ image: UploadableImage) async throws -> CloudScreenshot {
        guard let client else { throw CloudError.notSignedIn }
        do {
            let created = try await client.create(contentType: image.contentType,byteSize: image.data.count,width: image.width,height: image.height,filename: image.filename)
            try await client.put(image.data,to: created)
            var done = try await client.complete(created.screenshot.id)
            if done.shareURL.isEmpty { done.shareURL = created.screenshot.shareURL }
            return done
        } catch CloudError.notSignedIn { sessionExpired(); throw CloudError.notSignedIn }
    }
}

/// Encoded bytes ready for upload, plus what the server needs to know about them.
struct UploadableImage: Sendable {
    var data: Data; var contentType: String; var width: Int; var height: Int; var filename: String
    static let maxBytes = 24 * 1024 * 1024

    /// Reads an image file, shrinking oversized PNGs to JPEG so they fit the server limit.
    static func load(from url: URL) throws -> UploadableImage {
        let data = try Data(contentsOf: url,options: .mappedIfSafe)
        guard let rep = NSBitmapImageRep(data: data) else { throw ShotError.message("This file is not an image Easyshot can upload.") }
        let ext = url.pathExtension.lowercased()
        let type = ["jpg": "image/jpeg","jpeg": "image/jpeg","gif": "image/gif","webp": "image/webp"][ext] ?? "image/png"
        return try make(data: data,contentType: type,rep: rep,filename: url.lastPathComponent)
    }
    static func make(data: Data,contentType: String,rep: NSBitmapImageRep,filename: String) throws -> UploadableImage {
        if data.count <= maxBytes { return UploadableImage(data: data,contentType: contentType,width: rep.pixelsWide,height: rep.pixelsHigh,filename: filename) }
        guard contentType != "image/gif",let jpeg = rep.representation(using: .jpeg,properties: [.compressionFactor: 0.85]),jpeg.count <= maxBytes else {
            throw ShotError.message("This image is larger than the 25 MB upload limit.")
        }
        return UploadableImage(data: jpeg,contentType: "image/jpeg",width: rep.pixelsWide,height: rep.pixelsHigh,filename: (filename as NSString).deletingPathExtension + ".jpg")
    }
    /// The image currently on the general pasteboard: a copied file, PNG data, or anything NSImage understands.
    static func fromPasteboard(_ pasteboard: NSPasteboard = .general) throws -> UploadableImage? {
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self],options: [.urlReadingFileURLsOnly: true,.urlReadingContentsConformToTypes: ["public.image"]]) as? [URL])?.first {
            return try load(from: url)
        }
        if let png = pasteboard.data(forType: .png),let rep = NSBitmapImageRep(data: png) {
            return try make(data: png,contentType: "image/png",rep: rep,filename: CaptureFiles.filename(extension: "png"))
        }
        if let tiff = pasteboard.data(forType: .tiff),let rep = NSBitmapImageRep(data: tiff),let png = rep.representation(using: .png,properties: [:]) {
            return try make(data: png,contentType: "image/png",rep: rep,filename: CaptureFiles.filename(extension: "png"))
        }
        return nil
    }
}

import AppKit
import ImageIO
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
    /// Bumped whenever the server or the signed-in identity changes. A sign-in that started under an older
    /// generation is discarded, so a token is only ever stored for, and sent to, the server that issued it.
    private var generation = 0
    private let preferences = Preferences.shared

    var baseURL: URL? { Preferences.validatedServerURL(preferences.cloudBaseURL) }
    var isSignedIn: Bool { guard Self.isAvailable else { return false }; loadIfNeeded(); return token != nil }
    var client: CloudClient? { loadIfNeeded(); return baseURL.map { CloudClient(baseURL: $0,token: token) } }

    private var account: String { baseURL?.absoluteString ?? "" }
    private func loadIfNeeded() {
        guard loadedFor != account else { return }
        loadedFor = account; generation += 1
        token = CloudKeychain.read(account)
        user = UserDefaults.standard.data(forKey: "cloudUser:\(account)").flatMap { try? JSONDecoder().decode(CloudUser.self,from: $0) }
    }
    /// A server change must not send the old server's token to the new one.
    func serverChanged() { loadedFor = nil; loadIfNeeded(); objectWillChange.send() }

    /// Where a request started: the server, its Keychain account and the generation at that moment.
    private struct Origin { var url: URL; var account: String; var generation: Int }
    private func origin() -> Origin? {
        loadIfNeeded()
        guard let url = baseURL else { error = "Enter a valid server address (https://…)."; return nil }
        return Origin(url: url,account: account,generation: generation)
    }
    /// Signs in with a password, or creates the account. Returns the attempt when the server emailed a code
    /// to confirm the address instead (new or unconfirmed accounts); `signIn(email:code:attempt:)` finishes it.
    @discardableResult func signIn(email: String,password: String,register: Bool) async -> String? {
        guard let origin = origin() else { return nil }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@"),!password.isEmpty else { error = "Enter your email and password."; return nil }
        busy = true; error = nil; defer { busy = false }
        do {
            switch try await CloudClient(baseURL: origin.url).authenticate(register: register,email: address,password: password,deviceName: Host.current().localizedName ?? "Mac") {
            case .signedIn(let result): finish(result,from: origin); return nil
            case .verificationRequired(let attempt): return isCurrent(origin) ? attempt : nil
            }
        } catch { self.error = error.localizedDescription; return nil }
    }
    private func isCurrent(_ origin: Origin) -> Bool {
        loadIfNeeded(); return origin.generation == generation && origin.account == account
    }
    private func finish(_ result: CloudClient.AuthResult,from origin: Origin) {
        loadIfNeeded()
        guard origin.generation == generation,origin.account == account else {
            // The server changed or the user signed out while this was in flight; the token is only valid
            // at `origin`, and nobody asked for it any more.
            let client = CloudClient(baseURL: origin.url,token: result.token)
            Task { await client.logout() }
            return
        }
        CloudKeychain.write(result.token,account: origin.account)
        UserDefaults.standard.set(try? JSONEncoder().encode(result.user),forKey: "cloudUser:\(origin.account)")
        token = result.token; user = result.user; generation += 1
    }
    /// Runs a server call that doesn't sign in, surfacing the server's message. Returns success.
    @discardableResult private func attempt(_ work: (CloudClient,Origin) async throws -> Void) async -> Bool {
        guard let origin = origin() else { return false }
        let token = token
        busy = true; error = nil; defer { busy = false }
        do { try await work(CloudClient(baseURL: origin.url,token: token),origin); return true }
        catch CloudError.notSignedIn where token != nil { expire(origin); return false }
        catch { self.error = error.localizedDescription; return false }
    }
    private func validEmail(_ email: String) -> String? {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.contains("@") { error = "Enter your email address."; return nil }
        return address
    }
    /// Emails a 6-digit code for sign-in (`reset: false`) or a password reset.
    func requestCode(email: String,reset: Bool,attempt confirming: String? = nil) async -> Bool {
        guard let address = validEmail(email) else { return false }
        return await attempt { client,_ in try await client.requestCode(email: address,reset: reset,attempt: confirming) }
    }
    func signIn(email: String,code: String,attempt confirming: String? = nil) async {
        guard let address = validEmail(email) else { return }
        await attempt { client,origin in self.finish(try await client.signIn(email: address,code: code.trimmingCharacters(in: .whitespaces),attempt: confirming),from: origin) }
    }
    func resetPassword(email: String,code: String,newPassword: String) async -> Bool {
        guard let address = validEmail(email) else { return false }
        return await attempt { client,_ in try await client.resetPassword(email: address,code: code.trimmingCharacters(in: .whitespaces),newPassword: newPassword) }
    }
    func sendVerification() async -> Bool { await attempt { client,_ in try await client.sendVerification() } }
    func confirmEmail(code: String) async -> Bool {
        await attempt { client,origin in
            try await client.confirmEmail(code: code.trimmingCharacters(in: .whitespaces))
            guard self.isCurrent(origin),var current = self.user else { return }
            current.emailVerified = true; self.user = current
            UserDefaults.standard.set(try? JSONEncoder().encode(current),forKey: "cloudUser:\(origin.account)")
        }
    }
    /// Refresh the cached profile only for the identity that requested it.
    func refreshUser() async {
        guard let origin = origin(),let token else { return }
        do {
            let fresh = try await CloudClient(baseURL: origin.url,token: token).me()
            guard isCurrent(origin) else { return }
            user = fresh; UserDefaults.standard.set(try? JSONEncoder().encode(fresh),forKey: "cloudUser:\(origin.account)")
        } catch CloudError.notSignedIn { expire(origin) } catch {}
    }
    func signOut() {
        let client = self.client
        Task { await client?.logout() }
        CloudKeychain.delete(account)
        UserDefaults.standard.removeObject(forKey: "cloudUser:\(account)")
        token = nil; user = nil; generation += 1
    }
    /// A delayed response from another server or identity cannot clear this session.
    func isCurrent(_ client: CloudClient) -> Bool { loadIfNeeded(); return client.baseURL == baseURL && client.token == token }
    func sessionExpired(for client: CloudClient) { if isCurrent(client) { sessionExpired() } }
    /// The server rejected our current token (expired or revoked).
    private func sessionExpired() {
        CloudKeychain.delete(account); UserDefaults.standard.removeObject(forKey: "cloudUser:\(account)")
        token = nil; user = nil; error = "Your session expired. Sign in again."; generation += 1
    }
    /// A rejection from `origin` only clears that server's credentials, and only if they are still current.
    private func expire(_ origin: Origin) {
        loadIfNeeded()
        if origin.generation == generation { sessionExpired() }
    }

    /// Reserve → PUT to storage → confirm. Returns the confirmed screenshot with its share link.
    func upload(_ image: UploadableImage) async throws -> CloudScreenshot {
        guard let client else { throw CloudError.notSignedIn }
        let origin = Origin(url: client.baseURL,account: client.baseURL.absoluteString,generation: generation)
        do {
            let created = try await client.create(contentType: image.contentType,byteSize: image.data.count,width: image.width,height: image.height,filename: image.filename)
            try await client.put(image.data,to: created)
            var done = try await client.complete(created.screenshot.id)
            if done.shareURL.isEmpty { done.shareURL = created.screenshot.shareURL }
            return done
        } catch CloudError.notSignedIn { expire(origin); throw CloudError.notSignedIn }
    }
}

/// Encoded bytes ready for upload, plus what the server needs to know about them.
struct UploadableImage: Sendable {
    var data: Data; var contentType: String; var width: Int; var height: Int; var filename: String
    static let maxBytes = 24 * 1024 * 1024

    /// Reads an image file, shrinking oversized PNGs to JPEG so they fit the server limit.
    static func load(from url: URL) throws -> UploadableImage {
        try decode(Data(contentsOf: url,options: .mappedIfSafe),filename: url.lastPathComponent)
    }
    /// The content type comes from the bytes, not the filename; formats the server doesn't store
    /// (TIFF, HEIC, BMP, …) are re-encoded as PNG so the label always matches what is uploaded.
    static func decode(_ data: Data,filename: String) throws -> UploadableImage {
        guard let source = CGImageSourceCreateWithData(data as CFData,nil),let identifier = CGImageSourceGetType(source) as String?,
              let rep = NSBitmapImageRep(data: data) else { throw ShotError.message("This file is not an image Easyshot can upload.") }
        if let type = UploadImageType.mime(forTypeIdentifier: identifier) { return try make(data: data,contentType: type,rep: rep,filename: filename) }
        guard let png = rep.representation(using: .png,properties: [:]) else { throw ShotError.message("This file is not an image Easyshot can upload.") }
        return try make(data: png,contentType: "image/png",rep: rep,filename: (filename as NSString).deletingPathExtension + ".png")
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
        if let png = pasteboard.data(forType: .png) { return try decode(png,filename: CaptureFiles.filename(extension: "png")) }
        if let tiff = pasteboard.data(forType: .tiff),let rep = NSBitmapImageRep(data: tiff),let png = rep.representation(using: .png,properties: [:]) {
            return try make(data: png,contentType: "image/png",rep: rep,filename: CaptureFiles.filename(extension: "png"))
        }
        return nil
    }
}

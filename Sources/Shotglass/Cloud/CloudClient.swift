import Foundation
import Security
import ShotglassCore

struct CloudUser: Codable, Equatable { var id: String; var email: String; var plan: String?; var emailVerified: Bool? }

struct CloudScreenshot: Identifiable, Equatable {
    var id: String; var slug: String; var shareURL: String; var contentType: String; var byteSize: Int
    var width: Int?; var height: Int?; var filename: String?
    var createdAt: Date; var expiresAt: Date; var imageURL: String
}

enum CloudError: LocalizedError {
    case notSignedIn, server(String), invalidResponse, uploadFailed(Int)
    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to Shotglass Cloud to upload screenshots."
        case .server(let message): return message
        case .invalidResponse: return "The Shotglass server sent an unexpected response."
        case .uploadFailed(let status): return "Upload to storage failed (HTTP \(status))."
        }
    }
}

/// Thin typed wrapper around the Shotglass backend. Tokens are bearer credentials kept in the Keychain.
struct CloudClient {
    var baseURL: URL
    var token: String?
    var session: URLSession = .shared

    private struct Wire: Decodable {
        struct Upload: Decodable { var method: String; var url: String; var headers: [String: String] }
        struct Shot: Decodable {
            var id: String; var slug: String; var shareUrl: String; var contentType: String; var byteSize: Int
            var width: Int?; var height: Int?; var filename: String?
            var createdAt: String; var expiresAt: String; var imageUrl: String?
        }
    }
    struct Created { var screenshot: CloudScreenshot; var uploadURL: URL; var headers: [String: String]; var method: String }
    struct AuthResult { var token: String; var user: CloudUser }

    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d }()

    private static let failureDecoder = JSONDecoder()
    private struct Failure: Decodable { struct Inner: Decodable { var message: String }; var error: Inner }

    private func makeRequest(_ method: String,_ path: String,query: [URLQueryItem] = [],body: Data? = nil,authorized: Bool = true) throws -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path),resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!,timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json",forHTTPHeaderField: "Accept")
        request.setValue("Shotglass/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")",forHTTPHeaderField: "User-Agent")
        if authorized {
            guard let token else { throw CloudError.notSignedIn }
            request.setValue("Bearer \(token)",forHTTPHeaderField: "Authorization")
        }
        if let body { request.setValue("application/json",forHTTPHeaderField: "Content-Type"); request.httpBody = body }
        return request
    }
    private func send(_ request: URLRequest,authorized: Bool = true) async throws -> Data {
        let (data,response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.invalidResponse }
        if http.statusCode == 401 && authorized { throw CloudError.notSignedIn }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudError.server((try? Self.failureDecoder.decode(Failure.self,from: data))?.error.message ?? "Server error (HTTP \(http.statusCode)).")
        }
        return data
    }
    private func request(_ method: String,_ path: String,query: [URLQueryItem] = []) async throws -> Data {
        try await send(makeRequest(method,path,query: query))
    }
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return e }()
    private func shot(_ wire: Wire.Shot) throws -> CloudScreenshot {
        guard let created = RFC3339.parse(wire.createdAt),let expires = RFC3339.parse(wire.expiresAt) else { throw CloudError.invalidResponse }
        return CloudScreenshot(id: wire.id,slug: wire.slug,shareURL: wire.shareUrl,contentType: wire.contentType,byteSize: wire.byteSize,width: wire.width,height: wire.height,filename: wire.filename,createdAt: created,expiresAt: expires,imageURL: wire.imageUrl ?? "")
    }

    func authenticate(register: Bool,email: String,password: String,deviceName: String) async throws -> AuthResult {
        struct Body: Encodable { var email: String; var password: String; var deviceName: String }
        struct Reply: Decodable { var token: String; var user: CloudUser }
        let body = try Self.encoder.encode(Body(email: email,password: password,deviceName: deviceName))
        let data = try await send(makeRequest("POST","v1/auth/\(register ? "register" : "login")",body: body,authorized: false),authorized: false)
        let reply = try Self.decoder.decode(Reply.self,from: data)
        return AuthResult(token: reply.token,user: reply.user)
    }
    private static let deviceName = Host.current().localizedName ?? "Mac"
    private func post<B: Encodable>(_ path: String,_ body: B,authorized: Bool = false) async throws -> Data {
        try await send(makeRequest("POST",path,body: Self.encoder.encode(body),authorized: authorized),authorized: authorized)
    }
    /// Emails a one-time code for passwordless sign-in or password reset. The server answers the same for unknown accounts.
    func requestCode(email: String,reset: Bool) async throws {
        struct Body: Encodable { var email: String }
        _ = try await post("v1/auth/\(reset ? "password/forgot" : "otp/request")",Body(email: email))
    }
    func signIn(email: String,code: String) async throws -> AuthResult {
        struct Body: Encodable { var email: String; var code: String; var deviceName: String }
        struct Reply: Decodable { var token: String; var user: CloudUser }
        let reply = try Self.decoder.decode(Reply.self,from: await post("v1/auth/otp/verify",Body(email: email,code: code,deviceName: Self.deviceName)))
        return AuthResult(token: reply.token,user: reply.user)
    }
    func resetPassword(email: String,code: String,newPassword: String) async throws {
        struct Body: Encodable { var email: String; var code: String; var newPassword: String }
        _ = try await post("v1/auth/password/reset",Body(email: email,code: code,newPassword: newPassword))
    }
    func sendVerification() async throws {
        struct Empty: Encodable {}
        _ = try await post("v1/auth/verify-email/send",Empty(),authorized: true)
    }
    func confirmEmail(code: String) async throws {
        struct Body: Encodable { var code: String }
        _ = try await post("v1/auth/verify-email/confirm",Body(code: code),authorized: true)
    }
    func logout() async { _ = try? await request("POST","v1/auth/logout") }
    func me() async throws -> CloudUser {
        try Self.decoder.decode(CloudUser.self,from: await request("GET","v1/me"))
    }
    func create(contentType: String,byteSize: Int,width: Int,height: Int,filename: String) async throws -> Created {
        struct Body: Encodable { var contentType: String; var byteSize: Int; var width: Int; var height: Int; var filename: String }
        struct Reply: Decodable { var id: String; var slug: String; var shareUrl: String; var expiresAt: String; var upload: Wire.Upload }
        let body = try Self.encoder.encode(Body(contentType: contentType,byteSize: byteSize,width: width,height: height,filename: filename))
        let reply = try Self.decoder.decode(Reply.self,from: await send(makeRequest("POST","v1/screenshots",body: body)))
        guard let upload = URL(string: reply.upload.url),let expires = RFC3339.parse(reply.expiresAt) else { throw CloudError.invalidResponse }
        let placeholder = CloudScreenshot(id: reply.id,slug: reply.slug,shareURL: reply.shareUrl,contentType: contentType,byteSize: byteSize,width: width,height: height,filename: filename,createdAt: Date(),expiresAt: expires,imageURL: "")
        return Created(screenshot: placeholder,uploadURL: upload,headers: reply.upload.headers,method: reply.upload.method)
    }
    func complete(_ id: String) async throws -> CloudScreenshot {
        try shot(Self.decoder.decode(Wire.Shot.self,from: await request("POST","v1/screenshots/\(id)/complete")))
    }
    func list(before: String? = nil,limit: Int = 50) async throws -> (items: [CloudScreenshot],next: String?) {
        struct Reply: Decodable { var items: [Wire.Shot]; var nextCursor: String? }
        var query = [URLQueryItem(name: "limit",value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before",value: before)) }
        let reply = try Self.decoder.decode(Reply.self,from: await request("GET","v1/screenshots",query: query))
        return (try reply.items.map(shot),reply.nextCursor)
    }
    func delete(_ id: String) async throws { _ = try await request("DELETE","v1/screenshots/\(id)") }

    /// PUT the bytes straight to object storage using the presigned request.
    func put(_ data: Data,to created: Created) async throws {
        var req = URLRequest(url: created.uploadURL,timeoutInterval: 120)
        req.httpMethod = created.method
        for (name,value) in created.headers { req.setValue(value,forHTTPHeaderField: name) }
        let (_,response) = try await session.upload(for: req,from: data)
        guard let http = response as? HTTPURLResponse,(200..<300).contains(http.statusCode) else {
            throw CloudError.uploadFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }
}

/// Generic-password Keychain item holding the session token for one server.
enum CloudKeychain {
    private static let service = "\(Bundle.main.bundleIdentifier ?? "no.paraply.shotglass").cloud"
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,kSecAttrService as String: service,kSecAttrAccount as String: account]
    }
    static func read(_ account: String) -> String? {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary,&out) == errSecSuccess,let data = out as? Data else { return nil }
        return String(data: data,encoding: .utf8)
    }
    static func write(_ value: String,account: String) {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account); q[kSecValueData as String] = Data(value.utf8); q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary,nil)
    }
    static func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}

import Foundation
import EasyshotCore

/// A video on Easyshot Cloud. The share link exists from creation, before any bytes arrive.
struct CloudVideo: Codable,Equatable,Sendable {
    var id: String; var slug: String; var shareUrl: String; var title: String?; var status: String
    var visibility: String?; var byteSize: Int?; var durationMs: Int?; var width: Int?; var height: Int?
    var hasThumbnail: Bool?; var hasTranscript: Bool?
    struct Limits: Codable,Equatable,Sendable { var minPartBytes: Int; var maxBytes: Int?; var maxPartBatch: Int; var partUrlTtlSeconds: Int?; var maxParts: Int? }
    var upload: Limits?
}

/// Presigned single-object PUT (thumbnail, transcript) as the server describes it.
struct PresignedPut: Decodable,Sendable { var method: String; var url: String; var headers: [String: String] }

extension CloudClient {
    /// Seconds without upload progress before a part PUT is abandoned and retried (`--share-test` shortens it).
    nonisolated(unsafe) static var partIdleTimeout: TimeInterval = 25
    func createVideo(title: String?) async throws -> CloudVideo {
        struct Body: Encodable { var title: String?; var contentType = "video/mp4" }
        return try Self.decoder.decode(CloudVideo.self,from: await send(makeRequest("POST","v1/videos",body: Self.encoder.encode(Body(title: title)))))
    }
    func video(_ id: String) async throws -> CloudVideo { try Self.decoder.decode(CloudVideo.self,from: await send(makeRequest("GET","v1/videos/\(id)"))) }
    /// Presigned UploadPart URLs, keyed by part number. Each part's exact size is signed into its URL,
    /// and the server reserves those bytes against the video's and the account's allowance.
    func presignParts(_ id: String,parts: [(number: Int,size: Int)]) async throws -> [Int: URL] {
        struct Part: Encodable { var partNumber: Int; var size: Int }
        struct Body: Encodable { var parts: [Part] }
        struct Reply: Decodable { struct Part: Decodable { var partNumber: Int; var url: String }; var parts: [Part] }
        let body = Body(parts: parts.map { Part(partNumber: $0.number,size: $0.size) })
        let reply = try Self.decoder.decode(Reply.self,from: await send(makeRequest("POST","v1/videos/\(id)/parts",body: Self.encoder.encode(body))))
        var out: [Int: URL] = [:]
        for part in reply.parts { guard let url = URL(string: part.url) else { throw CloudError.invalidResponse }; out[part.partNumber] = url }
        return out
    }
    func completeVideo(_ id: String,parts: [(number: Int,etag: String)],durationMs: Int,width: Int,height: Int) async throws -> CloudVideo {
        struct Part: Encodable { var partNumber: Int; var etag: String }
        struct Body: Encodable { var parts: [Part]; var durationMs: Int; var width: Int; var height: Int }
        let body = Body(parts: parts.map { Part(partNumber: $0.number,etag: $0.etag) },durationMs: durationMs,width: width,height: height)
        var request = try makeRequest("POST","v1/videos/\(id)/complete",body: Self.encoder.encode(body)); request.timeoutInterval = 120
        return try Self.decoder.decode(CloudVideo.self,from: await send(request))
    }
    /// `kind` is `thumbnail` (JPEG) or `transcript` (WebVTT): reserve, PUT the bytes to storage, then
    /// publish. The server announces the asset to open pages only after it has seen the stored object.
    func uploadAsset(_ id: String,kind: String,data: Data) async throws {
        struct Body: Encodable { var byteSize: Int }
        struct Reply: Decodable { var upload: PresignedPut }
        let backoff = Backoff()
        for attempt in 0... {
            do {
                let reply = try Self.decoder.decode(Reply.self,from: await send(makeRequest("POST","v1/videos/\(id)/\(kind)",body: Self.encoder.encode(Body(byteSize: data.count)))))
                guard let url = URL(string: reply.upload.url) else { throw CloudError.invalidResponse }
                var request = URLRequest(url: url,timeoutInterval: 60); request.httpMethod = reply.upload.method
                for (name,value) in reply.upload.headers { request.setValue(value,forHTTPHeaderField: name) }
                let (_,response) = try await session.upload(for: request,from: data)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else { throw CloudError.uploadFailed(status) }
                _ = try await send(makeRequest("POST","v1/videos/\(id)/\(kind)/complete"))
                return
            } catch {
                guard attempt < 3,let status = CloudError.retryStatus(error),Backoff.retryable(status: status) else { throw error }
                try await Task.sleep(for: .seconds(backoff.delay(attempt: attempt,unit: .random(in: 0...1))))
            }
        }
    }
    func updateVideo(_ id: String,title: String) async throws -> CloudVideo {
        struct Body: Encodable { var title: String }
        return try Self.decoder.decode(CloudVideo.self,from: await send(makeRequest("PATCH","v1/videos/\(id)",body: Self.encoder.encode(Body(title: title)))))
    }
    /// Upload progress for the watch page and library. Returns false when the server has no such endpoint
    /// (404/405); other failures throw and are ignored by the caller.
    func reportProgress(_ id: String,uploadedBytes: Int,recording: Bool) async throws -> Bool {
        struct Body: Encodable { var uploadedBytes: Int; var recording: Bool }
        var request = try makeRequest("POST","v1/videos/\(id)/progress",body: Self.encoder.encode(Body(uploadedBytes: uploadedBytes,recording: recording)))
        request.timeoutInterval = 10
        let (_,response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 || status == 405 { return false }
        guard (200..<300).contains(status) else { throw CloudError.server(status: status,code: nil,message: "Progress report failed (HTTP \(status)).") }
        return true
    }
    func deleteVideo(_ id: String) async throws { _ = try await send(makeRequest("DELETE","v1/videos/\(id)")) }
    /// PUT one part straight to object storage and return its ETag, quotes included.
    func putPart(_ data: Data,to url: URL) async throws -> String {
        // An idle timeout: a stalled connection fails after this long without progress and the part is retried.
        var request = URLRequest(url: url,timeoutInterval: Self.partIdleTimeout); request.httpMethod = "PUT"
        let (_,response) = try await session.upload(for: request,from: data)
        let http = response as? HTTPURLResponse
        guard let http,(200..<300).contains(http.statusCode) else { throw CloudError.uploadFailed(http?.statusCode ?? 0) }
        guard let etag = http.value(forHTTPHeaderField: "ETag"),!etag.isEmpty else { throw CloudError.invalidResponse }
        return etag
    }
}

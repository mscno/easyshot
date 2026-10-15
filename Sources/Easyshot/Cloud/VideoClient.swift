import Foundation
import EasyshotCore

/// A video on Easyshot Cloud. The share link exists from creation, before any bytes arrive.
struct CloudVideo: Codable,Equatable,Sendable {
    var id: String; var slug: String; var shareUrl: String; var title: String?; var status: String
    var visibility: String?; var byteSize: Int?; var durationMs: Int?; var width: Int?; var height: Int?
    var hasThumbnail: Bool?; var hasTranscript: Bool?
    struct Limits: Codable,Equatable,Sendable { var minPartBytes: Int; var maxBytes: Int?; var maxPartBatch: Int; var partUrlTtlSeconds: Int? }
    var upload: Limits?
}

/// Presigned single-object PUT (thumbnail, transcript) as the server describes it.
struct PresignedPut: Decodable,Sendable { var method: String; var url: String; var headers: [String: String] }

extension CloudClient {
    func createVideo(title: String?) async throws -> CloudVideo {
        struct Body: Encodable { var title: String?; var contentType = "video/mp4" }
        return try Self.decoder.decode(CloudVideo.self,from: await send(makeRequest("POST","v1/videos",body: Self.encoder.encode(Body(title: title)))))
    }
    func video(_ id: String) async throws -> CloudVideo { try Self.decoder.decode(CloudVideo.self,from: await send(makeRequest("GET","v1/videos/\(id)"))) }
    /// Presigned UploadPart URLs, keyed by part number.
    func presignParts(_ id: String,numbers: [Int]) async throws -> [Int: URL] {
        struct Body: Encodable { var partNumbers: [Int] }
        struct Reply: Decodable { struct Part: Decodable { var partNumber: Int; var url: String }; var parts: [Part] }
        let reply = try Self.decoder.decode(Reply.self,from: await send(makeRequest("POST","v1/videos/\(id)/parts",body: Self.encoder.encode(Body(partNumbers: numbers)))))
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
    /// `kind` is `thumbnail` (JPEG) or `transcript` (WebVTT): reserve, then PUT the bytes to storage.
    func uploadAsset(_ id: String,kind: String,data: Data) async throws {
        struct Body: Encodable { var byteSize: Int }
        struct Reply: Decodable { var upload: PresignedPut }
        let reply = try Self.decoder.decode(Reply.self,from: await send(makeRequest("POST","v1/videos/\(id)/\(kind)",body: Self.encoder.encode(Body(byteSize: data.count)))))
        guard let url = URL(string: reply.upload.url) else { throw CloudError.invalidResponse }
        var request = URLRequest(url: url,timeoutInterval: 60); request.httpMethod = reply.upload.method
        for (name,value) in reply.upload.headers { request.setValue(value,forHTTPHeaderField: name) }
        let (_,response) = try await session.upload(for: request,from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw CloudError.uploadFailed(status) }
    }
    func updateVideo(_ id: String,title: String) async throws -> CloudVideo {
        struct Body: Encodable { var title: String }
        return try Self.decoder.decode(CloudVideo.self,from: await send(makeRequest("PATCH","v1/videos/\(id)",body: Self.encoder.encode(Body(title: title)))))
    }
    func deleteVideo(_ id: String) async throws { _ = try await send(makeRequest("DELETE","v1/videos/\(id)")) }
    /// PUT one part straight to object storage and return its ETag, quotes included.
    func putPart(_ data: Data,to url: URL) async throws -> String {
        var request = URLRequest(url: url,timeoutInterval: 120); request.httpMethod = "PUT"
        let (_,response) = try await session.upload(for: request,from: data)
        let http = response as? HTTPURLResponse
        guard let http,(200..<300).contains(http.statusCode) else { throw CloudError.uploadFailed(http?.statusCode ?? 0) }
        guard let etag = http.value(forHTTPHeaderField: "ETag"),!etag.isEmpty else { throw CloudError.invalidResponse }
        return etag
    }
}

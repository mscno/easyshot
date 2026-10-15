import Foundation
import CoreGraphics

/// Model Context Protocol over stdio: newline-delimited JSON-RPC 2.0, independent of capture code.
public enum MCP {
    public static let latestVersion = "2025-06-18"
    public static let supportedVersions: Set<String> = ["2025-06-18","2025-03-26","2024-11-05"]
    /// Echo a version the client asked for when supported; otherwise offer the newest one.
    public static func negotiatedVersion(_ requested: String?) -> String {
        requested.flatMap { supportedVersions.contains($0) ? $0 : nil } ?? latestVersion
    }
    public struct Request {
        public let id: Any?
        public let method: String
        public let params: [String: Any]
        public var isNotification: Bool { id == nil }
    }
    public enum ParseError: Error { case invalidJSON, invalidRequest(id: Any?) }
    public static func parse(_ line: Data) throws -> Request {
        guard let object = try? JSONSerialization.jsonObject(with: line),let message = object as? [String: Any] else { throw ParseError.invalidJSON }
        let id = message["id"].flatMap { $0 is NSNull ? nil : $0 }
        guard message["jsonrpc"] as? String == "2.0",let method = message["method"] as? String,id == nil || id is String || id is NSNumber else { throw ParseError.invalidRequest(id: id) }
        return Request(id: id,method: method,params: message["params"] as? [String: Any] ?? [:])
    }
    /// One line of protocol output. JSONSerialization escapes embedded newlines.
    public static func encode(_ message: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: message,options: [.withoutEscapingSlashes])) ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Unencodable response"}}"#.utf8)
        data.append(0x0A)
        return data
    }
    public static func response(id: Any?,result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0","id": id ?? NSNull(),"result": result] }
    public static func error(id: Any?,code: Int,message: String) -> [String: Any] { ["jsonrpc": "2.0","id": id ?? NSNull(),"error": ["code": code,"message": message]] }
    public static func text(_ text: String) -> [String: Any] { ["type": "text","text": text] }
    public static func image(_ data: Data,mimeType: String) -> [String: Any] { ["type": "image","data": data.base64EncodedString(),"mimeType": mimeType] }
    public static func json(_ object: Any) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: object,options: [.sortedKeys,.withoutEscapingSlashes])) ?? Data("{}".utf8)
        return text(String(decoding: data,as: UTF8.self))
    }
    public static func toolResult(_ content: [[String: Any]],isError: Bool = false) -> [String: Any] { ["content": content,"isError": isError] }
    public static func toolError(_ message: String) -> [String: Any] { toolResult([text(message)],isError: true) }
}

public struct MCPTool {
    public let name: String
    public let description: String
    public let properties: [String: Any]
    public let required: [String]
    public init(_ name: String,_ description: String,properties: [String: Any] = [:],required: [String] = []) {
        self.name = name; self.description = description; self.properties = properties; self.required = required
    }
    public var definition: [String: Any] {
        var schema: [String: Any] = ["type": "object","properties": properties,"additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name,"description": description,"inputSchema": schema]
    }
}

/// Dispatch shared by the app and the tests. Tool bodies are supplied by the caller.
public final class MCPServerCore: @unchecked Sendable {
    public let tools: [MCPTool]
    public let name: String
    public let version: String
    public let instructions: String
    private let call: (String,MCPArguments) async -> [String: Any]
    public init(name: String,version: String,instructions: String,tools: [MCPTool],call: @escaping (String,MCPArguments) async -> [String: Any]) {
        self.name = name; self.version = version; self.instructions = instructions; self.tools = tools; self.call = call
    }
    /// Returns the encoded reply, or nil for notifications.
    public func handle(_ line: Data) async -> Data? {
        let request: MCP.Request
        do { request = try MCP.parse(line) }
        catch MCP.ParseError.invalidRequest(let id) { return MCP.encode(MCP.error(id: id,code: -32600,message: "Invalid request")) }
        catch { return MCP.encode(MCP.error(id: nil,code: -32700,message: "Parse error")) }
        guard !request.isNotification else { return nil }
        return MCP.encode(await reply(request))
    }
    func reply(_ request: MCP.Request) async -> [String: Any] {
        switch request.method {
        case "initialize":
            return MCP.response(id: request.id,result: [
                "protocolVersion": MCP.negotiatedVersion(request.params["protocolVersion"] as? String),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": name,"version": version],
                "instructions": instructions
            ])
        case "ping": return MCP.response(id: request.id,result: [:])
        case "tools/list": return MCP.response(id: request.id,result: ["tools": tools.map(\.definition)])
        case "tools/call":
            guard let tool = request.params["name"] as? String else { return MCP.error(id: request.id,code: -32602,message: "Missing tool name") }
            guard tools.contains(where: { $0.name == tool }) else { return MCP.error(id: request.id,code: -32602,message: "Unknown tool: \(tool)") }
            return MCP.response(id: request.id,result: await call(tool,MCPArguments(request.params["arguments"] as? [String: Any] ?? [:])))
        default: return MCP.error(id: request.id,code: -32601,message: "Method not found: \(request.method)")
        }
    }
}

public struct MCPArgumentError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

public struct MCPArguments {
    public let raw: [String: Any]
    public init(_ raw: [String: Any]) { self.raw = raw }
    public func string(_ key: String) -> String? { (raw[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    public func double(_ key: String) -> Double? {
        if let n = raw[key] as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue.isFinite ? n.doubleValue : nil }
        return (raw[key] as? String).flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
    }
    public func int(_ key: String) -> Int? { double(key).flatMap { abs($0) < 1e12 ? Int($0) : nil } }
    public func bool(_ key: String,default value: Bool) -> Bool {
        if let n = raw[key] as? NSNumber { return n.boolValue }
        if let s = raw[key] as? String { return ["true","1","yes"].contains(s.lowercased()) }
        return value
    }
    /// `{x,y,width,height}` (or `w`/`h`) in global points, origin at the top left of the main display.
    public func rect(_ key: String) throws -> CGRect? {
        guard let value = raw[key] else { return nil }
        guard let dict = value as? [String: Any] else { throw MCPArgumentError(message: "\(key) must be an object {x, y, width, height}.") }
        let a = MCPArguments(dict)
        guard let x = a.double("x"),let y = a.double("y"),let w = a.double("width") ?? a.double("w"),let h = a.double("height") ?? a.double("h") else {
            throw MCPArgumentError(message: "\(key) needs numeric x, y, width and height.")
        }
        guard w >= 1,h >= 1 else { throw MCPArgumentError(message: "\(key) must be at least 1 × 1 point.") }
        return CGRect(x: x,y: y,width: w,height: h)
    }
}

/// What a capture tool should capture, validated before any screen access.
public enum MCPCaptureTarget: Equatable {
    case display(UInt32?)
    case window(id: UInt32?,app: String?,title: String?)
    case area(CGRect)
    case activeWindow
    public static let names = ["display","window","area","active_window"]
    /// Whether `query` matches an application name or bundle identifier, case-insensitively.
    public static func matches(_ query: String,name: String?,bundle: String?) -> Bool {
        let q = query.lowercased()
        return [name,bundle].contains { $0?.lowercased().contains(q) == true }
    }
    public init(_ args: MCPArguments) throws {
        let explicit = args.string("target")?.lowercased()
        let rect = try args.rect("rect")
        switch explicit ?? (rect != nil ? "area" : args.raw["window_id"] != nil || args.string("app") != nil ? "window" : "display") {
        case "display","screen","fullscreen": self = .display(args.int("display_id").map { UInt32(truncatingIfNeeded: $0) })
        case "window":
            let id = args.int("window_id").map { UInt32(truncatingIfNeeded: $0) }
            guard id != nil || args.string("app") != nil || args.string("title") != nil else { throw MCPArgumentError(message: "Window capture needs window_id, app or title. Call list_windows first.") }
            self = .window(id: id,app: args.string("app"),title: args.string("title"))
        case "area","region":
            guard let rect else { throw MCPArgumentError(message: "Area capture needs rect {x, y, width, height} in points.") }
            self = .area(rect)
        case "active_window","active","frontmost": self = .activeWindow
        case let other: throw MCPArgumentError(message: "Unknown target \"\(other)\". Use one of: \(Self.names.joined(separator: ", ")).")
        }
    }
}

public enum ImageFit {
    /// Largest size within `maxDimension` on the long edge, preserving aspect ratio. Never upscales.
    public static func size(width: Int,height: Int,maxDimension: Int) -> (width: Int,height: Int) {
        let long = max(width,height)
        guard maxDimension > 0,long > maxDimension else { return (width,height) }
        let scale = Double(maxDimension)/Double(long)
        return (max(1,Int((Double(width)*scale).rounded())),max(1,Int((Double(height)*scale).rounded())))
    }
    /// Maps a Vision bounding box (normalized, bottom-left origin) into a top-left-origin frame.
    public static func topLeft(_ box: CGRect,in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX+box.minX*frame.width,y: frame.minY+(1-box.maxY)*frame.height,width: box.width*frame.width,height: box.height*frame.height)
    }
}

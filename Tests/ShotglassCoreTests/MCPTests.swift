import XCTest
import CoreGraphics
@testable import ShotglassCore

final class MCPTests: XCTestCase {
    let tools = [MCPTool("echo","Echo",properties: ["value": ["type": "string"]],required: ["value"]),MCPTool("noop","Nothing")]
    func server() -> MCPServerCore {
        MCPServerCore(name: "shotglass",version: "1.0",instructions: "Use it.",tools: tools) { name,args in
            name == "echo" ? MCP.toolResult([MCP.text(args.string("value") ?? "")]) : MCP.toolError("nope")
        }
    }
    func reply(_ line: String) async throws -> [String: Any]? {
        guard let data = await server().handle(Data(line.utf8)) else { return nil }
        XCTAssertEqual(data.last,0x0A); XCTAssertEqual(data.filter { $0 == 0x0A }.count,1,"one message per line")
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    func testInitializeEchoesSupportedVersionAndFallsBackToLatest() async throws {
        let old = try await reply(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#)
        let result = old?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String,"2024-11-05")
        XCTAssertEqual((result?["serverInfo"] as? [String: Any])?["name"] as? String,"shotglass")
        XCTAssertNotNil((result?["capabilities"] as? [String: Any])?["tools"])
        let future = try await reply(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
        XCTAssertEqual((future?["result"] as? [String: Any])?["protocolVersion"] as? String,MCP.latestVersion)
        XCTAssertEqual(future?["id"] as? String,"a")
    }
    func testNotificationsGetNoReply() async throws {
        let none = try await reply(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(none)
    }
    func testToolsListPublishesObjectSchemas() async throws {
        let list = try await reply(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let defs = (list?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(defs.map { $0["name"] as? String },["echo","noop"])
        let schema = defs[0]["inputSchema"] as? [String: Any]
        XCTAssertEqual(schema?["type"] as? String,"object"); XCTAssertEqual(schema?["required"] as? [String],["value"])
        XCTAssertNil((defs[1]["inputSchema"] as? [String: Any])?["required"])
    }
    func testToolCallRoutesArgumentsAndErrors() async throws {
        let ok = try await reply(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"value":"hi\nthere"}}}"#)
        let result = ok?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool,false)
        XCTAssertEqual((result?["content"] as? [[String: Any]])?.first?["text"] as? String,"hi\nthere")
        let failed = try await reply(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"noop"}}"#)
        XCTAssertEqual((failed?["result"] as? [String: Any])?["isError"] as? Bool,true)
        let unknown = try await reply(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"missing"}}"#)
        XCTAssertEqual((unknown?["error"] as? [String: Any])?["code"] as? Int,-32602)
    }
    func testProtocolErrors() async throws {
        let parse = try await reply("{not json")
        XCTAssertEqual((parse?["error"] as? [String: Any])?["code"] as? Int,-32700); XCTAssertTrue(parse?["id"] is NSNull)
        let invalid = try await reply(#"{"jsonrpc":"1.0","id":7,"method":"ping"}"#)
        XCTAssertEqual((invalid?["error"] as? [String: Any])?["code"] as? Int,-32600); XCTAssertEqual(invalid?["id"] as? Int,7)
        let missing = try await reply(#"{"jsonrpc":"2.0","id":8,"method":"resources/list"}"#)
        XCTAssertEqual((missing?["error"] as? [String: Any])?["code"] as? Int,-32601)
        let ping = try await reply(#"{"jsonrpc":"2.0","id":9,"method":"ping"}"#)
        XCTAssertNotNil(ping?["result"] as? [String: Any])
    }
    func testArgumentsCoerceNumbersBooleansAndRects() throws {
        let args = MCPArguments(["n": 12.7,"s": "40","b": true,"t": "yes","flag": NSNumber(value: true),"rect": ["x": -10,"y": 20,"w": 300,"h": 200]])
        XCTAssertEqual(args.int("n"),12); XCTAssertEqual(args.int("s"),40); XCTAssertNil(args.int("flag"))
        XCTAssertTrue(args.bool("b",default: false)); XCTAssertTrue(args.bool("t",default: false)); XCTAssertFalse(args.bool("absent",default: false))
        XCTAssertEqual(try args.rect("rect"),CGRect(x: -10,y: 20,width: 300,height: 200))
        XCTAssertNil(try args.rect("absent"))
        XCTAssertThrowsError(try MCPArguments(["rect": ["x": 0,"y": 0,"width": 0,"height": 5]]).rect("rect"))
        XCTAssertThrowsError(try MCPArguments(["rect": "0,0,10,10"]).rect("rect"))
    }
    func testCaptureTargetsInferAndValidate() throws {
        XCTAssertEqual(try MCPCaptureTarget(MCPArguments([:])),.display(nil))
        XCTAssertEqual(try MCPCaptureTarget(MCPArguments(["display_id": 2])),.display(2))
        XCTAssertEqual(try MCPCaptureTarget(MCPArguments(["rect": ["x": 1,"y": 2,"width": 3,"height": 4]])),.area(CGRect(x: 1,y: 2,width: 3,height: 4)))
        XCTAssertEqual(try MCPCaptureTarget(MCPArguments(["window_id": 99])),.window(id: 99,app: nil,title: nil))
        XCTAssertEqual(try MCPCaptureTarget(MCPArguments(["app": "Safari","title": "Docs"])),.window(id: nil,app: "Safari",title: "Docs"))
        XCTAssertEqual(try MCPCaptureTarget(MCPArguments(["target": "active_window"])),.activeWindow)
        XCTAssertThrowsError(try MCPCaptureTarget(MCPArguments(["target": "window"])))
        XCTAssertThrowsError(try MCPCaptureTarget(MCPArguments(["target": "area"])))
        XCTAssertThrowsError(try MCPCaptureTarget(MCPArguments(["target": "printer"])))
        XCTAssertTrue(MCPCaptureTarget.matches("safari",name: "Safari",bundle: "com.apple.Safari"))
        XCTAssertTrue(MCPCaptureTarget.matches("com.apple.safari",name: nil,bundle: "com.apple.Safari"))
        XCTAssertFalse(MCPCaptureTarget.matches("chrome",name: "Safari",bundle: "com.apple.Safari"))
    }
    func testPreviewSizingNeverUpscalesAndKeepsAspect() {
        XCTAssertEqual(ImageFit.size(width: 5120,height: 2880,maxDimension: 1568).width,1568)
        XCTAssertEqual(ImageFit.size(width: 5120,height: 2880,maxDimension: 1568).height,882)
        XCTAssertEqual(ImageFit.size(width: 1000,height: 3000,maxDimension: 1500).width,500)
        XCTAssertEqual(ImageFit.size(width: 800,height: 600,maxDimension: 1568).width,800)
        XCTAssertEqual(ImageFit.size(width: 10000,height: 1,maxDimension: 100).height,1)
    }
    func testVisionBoxesMapToTopLeftFrames() {
        let frame = CGRect(x: 100,y: 50,width: 1000,height: 500)
        XCTAssertEqual(ImageFit.topLeft(CGRect(x: 0,y: 0.9,width: 0.5,height: 0.1),in: frame),CGRect(x: 100,y: 50,width: 500,height: 50))
        XCTAssertEqual(ImageFit.topLeft(CGRect(x: 0.5,y: 0,width: 0.5,height: 0.2),in: frame),CGRect(x: 600,y: 450,width: 500,height: 100))
    }
    func testEditURLRoundTripsAbsolutePathsOnly() {
        let url = LaunchAction.editURL(path: "/Users/me/Shots/A b#c?.png")!
        XCTAssertEqual(LaunchAction.editPath(url),"/Users/me/Shots/A b#c?.png")
        XCTAssertNil(LaunchAction(url: url))
        XCTAssertNil(LaunchAction.editPath(URL(string: "shotglass://edit?path=relative.png")!))
        XCTAssertNil(LaunchAction.editPath(URL(string: "shotglass://edit?path=/a.png&path=/b.png")!))
        XCTAssertNil(LaunchAction.editPath(URL(string: "shotglass://capture?path=/a.png")!))
    }
}

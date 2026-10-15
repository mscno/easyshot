import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import EasyshotCore

final class SecretScannerTests: XCTestCase {
    let scanner = SecretScanner()
    func kinds(_ text: String, _ scanner: SecretScanner = SecretScanner()) -> [SecretScanner.Kind] { scanner.scan(text).map(\.kind) }
    func texts(_ text: String) -> [String] { scanner.scan(text).map(\.text) }

    func testProviderKeys() {
        let samples = [
            "OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz123456",
            "token ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789",
            "github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP",
            "slack xoxb-1234567890-abcdefghij",
            "aws AKIAIOSFODNN7EXAMPLE here",
            "maps AIzaSyA1234567890abcdefghijklmnopqrstuv",
            "stripe sk_live_51HabcdefGHIJKLmnop",
            "restricted rk_live_abcdefghijklmnop123",
        ]
        for sample in samples { XCTAssertTrue(kinds(sample).contains(.apiKey), sample) }
        XCTAssertEqual(texts("aws AKIAIOSFODNN7EXAMPLE here"), ["AKIAIOSFODNN7EXAMPLE"])
    }
    func testJWTAndPrivateKey() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        XCTAssertEqual(kinds("Authorization: Bearer \(jwt)"), [.jwt])
        XCTAssertEqual(kinds("-----BEGIN RSA PRIVATE KEY-----"), [.privateKey])
        XCTAssertEqual(kinds("-----BEGIN OPENSSH PRIVATE KEY-----"), [.privateKey])
    }
    func testPasswordAssignmentsRedactOnlyTheValue() {
        XCTAssertEqual(texts("password=hunter22"), ["hunter22"])
        XCTAssertEqual(texts("DB_PASSWORD: \"s3cr3t!\""), ["s3cr3t!"])
        XCTAssertEqual(kinds("api_key = abcd1234"), [.password])
    }
    func testPersonalData() {
        XCTAssertEqual(texts("Contact mads@example.com today"), ["mads@example.com"])
        XCTAssertEqual(kinds("ssh root@10.0.12.7"), [.ipv4])
        XCTAssertEqual(texts("ssh root@10.0.12.7"), ["10.0.12.7"])
        XCTAssertEqual(kinds("listen [2001:db8:85a3:0:0:8a2e:370:7334]:443"), [.ipv6])
        XCTAssertEqual(kinds("curl http://[::1]:8080"), [.ipv6])
        XCTAssertEqual(kinds("card 4242 4242 4242 4242 exp"), [.creditCard])
        XCTAssertEqual(kinds("card 4111-1111-1111-1111"), [.creditCard])
    }
    func testFalsePositivesAreIgnored() {
        XCTAssertEqual(kinds("card 4242 4242 4242 4241"), [], "fails Luhn")
        XCTAssertEqual(kinds("version 1.2.3 and 300.1.1.1"), [], "300 is not an octet")
        XCTAssertEqual(kinds("v01.02.03.04"), [], "leading zeros look like versions")
        XCTAssertEqual(kinds("meeting at 12:30:45"), [], "clock times are not IPv6")
        XCTAssertEqual(kinds("std::vector<int> Foo::Bar"), [])
        XCTAssertEqual(kinds("/Users/madsschou/projects/easyshot/Sources/Easyshot"), [])
        XCTAssertEqual(kinds("ThisIsAVeryLongCamelCaseIdentifierName"), [], "plain words lack digits")
        XCTAssertEqual(kinds("phone +47 22 33 44 55"), [])
        XCTAssertEqual(kinds("color #ff8800 and 0xdeadbeef"), [])
    }
    func testUUIDsAndGitSHAsAreConfigurable() {
        let uuid = "id 3f2504e0-4f89-11d3-9a0c-0305e82c3301"
        let sha = "commit 8c9667a0c3b2f9d1e4a5b6c7d8e9f0a1b2c3d4e5 and 6ef6e5e"
        XCTAssertEqual(kinds(uuid), [])
        XCTAssertEqual(kinds(sha), [], "hex SHAs never count as random tokens")
        XCTAssertEqual(kinds(uuid, SecretScanner(includeUUIDs: true)), [.uuid])
        XCTAssertEqual(kinds(sha, SecretScanner(includeGitSHAs: true)), [.gitSHA, .gitSHA])
    }
    func testHighEntropyTokens() {
        XCTAssertEqual(kinds("export TOKEN_VALUE Zx9Qw2Lp8Rt5Vy7Nm3Kb6Hc4Jd1Fg0"), [.highEntropy])
        XCTAssertEqual(texts("session=Ab3dEf9hIj2kLm5nOp8qRs1tUv4w"), ["Ab3dEf9hIj2kLm5nOp8qRs1tUv4w"])
    }
    func testRangesPointIntoTheLine() {
        let line = "user mads@example.com key sk-abcdefghijklmnopqrstuvwx"
        for match in scanner.scan(line) { XCTAssertEqual(String(line[match.range]), match.text) }
        XCTAssertEqual(scanner.scan(line).count, 2)
    }
    func testLuhnAndEntropy() {
        XCTAssertTrue(SecretScanner.luhn("4242424242424242"))
        XCTAssertFalse(SecretScanner.luhn("4242424242424241"))
        XCTAssertFalse(SecretScanner.luhn("42"))
        XCTAssertEqual(SecretScanner.entropy("aaaa"), 0)
        XCTAssertEqual(SecretScanner.entropy("abcd"), 2, accuracy: 0.0001)
    }
    /// The upload type is sniffed from bytes: a PNG renamed .gif is still scanned and labelled as a PNG.
    func testUploadTypeComesFromTheBytes() throws {
        func encode(_ type: UTType,frames: Int) throws -> Data {
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data,type.identifier as CFString,frames,nil))
            let ctx = try XCTUnwrap(CGContext(data: nil,width: 4,height: 4,bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            for _ in 0..<frames { CGImageDestinationAddImage(destination,try XCTUnwrap(ctx.makeImage()),nil) }
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return data as Data
        }
        func sniff(_ data: Data) throws -> (String?,Int) {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
            return (UploadImageType.mime(forTypeIdentifier: try XCTUnwrap(CGImageSourceGetType(source)) as String),CGImageSourceGetCount(source))
        }
        XCTAssertEqual(try sniff(encode(.png,frames: 1)).0,"image/png")
        XCTAssertEqual(try sniff(encode(.jpeg,frames: 1)).0,"image/jpeg")
        let gif = try sniff(encode(.gif,frames: 3))
        XCTAssertEqual(gif.0,"image/gif"); XCTAssertEqual(gif.1,3)
        XCTAssertNil(try sniff(encode(.tiff,frames: 1)).0,"TIFF is re-encoded as PNG before upload")
        XCTAssertGreaterThan(UploadImageType.maxScannedFrames,1)
    }
}

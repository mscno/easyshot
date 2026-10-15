import XCTest
@testable import EasyshotCore

final class ShareUploadTests: XCTestCase {
    let MiB = 1024*1024
    func testPartsAreAtLeastFiveMiBExceptTheLast() {
        var planner = PartPlanner()
        XCTAssertEqual(planner.parts(upTo: 4*MiB),[])
        XCTAssertEqual(planner.parts(upTo: 5*MiB-1),[])
        XCTAssertEqual(planner.parts(upTo: 11*MiB),[PartPlanner.Part(number: 1,range: 0..<5*MiB),PartPlanner.Part(number: 2,range: 5*MiB..<10*MiB)])
        XCTAssertEqual(planner.parts(upTo: 12*MiB),[])
        XCTAssertEqual(planner.finish(total: 12*MiB+7),[PartPlanner.Part(number: 3,range: 10*MiB..<12*MiB+7)])
        XCTAssertEqual(planner.parts(upTo: 40*MiB),[],"nothing after finish")
    }
    func testFinishOnExactBoundaryAddsNoEmptyPart() {
        var planner = PartPlanner()
        _ = planner.parts(upTo: 10*MiB)
        XCTAssertEqual(planner.finish(total: 10*MiB),[])
        XCTAssertEqual(planner.nextNumber,3)
    }
    func testEmptyAndSmallStreamsStillHaveOnePart() {
        XCTAssertEqual(PartPlanner.whole(size: 0),[PartPlanner.Part(number: 1,range: 0..<0)])
        XCTAssertEqual(PartPlanner.whole(size: 300),[PartPlanner.Part(number: 1,range: 0..<300)])
    }
    func testPartSizeNeverBelowS3Minimum() {
        XCTAssertEqual(PartPlanner(partSize: 1024).partSize,PartPlanner.minimumPartSize)
        let parts = PartPlanner.whole(size: 17*MiB,partSize: 8*MiB)
        XCTAssertEqual(parts.map(\.range.count),[8*MiB,8*MiB,MiB])
        XCTAssertEqual(parts.map(\.number),[1,2,3])
    }
    func testLedgerTracksPendingAndSortsCompletion() {
        var ledger = PartLedger()
        XCTAssertFalse(ledger.isComplete,"an upload with no parts is not complete")
        for n in [1,2,3] { ledger.expect(n) }
        ledger.record(3,etag: "\"c\""); ledger.record(1,etag: "\"a\"")
        XCTAssertEqual(ledger.pending,[2]); XCTAssertFalse(ledger.isComplete)
        ledger.record(2,etag: "\"b\""); ledger.record(2,etag: "\"b2\"")
        XCTAssertTrue(ledger.isComplete)
        XCTAssertEqual(ledger.completed.map(\.number),[1,2,3])
        XCTAssertEqual(ledger.completed.map(\.etag),["\"a\"","\"b2\"","\"c\""],"quotes are kept and a retried part's newest ETag wins")
    }
    func testBackoffDoublesToCapWithBoundedJitter() {
        let b = Backoff()
        XCTAssertEqual(b.delay(attempt: 0),0.5,accuracy: 1e-9)
        XCTAssertEqual(b.delay(attempt: 3),4,accuracy: 1e-9)
        XCTAssertEqual(b.delay(attempt: 30),20,accuracy: 1e-9)
        XCTAssertEqual(b.delay(attempt: 2,unit: 0),1.6,accuracy: 1e-9)
        XCTAssertEqual(b.delay(attempt: 2,unit: 1),2.4,accuracy: 1e-9)
        XCTAssertTrue(Backoff.retryable(status: 0)); XCTAssertTrue(Backoff.retryable(status: 503)); XCTAssertTrue(Backoff.retryable(status: 403))
        XCTAssertFalse(Backoff.retryable(status: 400)); XCTAssertFalse(Backoff.retryable(status: 404))
        XCTAssertTrue(Backoff.retryable(status: 429))
        XCTAssertTrue(Backoff.transient(.timedOut)); XCTAssertTrue(Backoff.transient(.networkConnectionLost)); XCTAssertTrue(Backoff.transient(.notConnectedToInternet))
        XCTAssertFalse(Backoff.transient(.cancelled)); XCTAssertFalse(Backoff.transient(.serverCertificateUntrusted)); XCTAssertFalse(Backoff.transient(.badURL))
    }
    func testVTTFormatting() {
        XCTAssertEqual(WebVTT.timestamp(3725.4567),"01:02:05.457")
        let doc = WebVTT.document([WebVTT.Cue(start: 0,end: 1.5,text: "Hello --> world")])
        XCTAssertEqual(doc,"WEBVTT\n\n1\n00:00:00.000 --> 00:00:01.500\nHello → world\n")
    }
    func testLongPhrasesSplitIntoTimedCues() {
        let text = (1...30).map { "word\($0)" }.joined(separator: " ")
        let cues = WebVTT.cues([WebVTT.Cue(start: 10,end: 20,text: text),WebVTT.Cue(start: 21,end: 21,text: "dropped"),WebVTT.Cue(start: 22,end: 23,text: "  ")],maxCharacters: 40)
        XCTAssertGreaterThan(cues.count,1)
        XCTAssertTrue(cues.allSatisfy { $0.text.count <= 40 })
        XCTAssertEqual(cues.first?.start,10); XCTAssertEqual(cues.last?.end,20)
        for (a,b) in zip(cues,cues.dropFirst()) { XCTAssertEqual(a.end,b.start,accuracy: 1e-9) }
        XCTAssertEqual(cues.map(\.text).joined(separator: " "),text)
    }
    func testGitHubMarkdown() {
        XCTAssertEqual(ShareLinks.thumbnail("https://easyshot.app/v/abc/"),"https://easyshot.app/v/abc/thumbnail.jpg")
        XCTAssertEqual(ShareLinks.githubMarkdown(title: "Fix [login] bug",shareURL: "https://easyshot.app/v/abc"),
                       "[![Fix \\[login\\] bug](https://easyshot.app/v/abc/thumbnail.jpg)](https://easyshot.app/v/abc)")
        XCTAssertEqual(ShareLinks.githubMarkdown(title: "",shareURL: "https://x/v/1"),"[![Recording](https://x/v/1/thumbnail.jpg)](https://x/v/1)")
    }
}

import XCTest
@testable import EasyshotCore

final class AudioMixTimelineTests: XCTestCase {
    func stereo(_ value: Float,frames: Int) -> [Float] { Array(repeating: value,count: frames*2) }
    func testWaitsForEverySourceThenSumsWithGains() {
        var mix = AudioMixTimeline(gains: [0.5,1],maxLag: 1000)
        mix.write(0,start: 0,stereo: stereo(0.2,frames: 100))
        XCTAssertEqual(mix.available(final: false),100,"one active source releases on its own")
        mix.write(1,start: 0,stereo: stereo(0.3,frames: 40))
        XCTAssertEqual(mix.available(final: false),40,"the second source holds output back to where both arrived")
        let out = mix.read(upTo: 40,maxFrames: 1000)
        XCTAssertEqual(out?.start,0)
        XCTAssertEqual(out?.stereo.count,80)
        XCTAssertEqual(out?.stereo.first ?? 0,0.4,accuracy: 1e-6)
        XCTAssertEqual(mix.emitted,40)
    }
    func testLaggingSourceIsSilenceAfterMaxLag() {
        var mix = AudioMixTimeline(gains: [1,1],maxLag: 50)
        mix.write(0,start: 0,stereo: stereo(0.1,frames: 10))
        mix.write(1,start: 0,stereo: stereo(0.1,frames: 200))
        XCTAssertEqual(mix.available(final: false),150,"a stalled source delays output by at most maxLag")
        let out = mix.read(upTo: 150,maxFrames: 1000)!
        XCTAssertEqual(out.stereo[0],0.2,accuracy: 1e-6)
        XCTAssertEqual(out.stereo[2*20],0.1,accuracy: 1e-6,"after source 0 ends, only source 1")
        XCTAssertEqual(mix.available(final: true),200)
    }
    func testGapsAreSilenceLateSamplesAreDroppedAndOverlapKeepsEarlier() {
        var mix = AudioMixTimeline(gains: [1],maxLag: 0)
        mix.write(0,start: 10,stereo: stereo(0.5,frames: 10))
        XCTAssertEqual(mix.end(of: 0),20)
        let first = mix.read(upTo: 20,maxFrames: 100)!
        XCTAssertEqual(first.stereo[0],0,"frames before the first sample are silence")
        XCTAssertEqual(first.stereo[2*15],0.5,accuracy: 1e-6)
        mix.write(0,start: 15,stereo: stereo(0.25,frames: 10))
        XCTAssertEqual(mix.end(of: 0),25,"frames before emitted are dropped")
        mix.write(0,start: 22,stereo: stereo(0.75,frames: 6))
        XCTAssertEqual(mix.end(of: 0),28,"an overlap keeps the earlier samples")
        let second = mix.read(upTo: 28,maxFrames: 100)!
        XCTAssertEqual(second.stereo[2*4],0.25,accuracy: 1e-6)
        XCTAssertEqual(second.stereo[2*6],0.75,accuracy: 1e-6)
    }
    func testChunksAndLimiter() {
        var mix = AudioMixTimeline(gains: [1,1],maxLag: 0)
        mix.write(0,start: 0,stereo: stereo(0.9,frames: 30))
        mix.write(1,start: 0,stereo: stereo(0.9,frames: 30))
        let a = mix.read(upTo: 30,maxFrames: 20)!,b = mix.read(upTo: 30,maxFrames: 20)!
        XCTAssertEqual(a.stereo.count,40); XCTAssertEqual(b.start,20); XCTAssertEqual(b.stereo.count,20)
        XCTAssertNil(mix.read(upTo: 30,maxFrames: 20))
        XCTAssertLessThan(a.stereo[0],1,"summed peaks bend below full scale")
        XCTAssertGreaterThan(a.stereo[0],0.95)
        XCTAssertEqual(AudioMixTimeline.limit(0.5),0.5)
        XCTAssertEqual(AudioMixTimeline.limit(-3),-AudioMixTimeline.limit(3))
        XCTAssertLessThan(AudioMixTimeline.limit(100),1.0001)
    }
}

final class ProgressThrottleTests: XCTestCase {
    typealias R = ProgressThrottle.Report
    func testAtMostOncePerIntervalCoalescedToLatest() {
        var t = ProgressThrottle(interval: 1)
        XCTAssertEqual(t.update(R(uploadedBytes: 1,recording: true),now: 0),R(uploadedBytes: 1,recording: true))
        XCTAssertNil(t.update(R(uploadedBytes: 2,recording: true),now: 0.2))
        XCTAssertNil(t.update(R(uploadedBytes: 3,recording: true),now: 0.5))
        XCTAssertEqual(t.deadline,1)
        XCTAssertNil(t.flush(now: 0.9))
        XCTAssertEqual(t.flush(now: 1.0),R(uploadedBytes: 3,recording: true),"only the latest value is sent")
        XCTAssertNil(t.flush(now: 5)); XCTAssertNil(t.deadline)
        XCTAssertNil(t.update(R(uploadedBytes: 3,recording: true),now: 9),"unchanged values are dropped")
        XCTAssertEqual(t.update(R(uploadedBytes: 4,recording: true),now: 9),R(uploadedBytes: 4,recording: true))
    }
    func testStopIsSentImmediatelyOnce() {
        var t = ProgressThrottle(interval: 1)
        _ = t.update(R(uploadedBytes: 1,recording: true),now: 0)
        XCTAssertEqual(t.update(R(uploadedBytes: 1,recording: false),now: 0.1),R(uploadedBytes: 1,recording: false))
        XCTAssertNil(t.update(R(uploadedBytes: 2,recording: false),now: 0.2),"later reports are throttled again")
        XCTAssertEqual(t.flush(now: 1.1),R(uploadedBytes: 2,recording: false))
    }
    func testDisabledSendsNothing() {
        var t = ProgressThrottle()
        _ = t.update(R(uploadedBytes: 1,recording: true),now: 0)
        _ = t.update(R(uploadedBytes: 2,recording: true),now: 0.1)
        t.disable()
        XCTAssertNil(t.deadline)
        XCTAssertNil(t.flush(now: 10))
        XCTAssertNil(t.update(R(uploadedBytes: 3,recording: false),now: 11))
    }
}

final class UploadJournalTests: XCTestCase {
    let MiB = 1024*1024
    func testReusesOnlyPartsMatchingThePlan() throws {
        var journal = UploadJournal(videoID: "v",partSize: 5*MiB)
        journal.record(PartPlanner.Part(number: 1,range: 0..<5*MiB),etag: "\"a\"")
        journal.record(PartPlanner.Part(number: 2,range: 5*MiB..<10*MiB),etag: "\"b\"")
        journal.record(PartPlanner.Part(number: 3,range: 10*MiB..<11*MiB),etag: "\"c\"")
        journal.record(PartPlanner.Part(number: 2,range: 5*MiB..<10*MiB),etag: "\"b2\"")
        XCTAssertEqual(journal.parts.count,3,"a re-uploaded part replaces its entry")
        XCTAssertEqual(journal.reusable(size: 12*MiB),[1: "\"a\"",2: "\"b2\""],"a last part of a different length is uploaded again")
        XCTAssertEqual(journal.reusable(size: 11*MiB),[1: "\"a\"",2: "\"b2\"",3: "\"c\""])
        XCTAssertEqual(journal.reusable(size: 3*MiB),[:],"a shorter file reuses nothing")
        let round = try JSONDecoder().decode(UploadJournal.self,from: JSONEncoder().encode(journal))
        XCTAssertEqual(round,journal)
    }
    func testJournalSitsHiddenBesideTheRecording() {
        let url = UploadJournal.url(for: URL(fileURLWithPath: "/tmp/Shots/Easyshot 1.mp4"))
        XCTAssertEqual(url.path,"/tmp/Shots/.Easyshot 1.mp4.easyshot-upload.json")
    }
}

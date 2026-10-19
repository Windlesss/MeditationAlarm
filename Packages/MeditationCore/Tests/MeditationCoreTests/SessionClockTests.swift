import XCTest
@testable import MeditationCore

final class SessionClockTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    // MARK: 核心验收：计时精度

    func testElapsedIsExactAfter30Minutes() {
        var clock = SessionClock.start(at: t0, plannedDuration: 1800, interval: nil)
        clock = clock.pausing(at: t0.addingTimeInterval(1800))
        // 验收标准 1：误差 < 1 秒，这里是 0
        XCTAssertEqual(clock.elapsed(at: t0.addingTimeInterval(1800)), 1800, accuracy: .ulpOfOne)
    }

    func testElapsedSurvivesLongBackgroundSpan() {
        let clock = SessionClock.start(at: t0, plannedDuration: nil, interval: nil)
        let eightHoursLater = t0.addingTimeInterval(8 * 3600)
        XCTAssertEqual(clock.elapsed(at: eightHoursLater), 8 * 3600, accuracy: 0.001)
    }

    func testElapsedClampsToPlannedDuration() {
        let clock = SessionClock.start(at: t0, plannedDuration: 1800, interval: nil)
        // 到点后即便过了很久，显示也停在 30:00
        XCTAssertEqual(clock.elapsed(at: t0.addingTimeInterval(9999)), 1800, accuracy: .ulpOfOne)
    }

    func testElapsedNeverNegativeOnClockRollback() {
        let clock = SessionClock.start(at: t0, plannedDuration: nil, interval: nil)
        XCTAssertEqual(clock.elapsed(at: t0.addingTimeInterval(-30)), 0)
    }

    // MARK: 暂停

    func testPauseExcludesPausedTime() {
        var clock = SessionClock.start(at: t0, plannedDuration: nil, interval: nil)
        clock = clock.pausing(at: t0 + 600)      // 冥想 10 分钟
        clock = clock.resuming(at: t0 + 900)     // 暂停 5 分钟
        clock = clock.pausing(at: t0 + 1500)     // 再冥想 10 分钟
        XCTAssertEqual(clock.elapsed(at: t0 + 9999), 1200, accuracy: .ulpOfOne)
    }

    func testPauseTwiceIsIdempotent() {
        var clock = SessionClock.start(at: t0, plannedDuration: nil, interval: nil)
        clock = clock.pausing(at: t0 + 60)
        let once = clock
        clock = clock.pausing(at: t0 + 120)
        XCTAssertEqual(clock.elapsed(at: t0 + 9999), 60, accuracy: .ulpOfOne)
        XCTAssertEqual(once.accumulated, clock.accumulated)
    }

    func testResumeWhileRunningIsNoOp() {
        let clock = SessionClock.start(at: t0, plannedDuration: nil, interval: nil)
        XCTAssertEqual(clock.resuming(at: t0 + 10), clock)
    }

    func testCannotResumeAfterReachingPlannedDuration() {
        var clock = SessionClock.start(at: t0, plannedDuration: 600, interval: nil)
        clock = clock.pausing(at: t0 + 600)
        XCTAssertEqual(clock.resuming(at: t0 + 700), clock)
    }

    // MARK: 结束与 HealthKit 分段

    func testSegmentsSplitCorrectly() {
        var clock = SessionClock.start(at: t0, plannedDuration: nil, interval: nil)
        clock = clock.pausing(at: t0 + 600)
        clock = clock.resuming(at: t0 + 900)
        let (_, segments) = clock.ending(at: t0 + 1500)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].duration, 600, accuracy: .ulpOfOne)
        XCTAssertEqual(segments[1].duration, 600, accuracy: .ulpOfOne)
    }

    func testSubThresholdSegmentsAreDroppedFromHealthWrite() {
        var clock = SessionClock.start(at: t0, plannedDuration: nil, interval: nil)
        clock = clock.pausing(at: t0 + 20)          // 试了一下就放弃
        clock = clock.resuming(at: t0 + 60)
        clock = clock.pausing(at: t0 + 660)         // 再认真冥想 10 分钟
        let (_, segments) = clock.ending(at: t0 + 9999)

        let billable = SessionClock.billableDuration(segments)
        XCTAssertEqual(SessionClock.writableSegments(segments).count, 1)
        XCTAssertEqual(billable, 600, accuracy: .ulpOfOne)   // 而不是 620
    }

    func testEndingTrimsLastSegmentToPlannedDuration() {
        var clock = SessionClock.start(at: t0, plannedDuration: 600, interval: nil)
        clock = clock.pausing(at: t0 + 300)
        clock = clock.resuming(at: t0 + 400)
        let (ended, segments) = clock.ending(at: t0 + 1200)

        XCTAssertEqual(ended.elapsed(at: t0 + 9999), 600, accuracy: .ulpOfOne)
        XCTAssertEqual(segments.reduce(0) { $0 + $1.duration }, 600, accuracy: .ulpOfOne)
    }

    // MARK: 倒计时相关

    func testEndDateAndRemaining() {
        let clock = SessionClock.start(at: t0, plannedDuration: 1800, interval: nil)
        XCTAssertEqual(try XCTUnwrap(clock.remaining(at: t0 + 600)), 1200, accuracy: .ulpOfOne)
        XCTAssertEqual(clock.endDate(from: t0 + 600), t0 + 1800)
    }

    func testPerpetualSessionHasNoEnd() {
        let clock = SessionClock.start(at: t0, plannedDuration: nil, interval: nil)
        XCTAssertNil(clock.endDate(from: t0 + 100))
        XCTAssertNil(clock.remaining(at: t0 + 100))
        XCTAssertNil(clock.progress(at: t0 + 100))
        XCTAssertFalse(clock.isFinished(at: t0 + 999_999))
    }
}

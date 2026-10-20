import XCTest
@testable import MeditationCore

/// 正念分钟数分段写入策略（第三阶段 v3a）。
///
/// 配套纯函数：短于阈值的区间不写（试试 10 秒就放弃不该记账）；
/// 暂停不在任何区间内 —— 这是正念分钟数不虚报的关键。
final class WritableSegmentsTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 2_000_000)

    private func seg(_ duration: TimeInterval, offset: TimeInterval = 0) -> TimedSegment {
        TimedSegment(
            start: t0.addingTimeInterval(offset),
            end: t0.addingTimeInterval(offset + duration)
        )
    }

    func testSegmentsBelowThresholdAreDropped() {
        XCTAssertTrue(SessionClock.writableSegments([seg(59.9)]).isEmpty)
    }

    func testSegmentAtThresholdIsKept() {
        XCTAssertEqual(SessionClock.writableSegments([seg(60)]).count, 1)
    }

    func testMixedSegmentsKeepOnlyLongOnes() {
        let segments = [seg(30), seg(60, offset: 100), seg(90, offset: 200)]
        let writable = SessionClock.writableSegments(segments)
        XCTAssertEqual(writable.count, 2)
        XCTAssertEqual(writable.map { $0.duration }, [60, 90])
    }

    func testBillableDurationSumsWritableOnly() {
        let segments = [seg(30), seg(120), seg(60)]
        XCTAssertEqual(SessionClock.billableDuration(segments), 180)
    }

    func testPauseTimeIsNotInAnySegment() {
        // 冥想 15 分钟、中途暂停 10 分钟 → 只写 15 分钟，不写 25 分钟
        let segments = [seg(600), seg(300, offset: 1200)]
        XCTAssertEqual(SessionClock.billableDuration(segments), 900)
    }

    func testEmptySegments() {
        XCTAssertTrue(SessionClock.writableSegments([]).isEmpty)
        XCTAssertEqual(SessionClock.billableDuration([]), 0)
    }
}

import XCTest
@testable import MeditationCore

final class IntervalScheduleTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    // MARK: 联动规则

    func testPlannedShorterThanIntervalIsExpandedFiveFold() {
        let r = DurationPolicy.resolve(plannedDuration: 180, interval: 600)
        XCTAssertEqual(r.plannedDuration, 3000)
        XCTAssertTrue(r.wasAdjusted)
        XCTAssertEqual(r.adjustedFrom, 180)
    }

    func testPlannedWithinFiveFoldRangeKeepsUserInput() {
        // Q5：间隔 10 分钟、输入 15 分钟 → 保持 15 分钟
        let r = DurationPolicy.resolve(plannedDuration: 900, interval: 600)
        XCTAssertEqual(r.plannedDuration, 900)
        XCTAssertFalse(r.wasAdjusted)
    }

    func testPerpetualNeverAdjusted() {
        let r = DurationPolicy.resolve(plannedDuration: nil, interval: 600)
        XCTAssertNil(r.plannedDuration)
        XCTAssertFalse(r.wasAdjusted)
    }

    func testNoIntervalNeverAdjusted() {
        let r = DurationPolicy.resolve(plannedDuration: 30, interval: nil)
        XCTAssertEqual(r.plannedDuration, 30)
    }

    // MARK: 下一次提示

    func testNextReminderFiresAtTheRightMoment() {
        let clock = SessionClock.start(at: t0, plannedDuration: 3000, interval: 600)
        let first = IntervalSchedule.nextReminder(clock: clock, from: t0 + 100)
        XCTAssertEqual(first?.index, 1)
        XCTAssertEqual(first?.date, t0 + 600)

        let second = IntervalSchedule.nextReminder(clock: clock, from: t0 + 601)
        XCTAssertEqual(second?.index, 2)
        XCTAssertEqual(second?.date, t0 + 1200)
    }

    func testLastIntervalAtExactEndIsSuppressed() {
        // 计划 10 分钟 + 间隔 5 分钟 → 只在 5:00 响一次，10:00 交给结束音
        let clock = SessionClock.start(at: t0, plannedDuration: 600, interval: 300)
        XCTAssertEqual(IntervalSchedule.nextReminder(clock: clock, from: t0)?.date, t0 + 300)

        var c = clock
        c = c.pausing(at: t0 + 301)
        c = c.resuming(at: t0 + 301)
        XCTAssertNil(IntervalSchedule.nextReminder(clock: c, from: t0 + 305))
    }

    func testReminderIndexSurvivesPause() {
        var clock = SessionClock.start(at: t0, plannedDuration: 3000, interval: 300)
        clock = clock.pausing(at: t0 + 150)     // 2.5 分钟处暂停
        clock = clock.resuming(at: t0 + 1050)   // 暂停 15 分钟后继续
        let next = IntervalSchedule.nextReminder(clock: clock, from: t0 + 1051)
        XCTAssertEqual(next?.index, 1)
        // 已冥想 150 秒，间隔 300 秒 → 还需再冥想 150 秒。
        // 恢复点是 t0+1050，所以下一次应当在 t0+1200，暂停时长完全不影响对齐。
        XCTAssertEqual(next?.date, t0 + 1200)
    }

    func testNoIntervalMeansNoReminder() {
        let clock = SessionClock.start(at: t0, plannedDuration: 600, interval: nil)
        XCTAssertNil(IntervalSchedule.nextReminder(clock: clock, from: t0))
    }

    // MARK: 通知兜底的全量排程

    func testAllRemindersCount() {
        let reminders = IntervalSchedule.allReminders(
            plannedDuration: 1800, interval: 300, sessionStart: t0
        )
        XCTAssertEqual(reminders.count, 5)          // 5/10/15/20/25 分钟
        XCTAssertEqual(reminders.last?.date, t0 + 1500)
    }

    func testPerpetualSchedulesNothing() {
        let reminders = IntervalSchedule.allReminders(
            plannedDuration: nil, interval: 300, sessionStart: t0
        )
        XCTAssertTrue(reminders.isEmpty)
    }

    // MARK: 剩余提示（后台一次排程）

    func testRemainingRemindersFromCurrentProgress() {
        // 30 分钟 / 5 分钟间隔；已过 7 分钟 → 剩 4 发（10/15/20/25）
        let clock = SessionClock.start(at: t0, plannedDuration: 1800, interval: 300)
        let reminders = IntervalSchedule.remainingReminders(clock: clock, from: t0 + 420)
        XCTAssertEqual(reminders.map(\.index), [2, 3, 4, 5])
        XCTAssertEqual(reminders.first?.date, t0 + 600)
        XCTAssertEqual(reminders.last?.date, t0 + 1500)
    }

    func testRemainingRemindersAlignAfterPause() {
        // 暂停 15 分钟后继续：排程按「已冥想时长」对齐，不受墙上时钟影响
        var clock = SessionClock.start(at: t0, plannedDuration: 1800, interval: 300)
        clock = clock.pausing(at: t0 + 150)
        clock = clock.resuming(at: t0 + 1050)
        let reminders = IntervalSchedule.remainingReminders(clock: clock, from: t0 + 1051)
        XCTAssertEqual(reminders.map(\.index), [1, 2, 3, 4, 5])
        XCTAssertEqual(reminders.first?.date, t0 + 1200)   // 恢复后再冥想 150 秒
    }

    func testRemainingRemindersSuppressLastAtExactEnd() {
        // 计划 10 分钟 / 间隔 5 分钟 → 只剩 5:00 一发，10:00 交给结束音
        let clock = SessionClock.start(at: t0, plannedDuration: 600, interval: 300)
        let reminders = IntervalSchedule.remainingReminders(clock: clock, from: t0 + 10)
        XCTAssertEqual(reminders.count, 1)
        XCTAssertEqual(reminders.first?.date, t0 + 300)
    }

    func testRemainingRemindersRespectLimitForPerpetual() {
        // 永久模式排不完，靠 limit 截断
        let clock = SessionClock.start(at: t0, plannedDuration: nil, interval: 300)
        let reminders = IntervalSchedule.remainingReminders(clock: clock, from: t0, limit: 5)
        XCTAssertEqual(reminders.count, 5)
        XCTAssertEqual(reminders.last?.date, t0 + 1500)
    }

    func testNoIntervalMeansNoRemaining() {
        let clock = SessionClock.start(at: t0, plannedDuration: 600, interval: nil)
        XCTAssertTrue(IntervalSchedule.remainingReminders(clock: clock, from: t0).isEmpty)
    }
}

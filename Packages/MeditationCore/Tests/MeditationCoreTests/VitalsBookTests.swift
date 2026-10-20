import XCTest
@testable import MeditationCore

final class VitalsBookTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func reading(
        _ kind: VitalKind = .heartRate,
        value: Double = 66,
        offset: TimeInterval = 0,
        id: String? = "A"
    ) -> VitalReading {
        VitalReading(
            kind: kind,
            value: value,
            startDate: t0.addingTimeInterval(offset),
            endDate: t0.addingTimeInterval(offset),
            sourceID: id
        )
    }

    // MARK: 去重 —— 本项目最关键的一条逻辑

    func testRepeatedPollOfSameSampleIsRecordedOnce() {
        // 手表 10 分钟才写一条 HRV，我们每 30 秒捞一次 → 同一条被捞 20 次
        var book = VitalsBook()
        let sample = reading(.hrvSDNN, value: 42, offset: 300, id: "hrv-1")

        var accepted = 0
        for _ in 0..<20 where book.ingest(sample) { accepted += 1 }

        XCTAssertEqual(accepted, 1, "同一条样本只能入库一次")
        XCTAssertEqual(book.count(of: .hrvSDNN), 1, "不去重会画出虚假平线")
    }

    func testConcurrentSamplesWithDifferentIDsAreBothKept() {
        var book = VitalsBook()
        XCTAssertTrue(book.ingest(reading(value: 66, offset: 0, id: "A")))
        XCTAssertTrue(book.ingest(reading(value: 70, offset: 5, id: "B")))
        XCTAssertEqual(book.count(of: .heartRate), 2)
    }

    func testFallsBackToTimeAndValueWhenNoID() {
        var book = VitalsBook()
        XCTAssertTrue(book.ingest(reading(value: 66, offset: 100, id: nil)))
        XCTAssertFalse(book.ingest(reading(value: 66, offset: 100, id: nil)))
        XCTAssertTrue(book.ingest(reading(value: 66, offset: 101, id: nil)))
        XCTAssertEqual(book.count(of: .heartRate), 2)
    }

    // MARK: 脏样本过滤

    func testZeroAndNegativeValuesAreRejected() {
        var book = VitalsBook()
        XCTAssertFalse(book.ingest(reading(value: 0, id: "z")))
        XCTAssertFalse(book.ingest(reading(value: -5, id: "n")))
        XCTAssertTrue(book.isEmpty, "HealthKit 异常返回的 0 不应入库")
    }

    func testImplausibleValuesAreRejected() {
        var book = VitalsBook()
        XCTAssertFalse(book.ingest(reading(.heartRate, value: 3000, id: "x")))   // 心率 3000 bpm
        XCTAssertFalse(book.ingest(reading(.hrvSDNN, value: 0.01, id: "y")))     // HRV 0.01 ms
        XCTAssertFalse(book.ingest(reading(value: .nan, id: "nan")))
        XCTAssertTrue(book.isEmpty)
    }

    func testBatchReturnsAcceptedCount() {
        var book = VitalsBook()
        let batch = [
            reading(value: 66, offset: 0, id: "1"),
            reading(value: 67, offset: 10, id: "2"),
            reading(value: 68, offset: 20, id: "2"),   // 重复
        ]
        XCTAssertEqual(book.ingest(batch), 2)
    }

    // MARK: 可见性规则 (FR-10.5)

    func testNoDataHidesEverything() {
        let book = VitalsBook()
        XCTAssertEqual(book.presentation(of: .heartRate, sessionStart: t0), .hidden)
        XCTAssertEqual(book.presentation(of: .hrvSDNN, sessionStart: t0), .hidden)
    }

    func testSinglePointShowsValueNotChart() {
        var book = VitalsBook()
        _ = book.ingest(reading(value: 63, offset: 60))
        XCTAssertEqual(book.presentation(of: .heartRate, sessionStart: t0), .single(value: 63))
    }

    func testSeriesSortedByRelativeTime() {
        var book = VitalsBook()
        _ = book.ingest(reading(value: 70, offset: 600, id: "c"))
        _ = book.ingest(reading(value: 76, offset: 0, id: "a"))
        _ = book.ingest(reading(value: 66, offset: 300, id: "b"))

        guard case .series(let points) = book.presentation(of: .heartRate, sessionStart: t0) else {
            return XCTFail("应为 series")
        }
        XCTAssertEqual(points.map { $0.offsetSeconds }, [0, 300, 600])
        XCTAssertEqual(points.map { $0.value }, [76, 66, 70])
    }

    func testReadingsBeforeSessionStartAreExcluded() {
        var book = VitalsBook()
        _ = book.ingest(reading(value: 76, offset: -120, id: "stale"))   // 冥想开始前 2 分钟
        _ = book.ingest(reading(value: 70, offset: 60, id: "fresh"))
        XCTAssertEqual(book.presentation(of: .heartRate, sessionStart: t0), .single(value: 70))
    }

    func testHrvAndHeartRateAreEvaluatedIndependently() {
        var book = VitalsBook()
        _ = book.ingest(reading(.heartRate, value: 70, offset: 0, id: "h1"))
        _ = book.ingest(reading(.heartRate, value: 66, offset: 300, id: "h2"))

        XCTAssertNotNil(book.presentation(of: .heartRate, sessionStart: t0))
        if case .series = book.presentation(of: .heartRate, sessionStart: t0) {} else { XCTFail() }
        XCTAssertEqual(book.presentation(of: .hrvSDNN, sessionStart: t0), .hidden,
                       "没有 HRV 数据时该区块必须整块隐藏")
    }

    // MARK: 跨启动恢复预热

    func testPrewarmBlocksAlreadyPersistedSamples() {
        var book = VitalsBook()
        book.prewarm(keys: ["u:hrv-1"])
        XCTAssertFalse(book.ingest(reading(.hrvSDNN, value: 42, offset: 300, id: "hrv-1")))
        XCTAssertTrue(book.isEmpty, "已入库的样本恢复后不得二次入库（唯一索引会冲突）")
    }

    // MARK: 单位与文案

    func testUnits() {
        XCTAssertEqual(VitalKind.heartRate.unitLabel, "bpm")
        XCTAssertEqual(VitalKind.hrvSDNN.unitLabel, "ms")
        XCTAssertEqual(VitalKind.heartRate.displayName, "心率")
    }
}

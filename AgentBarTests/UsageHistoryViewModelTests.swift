import XCTest
@testable import AgentBar

final class UsageHistoryViewModelTests: XCTestCase {
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        gregorian.firstWeekday = 1
        calendar = gregorian
    }

    @MainActor
    func testHeatmapCellCountAndLevelMapping() async {
        let now = makeDate(2026, 2, 19, 12, 0)
        let service: ServiceType = .codex
        let records = [
            makeDayRecord(service: service, dayStart: makeDate(2026, 2, 15, 0, 0), primaryPeak: 0),
            makeDayRecord(service: service, dayStart: makeDate(2026, 2, 16, 0, 0), primaryPeak: 0.2),
            makeDayRecord(service: service, dayStart: makeDate(2026, 2, 17, 0, 0), primaryPeak: 0.5),
            makeDayRecord(service: service, dayStart: makeDate(2026, 2, 18, 0, 0), primaryPeak: 0.75),
            makeDayRecord(service: service, dayStart: makeDate(2026, 2, 19, 0, 0), primaryPeak: 1.0)
        ]

        let store = MockUsageHistoryStore(dayRecordsStorage: records, secondarySamplesStorage: [])
        let vm = UsageHistoryViewModel(store: store, calendar: calendar, nowProvider: { now })
        vm.selectedRangeWeeks = 4
        vm.selectedWindow = .primary
        await vm.refresh()

        guard let panel = panel(for: service, in: vm) else {
            XCTFail("Expected a panel for \(service.rawValue)")
            return
        }
        XCTAssertEqual(panel.heatmapCells.count, 28)

        let byDay = Dictionary(uniqueKeysWithValues: panel.heatmapCells.map { (calendar.startOfDay(for: $0.date), $0) })
        XCTAssertEqual(byDay[makeDate(2026, 2, 15, 0, 0)]?.level, 0)
        XCTAssertEqual(byDay[makeDate(2026, 2, 16, 0, 0)]?.level, 1)
        XCTAssertEqual(byDay[makeDate(2026, 2, 17, 0, 0)]?.level, 2)
        XCTAssertEqual(byDay[makeDate(2026, 2, 18, 0, 0)]?.level, 3)
        XCTAssertEqual(byDay[makeDate(2026, 2, 19, 0, 0)]?.level, 4)
    }

    @MainActor
    func testDailySummaryCalculatesExpectedMetrics() async {
        let now = makeDate(2026, 2, 19, 12, 0)
        let service: ServiceType = .codex
        let records = [
            makeDayRecord(service: service, dayStart: makeDate(2026, 2, 15, 0, 0), primaryPeak: 1.0),
            makeDayRecord(service: service, dayStart: makeDate(2026, 2, 16, 0, 0), primaryPeak: 0.85),
            makeDayRecord(service: service, dayStart: makeDate(2026, 2, 17, 0, 0), primaryPeak: 0.4),
            makeDayRecord(service: service, dayStart: makeDate(2026, 2, 18, 0, 0), primaryPeak: 0.0),
            makeDayRecord(service: service, dayStart: makeDate(2026, 2, 19, 0, 0), primaryPeak: 1.0)
        ]

        let store = MockUsageHistoryStore(dayRecordsStorage: records, secondarySamplesStorage: [])
        let vm = UsageHistoryViewModel(store: store, calendar: calendar, nowProvider: { now })
        vm.selectedRangeWeeks = 4
        vm.selectedWindow = .primary
        await vm.refresh()

        guard let panel = panel(for: service, in: vm) else {
            XCTFail("Expected a panel for \(service.rawValue)")
            return
        }
        XCTAssertEqual(panel.dailySummary.limitHitDays, 2)
        XCTAssertEqual(panel.dailySummary.nearLimitDays, 3)
        XCTAssertEqual(panel.dailySummary.lastHitDate, makeDate(2026, 2, 19, 0, 0))
    }

    @MainActor
    func testCycleSummaryComputesCompletionAndStreak() async {
        let now = makeDate(2026, 1, 25, 12, 0)
        let service: ServiceType = .claude
        let reset1 = makeDate(2026, 1, 10, 0, 0)
        let reset2 = makeDate(2026, 1, 17, 0, 0)
        let resetFuture = makeDate(2026, 1, 31, 0, 0)

        let samples = [
            UsageHistorySecondarySample(service: service, sampledAt: makeDate(2026, 1, 4, 8, 0), ratio: 0.2, resetAt: reset1),
            UsageHistorySecondarySample(service: service, sampledAt: makeDate(2026, 1, 6, 8, 0), ratio: 0.85, resetAt: reset1),
            UsageHistorySecondarySample(service: service, sampledAt: makeDate(2026, 1, 8, 8, 0), ratio: 1.0, resetAt: reset1),
            UsageHistorySecondarySample(service: service, sampledAt: makeDate(2026, 1, 11, 8, 0), ratio: 0.3, resetAt: reset2),
            UsageHistorySecondarySample(service: service, sampledAt: makeDate(2026, 1, 15, 8, 0), ratio: 0.82, resetAt: reset2),
            UsageHistorySecondarySample(service: service, sampledAt: makeDate(2026, 1, 20, 8, 0), ratio: 0.4, resetAt: resetFuture)
        ]
        let records = [
            makeDayRecord(
                service: service,
                dayStart: makeDate(2026, 1, 15, 0, 0),
                primaryPeak: 0.5,
                secondaryPeak: 0.82
            )
        ]

        let store = MockUsageHistoryStore(dayRecordsStorage: records, secondarySamplesStorage: samples)
        let vm = UsageHistoryViewModel(store: store, calendar: calendar, nowProvider: { now })
        vm.selectedWindow = .secondary
        await vm.refresh()

        guard let panel = panel(for: service, in: vm) else {
            XCTFail("Expected a panel for \(service.rawValue)")
            return
        }

        XCTAssertTrue(panel.isSevenDayCycleAvailable)
        XCTAssertEqual(panel.cycleSummary.totalClosedCycles, 2)
        XCTAssertEqual(panel.cycleSummary.completedCycles, 1)
        XCTAssertEqual(panel.cycleSummary.completionRate, 0.5, accuracy: 0.0001)
        XCTAssertEqual(panel.cycleSummary.averageDaysTo80 ?? -1, 3.5, accuracy: 0.0001)
        XCTAssertEqual(panel.cycleSummary.averageDaysTo100 ?? -1, 4.0, accuracy: 0.0001)
        XCTAssertEqual(panel.cycleSummary.currentCompletionStreak, 0)
        XCTAssertEqual(panel.cycleSummary.averageHighBandHours, 0.25, accuracy: 0.0001)
        XCTAssertEqual(panel.cycleCells.count, 2)
    }

    @MainActor
    func testNon5h7dServiceIsExcludedFromSecondaryWindow() async {
        let now = makeDate(2026, 2, 19, 12, 0)
        let service: ServiceType = .zai
        let records = [
            makeDayRecord(
                service: service,
                dayStart: makeDate(2026, 2, 18, 0, 0),
                primaryPeak: 0.2,
                secondaryPeak: 0.9
            )
        ]
        let samples = [
            UsageHistorySecondarySample(
                service: service,
                sampledAt: makeDate(2026, 2, 18, 10, 0),
                ratio: 0.9,
                resetAt: makeDate(2026, 2, 28, 0, 0)
            )
        ]

        let store = MockUsageHistoryStore(dayRecordsStorage: records, secondarySamplesStorage: samples)
        let vm = UsageHistoryViewModel(store: store, calendar: calendar, nowProvider: { now })
        vm.selectedWindow = .secondary
        await vm.refresh()

        XCTAssertNil(panel(for: service, in: vm), "Z.ai (MCP) should not appear in secondary view")
        XCTAssertTrue(vm.servicePanels.isEmpty)
    }

    @MainActor
    func testPanelsAreSortedByUsageFrequencyDescending() async {
        let now = makeDate(2026, 2, 19, 12, 0)
        let claude: ServiceType = .claude
        let codex: ServiceType = .codex

        let records = [
            makeDayRecord(service: claude, dayStart: makeDate(2026, 2, 15, 0, 0), primaryPeak: 0.4),
            makeDayRecord(service: claude, dayStart: makeDate(2026, 2, 16, 0, 0), primaryPeak: 0.5),
            makeDayRecord(service: codex, dayStart: makeDate(2026, 2, 15, 0, 0), primaryPeak: 0.4),
            makeDayRecord(service: codex, dayStart: makeDate(2026, 2, 16, 0, 0), primaryPeak: 0.5),
            makeDayRecord(service: codex, dayStart: makeDate(2026, 2, 17, 0, 0), primaryPeak: 0.3),
            makeDayRecord(service: codex, dayStart: makeDate(2026, 2, 18, 0, 0), primaryPeak: 0.6)
        ]

        let store = MockUsageHistoryStore(dayRecordsStorage: records, secondarySamplesStorage: [])
        let vm = UsageHistoryViewModel(store: store, calendar: calendar, nowProvider: { now })
        vm.selectedWindow = .primary
        await vm.refresh()

        XCTAssertEqual(vm.servicePanels.map(\.service), [.codex, .claude])
        XCTAssertEqual(vm.servicePanels.first?.usageFrequencyDays, 4)
        XCTAssertEqual(vm.servicePanels.last?.usageFrequencyDays, 2)
    }

    @MainActor
    func testLatestRefreshGenerationWinsWhenRefreshesOverlap() async {
        let now = makeDate(2026, 2, 19, 12, 0)
        let service: ServiceType = .claude
        let records = [
            makeDayRecord(
                service: service,
                dayStart: makeDate(2026, 2, 19, 0, 0),
                primaryPeak: 0.4,
                secondaryPeak: 0.8
            )
        ]

        let store = DelayedMockUsageHistoryStore(
            dayRecordsStorage: records,
            secondarySamplesStorage: []
        )
        let vm = UsageHistoryViewModel(store: store, calendar: calendar, nowProvider: { now })
        await vm.refresh()

        await store.setDelayOnNextAvailableServicesCall(nanoseconds: 200_000_000)
        vm.selectedWindow = .primary
        let firstRefresh = Task { await vm.refresh() }

        try? await Task.sleep(nanoseconds: 20_000_000)
        vm.selectedWindow = .secondary
        let secondRefresh = Task { await vm.refresh() }

        await firstRefresh.value
        await secondRefresh.value

        XCTAssertEqual(vm.servicePanels.first?.displayWindow, .secondary)
    }

    private func makeDayRecord(
        service: ServiceType,
        dayStart: Date,
        primaryPeak: Double,
        secondaryPeak: Double? = nil
    ) -> UsageHistoryDayRecord {
        UsageHistoryDayRecord(
            service: service,
            dayStart: dayStart,
            primaryPeakRatio: primaryPeak,
            primaryAverageRatio: primaryPeak,
            secondaryPeakRatio: secondaryPeak,
            secondaryAverageRatio: secondaryPeak,
            sampleCount: 1,
            lastSampleAt: dayStart
        )
    }

    private func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
        return components.date ?? Date(timeIntervalSince1970: 0)
    }

    @MainActor
    private func panel(for service: ServiceType, in vm: UsageHistoryViewModel) -> UsageHistoryServicePanel? {
        vm.servicePanels.first { $0.service == service }
    }
}

private actor DelayedMockUsageHistoryStore: UsageHistoryStoreProtocol {
    private let dayRecordsStorage: [UsageHistoryDayRecord]
    private let secondarySamplesStorage: [UsageHistorySecondarySample]
    private var delayOnNextAvailableServicesCall: UInt64 = 0

    init(
        dayRecordsStorage: [UsageHistoryDayRecord],
        secondarySamplesStorage: [UsageHistorySecondarySample]
    ) {
        self.dayRecordsStorage = dayRecordsStorage
        self.secondarySamplesStorage = secondarySamplesStorage
    }

    func setDelayOnNextAvailableServicesCall(nanoseconds: UInt64) {
        delayOnNextAvailableServicesCall = nanoseconds
    }

    func record(samples: [UsageData], recordedAt: Date) async {
        // no-op
    }

    func dayRecords(for service: ServiceType, since: Date, until: Date) async -> [UsageHistoryDayRecord] {
        dayRecordsStorage
            .filter { $0.service == service && $0.dayStart >= since && $0.dayStart <= until }
            .sorted { $0.dayStart < $1.dayStart }
    }

    func secondarySamples(for service: ServiceType, since: Date, until: Date) async -> [UsageHistorySecondarySample] {
        secondarySamplesStorage
            .filter { $0.service == service && $0.sampledAt >= since && $0.sampledAt <= until }
            .sorted { $0.sampledAt < $1.sampledAt }
    }

    func availableServices(since: Date, until: Date) async -> [ServiceType] {
        if delayOnNextAvailableServicesCall > 0 {
            let delay = delayOnNextAvailableServicesCall
            delayOnNextAvailableServicesCall = 0
            try? await Task.sleep(nanoseconds: delay)
        }

        var set = Set<ServiceType>()
        for record in dayRecordsStorage where record.dayStart >= since && record.dayStart <= until {
            set.insert(record.service)
        }
        for sample in secondarySamplesStorage where sample.sampledAt >= since && sample.sampledAt <= until {
            set.insert(sample.service)
        }
        return Array(set)
    }
}

private actor MockUsageHistoryStore: UsageHistoryStoreProtocol {
    private let dayRecordsStorage: [UsageHistoryDayRecord]
    private let secondarySamplesStorage: [UsageHistorySecondarySample]

    init(
        dayRecordsStorage: [UsageHistoryDayRecord],
        secondarySamplesStorage: [UsageHistorySecondarySample]
    ) {
        self.dayRecordsStorage = dayRecordsStorage
        self.secondarySamplesStorage = secondarySamplesStorage
    }

    func record(samples: [UsageData], recordedAt: Date) async {
        // no-op
    }

    func dayRecords(for service: ServiceType, since: Date, until: Date) async -> [UsageHistoryDayRecord] {
        dayRecordsStorage
            .filter { $0.service == service && $0.dayStart >= since && $0.dayStart <= until }
            .sorted { $0.dayStart < $1.dayStart }
    }

    func secondarySamples(for service: ServiceType, since: Date, until: Date) async -> [UsageHistorySecondarySample] {
        secondarySamplesStorage
            .filter { $0.service == service && $0.sampledAt >= since && $0.sampledAt <= until }
            .sorted { $0.sampledAt < $1.sampledAt }
    }

    func availableServices(since: Date, until: Date) async -> [ServiceType] {
        var set = Set<ServiceType>()

        for record in dayRecordsStorage where record.dayStart >= since && record.dayStart <= until {
            set.insert(record.service)
        }
        for sample in secondarySamplesStorage where sample.sampledAt >= since && sample.sampledAt <= until {
            set.insert(sample.service)
        }

        return Array(set)
    }
}

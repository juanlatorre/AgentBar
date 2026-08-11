import Foundation
import Combine

struct UsageHistoryHeatmapCell: Identifiable, Sendable {
    let id: String
    let date: Date
    let ratio: Double
    let level: Int
    let sampleCount: Int
    let peakRatio: Double
    let averageRatio: Double
    let usedValue: Double
    let unit: UsageUnit?
}

struct UsageHistorySummary: Sendable, Equatable {
    let limitHitDays: Int
    let nearLimitDays: Int
    let averageDailyPeakRatio: Double
    let lastHitDate: Date?

    static let empty = UsageHistorySummary(
        limitHitDays: 0,
        nearLimitDays: 0,
        averageDailyPeakRatio: 0,
        lastHitDate: nil
    )
}

struct UsageHistoryCycleCell: Identifiable, Sendable {
    let id: String
    let cycleStart: Date
    let cycleEnd: Date
    let peakRatio: Double
    let level: Int
    let reached80: Bool
    let reached100: Bool
    let daysTo80: Int?
    let daysTo100: Int?
    let highBandHours: Double
}

struct UsageHistoryCycleSummary: Sendable, Equatable {
    let completedCycles: Int
    let totalClosedCycles: Int
    let completionRate: Double
    let averageDaysTo80: Double?
    let averageDaysTo100: Double?
    let averageHighBandHours: Double
    let currentCompletionStreak: Int

    static let empty = UsageHistoryCycleSummary(
        completedCycles: 0,
        totalClosedCycles: 0,
        completionRate: 0,
        averageDaysTo80: nil,
        averageDaysTo100: nil,
        averageHighBandHours: 0,
        currentCompletionStreak: 0
    )
}

struct UsageHistoryServicePanel: Identifiable, Sendable {
    let id: ServiceType
    let service: ServiceType
    let displayWindow: UsageHistoryWindow
    let isSecondaryAvailable: Bool
    let heatmapCells: [UsageHistoryHeatmapCell]
    let dailySummary: UsageHistorySummary
    let cycleSummary: UsageHistoryCycleSummary
    let cycleCells: [UsageHistoryCycleCell]
    let isSevenDayCycleAvailable: Bool
    let usageFrequencyDays: Int
    let trendPoints: [UsageHistoryTrendPoint]
    let trendUnit: UsageUnit?
}

struct UsageHistoryTrendPoint: Sendable {
    let date: Date
    let value: Double
}

@MainActor
final class UsageHistoryViewModel: ObservableObject {
    @Published var selectedWindow: UsageHistoryWindow = .primary
    @Published var selectedRangeWeeks: Int = 8

    @Published private(set) var availableServices: [ServiceType] = []
    @Published private(set) var servicePanels: [UsageHistoryServicePanel] = []

    private let store: UsageHistoryStoreProtocol
    private var calendar: Calendar
    private let nowProvider: @Sendable () -> Date
    private var cancellables: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?
    private var refreshTaskGeneration: UInt64 = 0
    private var refreshGeneration: UInt64 = 0

    private static let cyclePanelMaxCycles = 12
    private static let secondarySampleWindowDays = 130
    private static let highBandThreshold = 0.8
    private static let completionThreshold = 1.0
    private static let highBandSegmentCapSeconds: TimeInterval = 30 * 60
    private static let serviceOrder: [ServiceType] = [
        .claude, .codex, .gemini, .copilot, .cursor, .opencode, .zai
    ]

    init(
        store: UsageHistoryStoreProtocol = UsageHistoryStore(),
        calendar: Calendar = Calendar(identifier: .gregorian),
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        var configuredCalendar = calendar
        configuredCalendar.firstWeekday = 1
        self.calendar = configuredCalendar
        self.nowProvider = nowProvider

        bindInputs()
        observeHistoryUpdates()
        scheduleRefresh()
    }

    func refresh() async {
        refreshTask?.cancel()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        refreshTask = Task { [weak self] in
            await self?.refresh(generation: generation)
        }
        refreshTaskGeneration = generation
        // A concurrent refresh (e.g. from a .usageHistoryChanged notification)
        // may replace `refreshTask` mid-await and invalidate this one. Wait for
        // the latest task in the chain so callers observe a fully populated state.
        await awaitLatestRefreshTask()
    }

    private func awaitLatestRefreshTask() async {
        while true {
            guard let task = refreshTask else { return }
            let taskGeneration = refreshTaskGeneration
            await task.value
            guard taskGeneration != refreshGeneration else { return }
            // The task was superseded while we waited; wait for the newer one.
        }
    }

    private func refresh(generation: UInt64) async {
        let now = nowProvider()
        let currentWeekStart = startOfWeek(containing: now) ?? calendar.startOfDay(for: now)
        let gridStart = calendar.date(
            byAdding: .day,
            value: -((selectedRangeWeeks - 1) * 7),
            to: currentWeekStart
        ) ?? currentWeekStart
        let gridEnd = calendar.date(
            byAdding: .day,
            value: (selectedRangeWeeks * 7) - 1,
            to: gridStart
        ) ?? now

        let allServices = await store.availableServices(since: gridStart, until: now)
        guard !isStale(generation) else { return }

        let services = selectedWindow == .secondary
            ? allServices.filter(\.hasFiveHourSevenDayStructure)
            : allServices
        let orderedServices = services.sorted {
            Self.serviceOrderIndex(for: $0) < Self.serviceOrderIndex(for: $1)
        }
        availableServices = orderedServices

        guard !orderedServices.isEmpty else {
            guard !isStale(generation) else { return }
            resetStateForEmptyHistory()
            return
        }

        let secondarySamplesSince = calendar.date(
            byAdding: .day,
            value: -Self.secondarySampleWindowDays,
            to: now
        ) ?? gridStart

        var panels: [UsageHistoryServicePanel] = []
        for service in orderedServices {
            let dayRecords = await store.dayRecords(
                for: service,
                since: gridStart,
                until: gridEnd
            )
            guard !isStale(generation) else { return }

            let secondarySamples = await store.secondarySamples(
                for: service,
                since: secondarySamplesSince,
                until: now
            )
            guard !isStale(generation) else { return }

            let isSecondaryAvailable = dayRecords.contains {
                $0.secondaryPeakRatio != nil || $0.secondaryAverageRatio != nil
            } || !secondarySamples.isEmpty

            let displayWindow: UsageHistoryWindow = (
                selectedWindow == .secondary && isSecondaryAvailable
            ) ? .secondary : .primary

            let heatmapCells = buildHeatmapCells(
                dayRecords: dayRecords,
                window: displayWindow,
                gridStart: gridStart,
                totalDays: selectedRangeWeeks * 7,
                now: now
            )
            let dailySummary = makeDailySummary(from: heatmapCells, now: now)
            let trendPoints = heatmapCells
                .filter { $0.date <= now }
                .map { UsageHistoryTrendPoint(date: $0.date, value: $0.usedValue) }
            let trendUnit = heatmapCells
                .compactMap(\.unit)
                .first ?? fallbackUnit(for: service, window: displayWindow)

            let isSevenDayCycleAvailable = (
                displayWindow == .secondary &&
                service.weeklyLabel == "7d"
            )

            let allClosedCycles = isSevenDayCycleAvailable
                ? buildClosedCycleCells(from: secondarySamples, now: now)
                : []
            let cycleCells = isSevenDayCycleAvailable
                ? Array(allClosedCycles.suffix(Self.cyclePanelMaxCycles))
                : []
            let cycleSummary = isSevenDayCycleAvailable
                ? makeCycleSummary(from: allClosedCycles)
                : .empty

            let frequencyDays: Int = {
                switch selectedWindow {
                case .primary:
                    return dayRecords.filter { $0.primaryPeakRatio > 0 }.count
                case .secondary:
                    guard isSecondaryAvailable else { return 0 }
                    return dayRecords.filter { ($0.secondaryPeakRatio ?? 0) > 0 }.count
                }
            }()

            panels.append(
                UsageHistoryServicePanel(
                    id: service,
                    service: service,
                    displayWindow: displayWindow,
                    isSecondaryAvailable: isSecondaryAvailable,
                    heatmapCells: heatmapCells,
                    dailySummary: dailySummary,
                    cycleSummary: cycleSummary,
                    cycleCells: cycleCells,
                    isSevenDayCycleAvailable: isSevenDayCycleAvailable,
                    usageFrequencyDays: frequencyDays,
                    trendPoints: trendPoints,
                    trendUnit: trendUnit
                )
            )
        }

        guard !isStale(generation) else { return }

        panels.sort {
            if $0.usageFrequencyDays != $1.usageFrequencyDays {
                return $0.usageFrequencyDays > $1.usageFrequencyDays
            }

            if $0.dailySummary.averageDailyPeakRatio != $1.dailySummary.averageDailyPeakRatio {
                return $0.dailySummary.averageDailyPeakRatio > $1.dailySummary.averageDailyPeakRatio
            }

            return Self.serviceOrderIndex(for: $0.service) < Self.serviceOrderIndex(for: $1.service)
        }

        servicePanels = panels
        availableServices = panels.map(\.service)
    }

    private func bindInputs() {
        $selectedWindow
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleRefresh()
            }
            .store(in: &cancellables)

        $selectedRangeWeeks
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleRefresh()
            }
            .store(in: &cancellables)
    }

    private func observeHistoryUpdates() {
        NotificationCenter.default
            .publisher(for: .usageHistoryChanged)
            .sink { [weak self] _ in
                self?.scheduleRefresh()
            }
            .store(in: &cancellables)
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        refreshTask = Task { [weak self] in
            await self?.refresh(generation: generation)
        }
        refreshTaskGeneration = generation
    }

    private func isStale(_ generation: UInt64) -> Bool {
        Task.isCancelled || generation != refreshGeneration
    }

    private func resetStateForEmptyHistory() {
        availableServices = []
        servicePanels = []
    }

    // MARK: - Daily Heatmap

    private func buildHeatmapCells(
        dayRecords: [UsageHistoryDayRecord],
        window: UsageHistoryWindow,
        gridStart: Date,
        totalDays: Int,
        now: Date
    ) -> [UsageHistoryHeatmapCell] {
        let recordsByDay = Dictionary(uniqueKeysWithValues: dayRecords.map { ($0.dayStart, $0) })

        return (0..<totalDays).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: gridStart) else {
                return nil
            }

            if date > now {
                return UsageHistoryHeatmapCell(
                    id: Self.cellID(date: date),
                    date: date,
                    ratio: 0,
                    level: 0,
                    sampleCount: 0,
                    peakRatio: 0,
                    averageRatio: 0,
                    usedValue: 0,
                    unit: nil
                )
            }

            let dayStart = calendar.startOfDay(for: date)
            let record = recordsByDay[dayStart]
            let peakRatio: Double
            let averageRatio: Double
            let sampleCount: Int
            let usedValue: Double
            let unit: UsageUnit?

            switch window {
            case .primary:
                peakRatio = record?.primaryPeakRatio ?? 0
                averageRatio = record?.primaryAverageRatio ?? 0
                sampleCount = record?.sampleCount ?? 0
                usedValue = record?.primaryPeakUsed ?? 0
                unit = record?.primaryUnitRawValue.flatMap(UsageUnit.init(rawValue:))
            case .secondary:
                peakRatio = record?.secondaryPeakRatio ?? 0
                averageRatio = record?.secondaryAverageRatio ?? 0
                sampleCount = record?.secondarySampleCount ?? 0
                usedValue = record?.secondaryPeakUsed ?? 0
                unit = record?.secondaryUnitRawValue.flatMap(UsageUnit.init(rawValue:))
            }

            let clampedPeak = Self.clampRatio(peakRatio)
            return UsageHistoryHeatmapCell(
                id: Self.cellID(date: date),
                date: date,
                ratio: clampedPeak,
                level: Self.level(for: clampedPeak),
                sampleCount: sampleCount,
                peakRatio: clampedPeak,
                averageRatio: Self.clampRatio(averageRatio),
                usedValue: usedValue,
                unit: unit
            )
        }
    }

    private func makeDailySummary(
        from cells: [UsageHistoryHeatmapCell],
        now: Date
    ) -> UsageHistorySummary {
        let completedCells = cells.filter { $0.date <= now }
        guard !completedCells.isEmpty else { return .empty }

        let hitCells = completedCells.filter { $0.peakRatio >= Self.completionThreshold }
        let nearLimitCells = completedCells.filter { $0.peakRatio >= Self.highBandThreshold }
        let averagePeak = completedCells.map(\.peakRatio).reduce(0, +) / Double(completedCells.count)

        return UsageHistorySummary(
            limitHitDays: hitCells.count,
            nearLimitDays: nearLimitCells.count,
            averageDailyPeakRatio: averagePeak,
            lastHitDate: hitCells.map(\.date).max()
        )
    }

    // MARK: - 7d Cycle Consistency

    private func buildClosedCycleCells(
        from samples: [UsageHistorySecondarySample],
        now: Date
    ) -> [UsageHistoryCycleCell] {
        guard !samples.isEmpty else { return [] }

        let grouped = Dictionary(grouping: samples, by: \.resetAt)
        let orderedResets = grouped.keys.sorted()
        var previousCycleEnd: Date?
        var cells: [UsageHistoryCycleCell] = []

        for resetAt in orderedResets {
            guard let rawCycleSamples = grouped[resetAt] else { continue }
            let cycleSamples = rawCycleSamples.sorted { $0.sampledAt < $1.sampledAt }
            guard let firstSample = cycleSamples.first else { continue }

            let cycleStart = previousCycleEnd ?? firstSample.sampledAt
            let cycleEnd = resetAt
            previousCycleEnd = cycleEnd

            guard cycleEnd <= now else { continue }

            let peakRatio = Self.clampRatio(cycleSamples.map(\.ratio).max() ?? 0)
            let reached80 = peakRatio >= Self.highBandThreshold
            let reached100 = peakRatio >= Self.completionThreshold

            let first80At = cycleSamples.first(where: { $0.ratio >= Self.highBandThreshold })?.sampledAt
            let first100At = cycleSamples.first(where: { $0.ratio >= Self.completionThreshold })?.sampledAt

            let highBandHours = calculateHighBandHours(cycleSamples: cycleSamples)

            cells.append(
                UsageHistoryCycleCell(
                    id: Self.cycleID(resetAt: resetAt),
                    cycleStart: cycleStart,
                    cycleEnd: cycleEnd,
                    peakRatio: peakRatio,
                    level: Self.level(for: peakRatio),
                    reached80: reached80,
                    reached100: reached100,
                    daysTo80: first80At.map { dayOffset(from: cycleStart, to: $0) },
                    daysTo100: first100At.map { dayOffset(from: cycleStart, to: $0) },
                    highBandHours: highBandHours
                )
            )
        }

        return cells
    }

    private func makeCycleSummary(from closedCycles: [UsageHistoryCycleCell]) -> UsageHistoryCycleSummary {
        guard !closedCycles.isEmpty else { return .empty }

        let completedCycles = closedCycles.filter(\.reached100).count
        let totalClosedCycles = closedCycles.count
        let completionRate = Double(completedCycles) / Double(totalClosedCycles)

        let daysTo80Values = closedCycles.compactMap(\.daysTo80)
        let daysTo100Values = closedCycles.compactMap(\.daysTo100)
        let averageDaysTo80 = Self.average(daysTo80Values)
        let averageDaysTo100 = Self.average(daysTo100Values)
        let averageHighBandHours = closedCycles.map(\.highBandHours).reduce(0, +) / Double(totalClosedCycles)

        let latestFirstCycles = closedCycles.sorted { $0.cycleEnd > $1.cycleEnd }
        var streak = 0
        for cycle in latestFirstCycles {
            if cycle.reached100 {
                streak += 1
            } else {
                break
            }
        }

        return UsageHistoryCycleSummary(
            completedCycles: completedCycles,
            totalClosedCycles: totalClosedCycles,
            completionRate: completionRate,
            averageDaysTo80: averageDaysTo80,
            averageDaysTo100: averageDaysTo100,
            averageHighBandHours: averageHighBandHours,
            currentCompletionStreak: streak
        )
    }

    private func calculateHighBandHours(cycleSamples: [UsageHistorySecondarySample]) -> Double {
        guard cycleSamples.count >= 2 else { return 0 }
        var totalSeconds: TimeInterval = 0

        for index in 0..<(cycleSamples.count - 1) {
            let current = cycleSamples[index]
            let next = cycleSamples[index + 1]

            guard current.ratio >= Self.highBandThreshold else { continue }
            let rawSeconds = max(0, next.sampledAt.timeIntervalSince(current.sampledAt))
            totalSeconds += min(rawSeconds, Self.highBandSegmentCapSeconds)
        }

        return totalSeconds / 3600
    }

    private func dayOffset(from start: Date, to end: Date) -> Int {
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        return max(0, calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0)
    }

    // MARK: - Helpers

    private func startOfWeek(containing date: Date) -> Date? {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start
    }

    private static func clampRatio(_ ratio: Double) -> Double {
        min(max(ratio, 0), 1)
    }

    private static func level(for ratio: Double) -> Int {
        let value = clampRatio(ratio)
        if value == 0 { return 0 }
        if value <= 0.25 { return 1 }
        if value <= 0.5 { return 2 }
        if value <= 0.75 { return 3 }
        return 4
    }

    private static func serviceOrderIndex(for service: ServiceType) -> Int {
        serviceOrder.firstIndex(of: service) ?? Int.max
    }

    private static func average(_ values: [Int]) -> Double? {
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    private func fallbackUnit(for service: ServiceType, window: UsageHistoryWindow) -> UsageUnit? {
        switch window {
        case .primary:
            switch service {
            case .codex: return .tokens
            case .gemini, .copilot, .cursor: return .requests
            case .claude, .zai, .opencode: return .percent
            }
        case .secondary:
            switch service {
            case .codex: return .tokens
            case .claude: return .percent
            case .zai: return .requests
            case .gemini, .copilot, .cursor, .opencode: return nil
            }
        }
    }

    private static func cellID(date: Date) -> String {
        "day-\(Int(date.timeIntervalSince1970))"
    }

    private static func cycleID(resetAt: Date) -> String {
        "cycle-\(Int(resetAt.timeIntervalSince1970))"
    }
}

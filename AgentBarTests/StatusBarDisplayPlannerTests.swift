import XCTest
import SwiftUI
@testable import AgentBar

final class ServiceTypeColorTests: XCTestCase {
    func testCodexDarkColorIsBlue700() {
        let color = ServiceType.codex.darkColor
        // blue-700: (0.004, 0.231, 0.741)
        let resolved = NSColor(color).usingColorSpace(.sRGB)!
        XCTAssertEqual(resolved.redComponent, 0.004, accuracy: 0.01)
        XCTAssertEqual(resolved.greenComponent, 0.231, accuracy: 0.01)
        XCTAssertEqual(resolved.blueComponent, 0.741, accuracy: 0.01)
    }

    func testAllServicesHaveDistinctDarkColors() {
        let colors = ServiceType.allCases.map { NSColor($0.darkColor).usingColorSpace(.sRGB)! }
        for i in 0..<colors.count {
            for j in (i + 1)..<colors.count {
                let same = abs(colors[i].redComponent - colors[j].redComponent) < 0.05
                    && abs(colors[i].greenComponent - colors[j].greenComponent) < 0.05
                    && abs(colors[i].blueComponent - colors[j].blueComponent) < 0.05
                XCTAssertFalse(same, "\(ServiceType.allCases[i]) and \(ServiceType.allCases[j]) have nearly identical darkColor")
            }
        }
    }
}

final class StatusBarDisplayPlannerTests: XCTestCase {
    func testRanksServicesByLowestRemainingFirst() {
        let services = [
            makeUsage(service: .claude, fiveHourPct: 0.20, weeklyPct: 0.40),
            makeUsage(service: .codex, fiveHourPct: 0.90, weeklyPct: 0.10),
            makeUsage(service: .gemini, fiveHourPct: 0.50, weeklyPct: 0.60)
        ]

        let ranked = StatusBarDisplayPlanner.rankedServices(from: services)
        XCTAssertEqual(ranked.map(\.service), [.codex, .gemini, .claude])
    }

    func testIgnoresUnavailableServicesWhenRanking() {
        let services = [
            makeUsage(service: .claude, fiveHourPct: 0.8),
            makeUsage(service: .codex, fiveHourPct: 0.7),
            makeUsage(service: .gemini, fiveHourPct: 0.9, available: false)
        ]

        let ranked = StatusBarDisplayPlanner.rankedServices(from: services)
        XCTAssertEqual(ranked.map(\.service), [.claude, .codex])
    }

    func testMaxScrollIndexWalksAllServicesOneByOne() {
        let services = [
            makeUsage(service: .claude, fiveHourPct: 0.95),
            makeUsage(service: .codex, fiveHourPct: 0.90),
            makeUsage(service: .gemini, fiveHourPct: 0.85)
        ]

        let ranked = StatusBarDisplayPlanner.rankedServices(from: services)
        XCTAssertEqual(StatusBarDisplayPlanner.maxScrollIndex(for: ranked), 2)
    }

    func testMaxScrollIndexEqualsLastServiceIndex() {
        let services = [
            makeUsage(service: .claude, fiveHourPct: 0.99),
            makeUsage(service: .codex, fiveHourPct: 0.98),
            makeUsage(service: .gemini, fiveHourPct: 0.97),
            makeUsage(service: .copilot, fiveHourPct: 0.96),
            makeUsage(service: .cursor, fiveHourPct: 0.95),
            makeUsage(service: .zai, fiveHourPct: 0.94),
            makeUsage(service: .claude, fiveHourPct: 0.93)
        ]

        let ranked = StatusBarDisplayPlanner.rankedServices(from: services)
        XCTAssertEqual(StatusBarDisplayPlanner.maxScrollIndex(for: ranked), 6)
    }

    func testCriticalRemainingPercentageTakesLowestWindow() {
        let services = [
            makeUsage(service: .claude, fiveHourPct: 0.9),
            makeUsage(service: .codex, fiveHourPct: 0.2)
        ]

        XCTAssertEqual(
            StatusBarDisplayPlanner.criticalRemainingPercentage(for: services[0]),
            0.1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            StatusBarDisplayPlanner.criticalRemainingPercentage(for: services[1]),
            0.8,
            accuracy: 0.001
        )
    }

    func testCriticalRemainingPercentageIgnoresMissingWindows() {
        let usage = UsageData(
            service: .opencode,
            fiveHourUsage: UsageMetric(used: 0, total: 12, unit: .dollars, resetTime: nil),
            weeklyUsage: nil,
            monthlyUsage: nil,
            lastUpdated: Date(),
            isAvailable: true
        )

        XCTAssertEqual(
            StatusBarDisplayPlanner.criticalRemainingPercentage(for: usage),
            1.0,
            accuracy: 0.001
        )
    }

    func testTieBreakUsesServiceOrder() {
        let services = [
            makeUsage(service: .zai, fiveHourPct: 0.50),
            makeUsage(service: .codex, fiveHourPct: 0.50),
            makeUsage(service: .claude, fiveHourPct: 0.50)
        ]

        let ranked = StatusBarDisplayPlanner.rankedServices(from: services)
        XCTAssertEqual(ranked.map(\.service), [.claude, .codex, .zai])
    }

    func testTopPriorityHoldIsLongerThanStepHold() {
        XCTAssertGreaterThan(
            StatusBarDisplayPlanner.topPriorityHoldSeconds,
            StatusBarDisplayPlanner.scrollStepHoldSeconds
        )
    }

    private func makeUsage(
        service: ServiceType,
        fiveHourPct: Double,
        weeklyPct: Double = 0,
        available: Bool = true
    ) -> UsageData {
        UsageData(
            service: service,
            fiveHourUsage: UsageMetric(
                used: fiveHourPct * 100,
                total: 100,
                unit: .percent,
                resetTime: nil
            ),
            weeklyUsage: UsageMetric(
                used: weeklyPct * 100,
                total: 100,
                unit: .percent,
                resetTime: nil
            ),
            lastUpdated: Date(),
            isAvailable: available
        )
    }
}

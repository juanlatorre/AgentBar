import Foundation
import CoreGraphics

enum StatusBarDisplayPlanner {
    static let topPriorityHoldSeconds: TimeInterval = 8
    static let scrollStepHoldSeconds: TimeInterval = 3
    static let scrollTransitionSeconds: TimeInterval = 1.2

    private static let serviceOrder: [ServiceType] = [.claude, .codex, .gemini, .copilot, .cursor, .opencode, .zai]

    static func rankedServices(from services: [UsageData]) -> [UsageData] {
        services
            .filter(\.isAvailable)
            .sorted { lhs, rhs in
                // Lowest remaining allowance first (most critical on top).
                let lhsScore = usageScore(lhs)
                let rhsScore = usageScore(rhs)
                if lhsScore != rhsScore {
                    return lhsScore < rhsScore
                }

                let lhsRank = serviceOrder.firstIndex(of: lhs.service) ?? serviceOrder.count
                let rhsRank = serviceOrder.firstIndex(of: rhs.service) ?? serviceOrder.count
                return lhsRank < rhsRank
            }
    }

    /// The least available remaining percentage across all of a service's windows.
    /// This drives both the ranking and the percentage shown in the menu bar.
    static func criticalRemainingPercentage(for data: UsageData) -> Double {
        let weekly = data.weeklyUsage?.remainingPercentage ?? 1
        let monthly = data.monthlyUsage?.remainingPercentage ?? 1
        return min(data.fiveHourUsage.remainingPercentage, weekly, monthly)
    }

    static func maxScrollIndex(for rankedServices: [UsageData]) -> Int {
        max(0, rankedServices.count - 1)
    }

    private static func usageScore(_ data: UsageData) -> Double {
        criticalRemainingPercentage(for: data)
    }
}

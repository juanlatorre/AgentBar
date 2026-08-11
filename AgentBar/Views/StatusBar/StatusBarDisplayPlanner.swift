import Foundation
import CoreGraphics

enum StatusBarDisplayPlanner {
    static let visibleRowCount = 3
    static let rowHeight: CGFloat = 6
    static let rowSpacing: CGFloat = 1
    static let viewportHeight: CGFloat = 20

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

    static func maxScrollIndex(for rankedServices: [UsageData]) -> Int {
        max(0, rankedServices.count - visibleRowCount)
    }

    private static func usageScore(_ data: UsageData) -> Double {
        let weekly = data.weeklyUsage?.remainingPercentage ?? 1
        let monthly = data.monthlyUsage?.remainingPercentage ?? 1
        return min(data.fiveHourUsage.remainingPercentage, weekly, monthly)
    }
}

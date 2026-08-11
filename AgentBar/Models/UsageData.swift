import Foundation

struct UsageData: Identifiable, Sendable {
    let id = UUID()
    let service: ServiceType
    let fiveHourUsage: UsageMetric
    let weeklyUsage: UsageMetric?
    let monthlyUsage: UsageMetric?
    let lastUpdated: Date
    let isAvailable: Bool
    let planName: String?

    init(
        service: ServiceType,
        fiveHourUsage: UsageMetric,
        weeklyUsage: UsageMetric?,
        monthlyUsage: UsageMetric? = nil,
        lastUpdated: Date,
        isAvailable: Bool,
        planName: String? = nil
    ) {
        self.service = service
        self.fiveHourUsage = fiveHourUsage
        self.weeklyUsage = weeklyUsage
        self.monthlyUsage = monthlyUsage
        self.lastUpdated = lastUpdated
        self.isAvailable = isAvailable
        self.planName = planName
    }
}

struct UsageMetric: Sendable {
    let used: Double
    let total: Double
    let unit: UsageUnit
    let resetTime: Date?

    var percentage: Double {
        guard total > 0 else { return 0 }
        return min(used / total, 1.0)
    }

    static let zero = UsageMetric(used: 0, total: 0, unit: .tokens, resetTime: nil)
}

enum UsageUnit: String, Sendable {
    case tokens = "tokens"
    case requests = "requests"
    case dollars = "USD"
    case percent = "%"
}

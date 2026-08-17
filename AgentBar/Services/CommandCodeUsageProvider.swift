import Foundation

// MARK: - Command Code Usage API (verified 2026-08)

/// Command Code's billing/usage API. Base: https://api.commandcode.ai
///
/// Authenticated with the CLI API key from `~/.commandcode/auth.json`
/// (`apiKey`). Requires `User-Agent: command-code-cli/<version>` or the API
/// returns Cloudflare error 1010. Sample responses:
///
/// GET /alpha/billing/credits
/// {"credits":{"monthlyCredits":69.33,...},
///  "windowLimits":{"limited":true,"exceeded":null,
///    "fiveHour":{"used":0.034,"cap":14,"exceeded":false,"resetAt":1786989474547},
///    "weekly":{"used":0.666,"cap":35,"exceeded":false,"resetAt":1787536922055}}}
///
/// GET /alpha/billing/subscriptions
/// {"success":true,"data":{"planId":"individual-goat","status":"active",...}}
struct CommandCodeCreditsResponse: Decodable, Sendable {
    let credits: CommandCodeCredits?
    let windowLimits: CommandCodeWindowLimits?
}

struct CommandCodeCredits: Decodable, Sendable {
    let monthlyCredits: Double?
    let purchasedCredits: Double?
    let freeCredits: Double?
}

struct CommandCodeWindowLimits: Decodable, Sendable {
    let limited: Bool?
    let fiveHour: CommandCodeWindowLimit?
    let weekly: CommandCodeWindowLimit?
}

struct CommandCodeWindowLimit: Decodable, Sendable {
    let used: Double?
    let cap: Double?
    let exceeded: Bool?
    let resetAt: Int64?
}

struct CommandCodeSubscriptionResponse: Decodable, Sendable {
    let success: Bool?
    let data: CommandCodeSubscription?
}

struct CommandCodeSubscription: Decodable, Sendable {
    let planId: String?
    let status: String?
}

/// The Command Code CLI auth store: `~/.commandcode/auth.json`.
/// {"apiKey":"user_...","userId":"...","userName":"...","keyName":"..."}
struct CommandCodeAuthFile: Decodable, Sendable {
    let apiKey: String?
}

enum CommandCodeUsageError: Error, Sendable {
    case missingCredential
}

// MARK: - Provider

/// Reads Command Code usage from the official billing API
/// (https://api.commandcode.ai), authenticated with the CLI API key from
/// `~/.commandcode/auth.json`. The API reports two usage windows — 5-hour and
/// weekly — as used/cap credit amounts plus reset times, matching the CLI's
/// own usage panel.
final class CommandCodeUsageProvider: UsageProviderProtocol, @unchecked Sendable {
    let serviceType: ServiceType = .cmd

    static let apiBaseURL = URL(string: "https://api.commandcode.ai")!
    static let userAgent = "command-code-cli/1.26.0"

    private let apiClient: APIClient
    private let authFileURL: URL
    private let fileManager: FileManager

    /// Minimum cache TTL to avoid excessive API requests.
    static let minCacheTTL: TimeInterval = 60
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedResponse: UsageData?
    nonisolated(unsafe) private static var cachedAt: Date?

    init(
        apiClient: APIClient = APIClient(),
        authFileURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let home = fileManager.homeDirectoryForCurrentUser
        self.apiClient = apiClient
        self.authFileURL = authFileURL ?? home.appendingPathComponent(".commandcode/auth.json")
        self.fileManager = fileManager
    }

    func isConfigured() async -> Bool {
        loadAPIKey() != nil
    }

    func fetchUsage() async throws -> UsageData {
        if let cached = Self.cachedIfFresh() {
            return cached
        }

        guard let apiKey = loadAPIKey() else {
            throw CommandCodeUsageError.missingCredential
        }

        let now = Date()

        let headers = [
            "Authorization": "Bearer \(apiKey)",
            "Content-Type": "application/json",
            "User-Agent": Self.userAgent,
            "Accept": "application/json"
        ]

        // Fetch credits (5h + weekly windows) and subscription (plan name).
        async let creditsRequest: CommandCodeCreditsResponse = apiClient.get(
            url: Self.apiBaseURL.appendingPathComponent("alpha/billing/credits"),
            headers: headers
        )
        async let subscriptionRequest: CommandCodeSubscriptionResponse = apiClient.get(
            url: Self.apiBaseURL.appendingPathComponent("alpha/billing/subscriptions"),
            headers: headers
        )

        let credits = try await creditsRequest
        let subscription = try await subscriptionRequest

        let windows = credits.windowLimits
        let fiveHour = metric(from: windows?.fiveHour, now: now)
        let weekly = metric(from: windows?.weekly, now: now)

        let planName = subscription.data?.planId.map { Self.displayPlanName($0) }

        let result = UsageData(
            service: .cmd,
            fiveHourUsage: fiveHour,
            weeklyUsage: weekly,
            lastUpdated: now,
            isAvailable: true,
            planName: planName
        )

        Self.updateCache(result, now: now)
        return result
    }

    // MARK: - Helpers

    /// Builds a credit-based metric: `used`/`total` are the window's used and
    /// cap amounts (in credits/dollars), reset time from `resetAt` (epoch ms).
    private func metric(from window: CommandCodeWindowLimit?, now: Date) -> UsageMetric {
        let used = window?.used ?? 0
        let total = window?.cap ?? 0
        let resetTime: Date?
        if let resetAt = window?.resetAt, resetAt > 0 {
            resetTime = Date(timeIntervalSince1970: TimeInterval(resetAt) / 1000)
        } else {
            resetTime = nil
        }
        return UsageMetric(used: used, total: total, unit: .dollars, resetTime: resetTime)
    }

    /// Maps API plan ids (e.g. "individual-goat") to a short display name.
    static func displayPlanName(_ planId: String) -> String {
        switch planId {
        case "individual-goat": "Goat"
        case "individual-max": "Max"
        default:
            // "individual-go" → "Go", "team-xyz" → "Team"
            planId
                .replacingOccurrences(of: "individual-", with: "")
                .replacingOccurrences(of: "team-", with: "")
                .capitalized
        }
    }

    // MARK: - Credentials

    /// Loads the API key from `~/.commandcode/auth.json` → `apiKey`.
    func loadAPIKey(authFileURL: URL? = nil) -> String? {
        let url = authFileURL ?? self.authFileURL
        guard let data = try? Data(contentsOf: url),
              let auth = try? JSONDecoder().decode(CommandCodeAuthFile.self, from: data),
              let key = auth.apiKey, !key.isEmpty else {
            return nil
        }
        return key
    }

    // MARK: - Cache

    static func cachedIfFresh(now: Date = Date()) -> UsageData? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let cached = cachedResponse,
              let cachedTime = cachedAt,
              now.timeIntervalSince(cachedTime) < minCacheTTL else {
            return nil
        }
        return cached
    }

    static func updateCache(_ data: UsageData, now: Date = Date()) {
        cacheLock.lock()
        cachedResponse = data
        cachedAt = now
        cacheLock.unlock()
    }
}

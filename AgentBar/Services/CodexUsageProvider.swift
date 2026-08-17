import Foundation

// MARK: - Codex Session Record Models (matches actual ~/.codex/sessions/ JSONL)

struct CodexSessionRecord: Decodable, Sendable {
    let timestamp: String?
    let type: String?
    let payload: CodexPayload?
}

struct CodexPayload: Decodable, Sendable {
    let type: String?
    let info: CodexTokenInfo?
    let rateLimits: CodexRateLimits?

    enum CodingKeys: String, CodingKey {
        case type
        case info
        case rateLimits = "rate_limits"
    }
}

struct CodexTokenInfo: Decodable, Sendable {
    let totalTokenUsage: CodexTokenUsage?
    let lastTokenUsage: CodexTokenUsage?

    enum CodingKeys: String, CodingKey {
        case totalTokenUsage = "total_token_usage"
        case lastTokenUsage = "last_token_usage"
    }
}

struct CodexTokenUsage: Decodable, Sendable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cachedInputTokens: Int?
    let reasoningOutputTokens: Int?
    let totalTokens: Int?

    var totalTokensSum: Int {
        (inputTokens ?? 0) +
        (cachedInputTokens ?? 0) +
        (outputTokens ?? 0) +
        (reasoningOutputTokens ?? 0)
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
    }
}

struct CodexRateLimits: Decodable, Sendable {
    let limitId: String?
    let primary: CodexRateWindow?
    let secondary: CodexRateWindow?

    enum CodingKeys: String, CodingKey {
        case limitId = "limit_id"
        case primary
        case secondary
    }
}

struct CodexRateWindow: Decodable, Sendable {
    let usedPercent: Double?
    let windowMinutes: Int?
    let resetsAt: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
    }
}

// MARK: - Codex Usage API (ChatGPT backend, verified 2026-08)

/// GET https://chatgpt.com/backend-api/codex/usage?limit_id=codex
///
/// Authenticated with the ChatGPT OAuth token from `~/.codex/auth.json`
/// (`tokens.access_token` + `tokens.account_id`). This is the same endpoint
/// the Codex CLI app-server polls in-process; it reports the live weekly
/// rate-limit window. Sample response:
///
/// {"user_id":"user-...","account_id":"...","email":"...","plan_type":"prolite",
///  "rate_limit":{"allowed":false,"limit_reached":true,
///    "primary_window":{"used_percent":100,"limit_window_seconds":604800,
///                      "reset_after_seconds":261623,"reset_at":1787196781},
///    "secondary_window":null},
///  "additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark",...}],
///  "credits":{"has_credits":false,"balance":"0"},
///  "spend_control":{"reached":false},
///  "rate_limit_reached_type":{"type":"rate_limit_reached"},
///  "rate_limit_reset_credits":{"available_count":0}}
struct CodexUsageAPIResponse: Decodable, Sendable {
    let planType: String?
    let rateLimit: CodexAPIRateLimit?
    let rateLimitResetCredits: CodexRateLimitResetCredits?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case rateLimitResetCredits = "rate_limit_reset_credits"
    }
}

struct CodexAPIRateLimit: Decodable, Sendable {
    let allowed: Bool?
    let limitReached: Bool?
    let primaryWindow: CodexAPIWindow?
    let secondaryWindow: CodexAPIWindow?

    enum CodingKeys: String, CodingKey {
        case allowed
        case limitReached = "limit_reached"
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

struct CodexAPIWindow: Decodable, Sendable {
    let usedPercent: Double?
    let limitWindowSeconds: Int?
    let resetAfterSeconds: Int?
    let resetAt: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }
}

struct CodexRateLimitResetCredits: Decodable, Sendable {
    let availableCount: Int?

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
    }
}

/// The Codex CLI OAuth store: `~/.codex/auth.json`.
/// {"auth_mode":"chatgpt","tokens":{"access_token":"...","account_id":"...",...}}
struct CodexAuthFile: Decodable, Sendable {
    struct Tokens: Decodable, Sendable {
        let accessToken: String?
        let accountId: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountId = "account_id"
        }
    }

    let tokens: Tokens?
}

enum CodexUsageError: Error, Sendable {
    case missingCredential
}

// MARK: - Provider

/// Reads Codex (ChatGPT) usage from the ChatGPT usage API, falling back to
/// local session files.
///
/// Since Codex CLI 0.147 the app-server no longer writes rollout JSONL session
/// files (`~/.codex/sessions/**`) while running — rate limits are fetched
/// in-process from the ChatGPT backend. The provider therefore queries
/// `GET /backend-api/codex/usage?limit_id=codex` with the OAuth token from
/// `~/.codex/auth.json` (the same store the CLI uses). When the API is
/// unreachable or the token is missing, it falls back to the legacy JSONL
/// parsing (which still works for CLI versions that write sessions), then to
/// the UserDefaults metric cache.
final class CodexUsageProvider: UsageProviderProtocol, @unchecked Sendable {
    let serviceType: ServiceType = .codex

    static let usageURL = URL(string: "https://chatgpt.com/backend-api/codex/usage?limit_id=codex")!

    private let sessionsDir: URL
    private let weeklyTokenLimit: Double
    private let defaults: UserDefaults
    private let apiClient: APIClient
    private let authFileURL: URL
    private let fileManager: FileManager

    /// Minimum cache TTL to avoid excessive API requests.
    static let minCacheTTL: TimeInterval = 60
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedResponse: UsageData?
    nonisolated(unsafe) private static var cachedAt: Date?

    init(
        sessionsDir: URL? = nil,
        weeklyTokenLimit: Double = 100_000_000,
        defaults: UserDefaults = .standard,
        apiClient: APIClient = APIClient(),
        authFileURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let home = fileManager.homeDirectoryForCurrentUser
        self.sessionsDir = sessionsDir ?? home.appendingPathComponent(".codex/sessions")
        self.weeklyTokenLimit = weeklyTokenLimit
        self.defaults = defaults
        self.apiClient = apiClient
        self.authFileURL = authFileURL ?? home.appendingPathComponent(".codex/auth.json")
        self.fileManager = fileManager
    }

    func isConfigured() async -> Bool {
        fileManager.fileExists(atPath: sessionsDir.path)
            || loadAuthTokens() != nil
    }

    func fetchUsage() async throws -> UsageData {
        if let cached = Self.cachedIfFresh() {
            return cached
        }

        let now = Date()

        // Preferred: live ChatGPT usage API.
        if let tokens = loadAuthTokens(),
           let usage = try? await fetchFromAPI(tokens: tokens, now: now) {
            Self.updateCache(usage, now: now)
            return usage
        }

        // Fallback 1: local JSONL session files (legacy CLI versions).
        let weeklyMetric: UsageMetric
        if let rateLimits = findLatestRateLimits(now: now) {
            let windows = rateLimits.compactMap(Self.weeklyWindow(from:))
            let (used, resetTime) = resolveAggregatedWindow(
                windows: windows,
                tokenLimit: weeklyTokenLimit,
                now: now
            )
            weeklyMetric = resolveMetric(
                used: used, total: weeklyTokenLimit,
                resetTime: resetTime, cacheKey: "codexUsageCache.weekly", now: now
            )
        } else {
            // Fallback 2: sum tokens from session files within the weekly window
            let weekly = sumTokensFromSessions(now: now)
            weeklyMetric = resolveMetric(
                used: Double(weekly), total: weeklyTokenLimit,
                resetTime: nil, cacheKey: "codexUsageCache.weekly", now: now
            )
        }

        let result = UsageData(
            service: .codex,
            fiveHourUsage: weeklyMetric,
            weeklyUsage: nil,
            lastUpdated: now,
            isAvailable: true,
            planName: storedPlanName()
        )
        Self.updateCache(result, now: now)
        return result
    }

    // MARK: - ChatGPT Usage API

    private func fetchFromAPI(tokens: CodexAuthFile.Tokens, now: Date) async throws -> UsageData {
        var headers = [
            "Authorization": "Bearer \(tokens.accessToken ?? "")",
            "Accept": "application/json",
            "User-Agent": "codex-cli/0.147.0"
        ]
        if let accountID = tokens.accountId {
            headers["ChatGPT-Account-Id"] = accountID
        }

        let response: CodexUsageAPIResponse = try await apiClient.get(
            url: Self.usageURL,
            headers: headers,
            timeout: 10
        )

        // The API reports a single weekly window (7 days) in primary_window.
        let primary = response.rateLimit?.primaryWindow
        let usedPercent = primary?.usedPercent ?? 0
        let used = weeklyTokenLimit * usedPercent / 100.0

        let resetTime: Date?
        if let resetAt = primary?.resetAt, resetAt > 0 {
            resetTime = Date(timeIntervalSince1970: TimeInterval(resetAt))
        } else if let resetAfter = primary?.resetAfterSeconds, resetAfter >= 0 {
            resetTime = now.addingTimeInterval(TimeInterval(resetAfter))
        } else {
            resetTime = nil
        }

        let metric = resolveMetric(
            used: used, total: weeklyTokenLimit,
            resetTime: resetTime, cacheKey: "codexUsageCache.weekly", now: now
        )

        return UsageData(
            service: .codex,
            fiveHourUsage: metric,
            weeklyUsage: nil,
            lastUpdated: now,
            isAvailable: true,
            planName: planName(from: response.planType)
        )
    }

    /// Maps the API `plan_type` to the app's display name.
    private func planName(from apiPlan: String?) -> String? {
        if let apiPlan, !apiPlan.isEmpty {
            return apiPlan
        }
        return storedPlanName()
    }

    private func storedPlanName() -> String? {
        (defaults.string(forKey: "codexPlan")
            .flatMap { CodexPlan(rawValue: $0) } ?? .pro).rawValue
    }

    // MARK: - Credentials

    /// Loads the OAuth token + account id from `~/.codex/auth.json`.
    func loadAuthTokens(authFileURL: URL? = nil) -> CodexAuthFile.Tokens? {
        let url = authFileURL ?? self.authFileURL
        guard let data = try? Data(contentsOf: url),
              let auth = try? JSONDecoder().decode(CodexAuthFile.self, from: data),
              let accessToken = auth.tokens?.accessToken, !accessToken.isEmpty else {
            return nil
        }
        return auth.tokens
    }

    // MARK: - Metric Caching

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

    private func resolveMetric(
        used: Double, total: Double, resetTime: Date?,
        cacheKey: String, now: Date
    ) -> UsageMetric {
        let cached = validCachedMetric(forKey: cacheKey, now: now)
        let incoming = UsageMetric(used: used, total: total, unit: .tokens, resetTime: resetTime)

        if shouldPreferCachedMetric(cached, over: incoming, now: now) {
            return cached!
        }

        if incoming.used > 0 {
            saveMetricCache(incoming, forKey: cacheKey)
        }
        return incoming
    }

    private func shouldPreferCachedMetric(
        _ cached: UsageMetric?, over incoming: UsageMetric, now: Date
    ) -> Bool {
        guard let cached, cached.used > 0 else { return false }
        guard let cachedReset = cached.resetTime, cachedReset > now else { return false }
        guard incoming.used <= 0 else { return false }
        // Cached value still valid (reset not yet passed) and incoming is zero —
        // prefer cached. validCachedMetric already clears expired entries.
        return true
    }

    private func validCachedMetric(forKey key: String, now: Date) -> UsageMetric? {
        guard let cached = loadMetricCache(forKey: key) else { return nil }

        if let reset = cached.resetTime, reset <= now {
            clearMetricCache(forKey: key)
            return nil
        }

        if cached.used <= 0, cached.resetTime == nil {
            clearMetricCache(forKey: key)
            return nil
        }

        return cached
    }

    private func saveMetricCache(_ metric: UsageMetric, forKey key: String) {
        defaults.set(metric.used, forKey: "\(key).used")
        defaults.set(metric.total, forKey: "\(key).total")
        defaults.set(metric.resetTime?.timeIntervalSince1970, forKey: "\(key).resetTime")
    }

    private func loadMetricCache(forKey key: String) -> UsageMetric? {
        guard defaults.object(forKey: "\(key).used") != nil else { return nil }
        let used = defaults.double(forKey: "\(key).used")
        let total = defaults.object(forKey: "\(key).total") != nil
            ? defaults.double(forKey: "\(key).total") : weeklyTokenLimit
        let resetTimestamp = defaults.object(forKey: "\(key).resetTime") as? Double
        let resetTime = resetTimestamp.map { Date(timeIntervalSince1970: $0) }
        return UsageMetric(used: used, total: total, unit: .tokens, resetTime: resetTime)
    }

    private func clearMetricCache(forKey key: String) {
        defaults.removeObject(forKey: "\(key).used")
        defaults.removeObject(forKey: "\(key).total")
        defaults.removeObject(forKey: "\(key).resetTime")
    }

    // MARK: - Window Resolution

    /// Selects the 7-day window from a rate-limit payload.
    /// Current format: `primary` is the weekly window (window_minutes 10080).
    /// Legacy format: `primary` is 5h and `secondary` is the weekly window.
    private static func weeklyWindow(from limits: CodexRateLimits) -> CodexRateWindow? {
        if let primary = limits.primary, (primary.windowMinutes ?? 0) >= 10080 {
            return primary
        }
        return limits.secondary
    }

    /// Resolve a rate window: advance stale resets_at by window_minutes until future.
    private func resolveWindow(
        window: CodexRateWindow, tokenLimit: Double, now: Date
    ) -> (used: Double, resetTime: Date?) {
        let usedPercent = window.usedPercent ?? 0
        let used = tokenLimit * usedPercent / 100.0

        guard let resetsAt = window.resetsAt else {
            return (used, nil)
        }

        var resetDate = Date(timeIntervalSince1970: TimeInterval(resetsAt))

        if resetDate > now {
            return (used, resetDate)
        }

        // resets_at is stale — advance by window intervals to find next reset
        if let windowMinutes = window.windowMinutes, windowMinutes > 0 {
            let windowSeconds = TimeInterval(windowMinutes) * 60
            while resetDate <= now {
                resetDate = resetDate.addingTimeInterval(windowSeconds)
            }
            // Window has rolled over; usage from the old window is stale
            return (0, resetDate)
        }

        // No window_minutes to advance with — window has reset
        return (0, nil)
    }

    /// Resolve multiple windows independently and aggregate active usage.
    private func resolveAggregatedWindow(
        windows: [CodexRateWindow], tokenLimit: Double, now: Date
    ) -> (used: Double, resetTime: Date?) {
        guard !windows.isEmpty else { return (0, nil) }

        var totalUsed: Double = 0
        var earliestActiveReset: Date?
        var earliestAnyReset: Date?

        for window in windows {
            let (used, resetTime) = resolveWindow(window: window, tokenLimit: tokenLimit, now: now)
            totalUsed += used

            if let resetTime {
                if let current = earliestAnyReset {
                    earliestAnyReset = min(current, resetTime)
                } else {
                    earliestAnyReset = resetTime
                }

                if used > 0 {
                    if let current = earliestActiveReset {
                        earliestActiveReset = min(current, resetTime)
                    } else {
                        earliestActiveReset = resetTime
                    }
                }
            }
        }

        return (totalUsed, earliestActiveReset ?? earliestAnyReset)
    }

    // MARK: - Rate Limits Extraction

    private func findLatestRateLimits(now: Date) -> [CodexRateLimits]? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionsDir.path) else { return nil }

        let recentFiles = findSessionFiles(within: 7 * 24 * 3600, relativeTo: now)
        guard !recentFiles.isEmpty else { return nil }

        // Check the most recent file first (sorted by path descending = most recent date first)
        let sorted = recentFiles.sorted { $0.lastPathComponent > $1.lastPathComponent }

        for file in sorted {
            if let rateLimits = extractLatestRateLimits(from: file) {
                return rateLimits
            }
        }

        return nil
    }

    private func extractLatestRateLimits(from file: URL) -> [CodexRateLimits]? {
        guard let records = try? JSONLParser.parseFile(file, as: CodexSessionRecord.self) else {
            return nil
        }

        // Track the latest rate_limits per limit_id.
        // Codex sessions may interleave multiple limit_ids (e.g. "codex",
        // "codex_bengalfox") with independent usage counters, so we keep each
        // limit_id's latest entry and resolve/aggregate windows afterward.
        var latestByLimitID: [String: CodexRateLimits] = [:]
        for record in records {
            guard record.type == "event_msg",
                  record.payload?.type == "token_count",
                  let rl = record.payload?.rateLimits else { continue }
            let key = rl.limitId ?? ""
            latestByLimitID[key] = rl
        }

        guard !latestByLimitID.isEmpty else { return nil }
        return Array(latestByLimitID.values)
    }

    // MARK: - Token Summing Fallback

    private func sumTokensFromSessions(now: Date) -> Int {
        let weeklyCutoff = DateUtils.weeklyWindowStart(relativeTo: now)

        let files = findSessionFiles(within: 7 * 24 * 3600, relativeTo: now)
        var weeklyTotal = 0

        for file in files {
            let records = (try? JSONLParser.parseFile(file, as: CodexSessionRecord.self)) ?? []
            for record in records {
                guard record.type == "event_msg",
                      record.payload?.type == "token_count",
                      let info = record.payload?.info,
                      let lastUsage = info.lastTokenUsage,
                      let ts = record.timestamp,
                      let date = DateUtils.parseISO8601(ts) else { continue }

                let tokens = lastUsage.totalTokensSum
                if date >= weeklyCutoff && date <= now {
                    weeklyTotal += tokens
                }
            }
        }

        return weeklyTotal
    }

    // MARK: - Directory Traversal

    private func findSessionFiles(within seconds: TimeInterval, relativeTo now: Date) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionsDir.path) else { return [] }

        let cutoff = now.addingTimeInterval(-seconds)
        var results: [URL] = []

        // Recursively enumerate through YYYY/MM/DD/ subdirectories
        guard let enumerator = fm.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }

            // Skip files not modified recently
            if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
               let modDate = attrs[.modificationDate] as? Date,
               modDate < cutoff {
                continue
            }

            results.append(fileURL)
        }

        return results
    }
}

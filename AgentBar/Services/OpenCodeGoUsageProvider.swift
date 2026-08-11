import Foundation

// MARK: - OpenCode Go Usage API Response (actual format, verified 2026-08)

/// GET https://opencode.ai/zen/go/v1/usage with the plan API key. The backend
/// has served two shapes; both are supported:
///
/// Shape A (older):
/// {"useBalance":false,
///  "rollingUsage":{"status":"ok","resetInSec":13561,"usagePercent":0},
///  "weeklyUsage":{"status":"ok","resetInSec":441666,"usagePercent":69},
///  "monthlyUsage":{"status":"ok","resetInSec":2068758,"usagePercent":49}}
///
/// Shape B (current):
/// {"usage":{"rolling":{"status":"ok","percent":0,"resetsAt":"2026-08-12T01:04:55.135Z"},
///           "weekly":{"status":"ok","percent":69,"resetsAt":"..."},
///           "monthly":{"status":"ok","percent":49,"resetsAt":"..."}}}
struct OpenCodeGoUsageResponse: Decodable, Sendable {
    let useBalance: Bool?
    let rollingUsage: OpenCodeGoUsageWindow?
    let weeklyUsage: OpenCodeGoUsageWindow?
    let monthlyUsage: OpenCodeGoUsageWindow?
    let usage: OpenCodeGoUsageGroup?

    var rolling: OpenCodeGoUsageWindow? { rollingUsage ?? usage?.rolling }
    var weekly: OpenCodeGoUsageWindow? { weeklyUsage ?? usage?.weekly }
    var monthly: OpenCodeGoUsageWindow? { monthlyUsage ?? usage?.monthly }
}

struct OpenCodeGoUsageGroup: Decodable, Sendable {
    let rolling: OpenCodeGoUsageWindow?
    let weekly: OpenCodeGoUsageWindow?
    let monthly: OpenCodeGoUsageWindow?
}

struct OpenCodeGoUsageWindow: Decodable, Sendable {
    let status: String?
    let resetInSec: Int?
    let usagePercent: Double?
    let percent: Double?
    let resetsAt: String?

    /// Usage percentage regardless of API shape.
    var resolvedPercent: Double? {
        usagePercent ?? percent
    }

    /// Reset time regardless of API shape (epoch-relative seconds or ISO8601).
    func resolvedReset(relativeTo now: Date) -> Date? {
        if let resetInSec, resetInSec >= 0 {
            return now.addingTimeInterval(TimeInterval(resetInSec))
        }
        if let resetsAt {
            return DateUtils.parseISO8601(resetsAt)
        }
        return nil
    }
}

/// The OpenCode Go plan key lives in the local opencode auth store:
/// {"opencode-go": {"type": "api", "key": "sk-..."}}
private struct OpenCodeAuthFile: Decodable, Sendable {
    struct ProviderAuth: Decodable, Sendable {
        let key: String?
    }

    let opencodeGo: ProviderAuth?

    enum CodingKeys: String, CodingKey {
        case opencodeGo = "opencode-go"
    }
}

enum OpenCodeGoUsageError: Error, Sendable {
    case missingCredential
}

// MARK: - Provider

/// Reads OpenCode Go plan usage from the official usage endpoint
/// (https://opencode.ai/zen/go/v1/usage), authenticated with the plan API key
/// from `~/.local/share/opencode/auth.json`. The server reports the three plan
/// windows — rolling (5h), weekly and monthly — as percentages plus seconds
/// until reset, matching the OpenCode Go dashboard.
final class OpenCodeGoUsageProvider: UsageProviderProtocol, @unchecked Sendable {
    let serviceType: ServiceType = .opencode

    static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    private let apiClient: APIClient
    private let credentialProvider: @Sendable () -> String?
    private let credentialLock = NSLock()
    nonisolated(unsafe) private var cachedCredential: String??

    /// Minimum cache TTL to avoid excessive API requests.
    static let minCacheTTL: TimeInterval = 60
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedResponse: UsageData?
    nonisolated(unsafe) private static var cachedAt: Date?

    init(
        apiClient: APIClient = APIClient(),
        credentialProvider: (@Sendable () -> String?)? = nil
    ) {
        self.apiClient = apiClient
        self.credentialProvider = credentialProvider ?? {
            Self.loadAPIKeyFromAuthFile()
        }
        self.cachedCredential = nil
    }

    func isConfigured() async -> Bool {
        resolveCredential() != nil
    }

    /// Returns cached response if within minimum TTL, nil otherwise.
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

    /// Stores a response in the cache.
    static func updateCache(_ data: UsageData, now: Date = Date()) {
        cacheLock.lock()
        cachedResponse = data
        cachedAt = now
        cacheLock.unlock()
    }

    func fetchUsage() async throws -> UsageData {
        if let cached = Self.cachedIfFresh() {
            return cached
        }

        guard let apiKey = resolveCredential() else {
            throw OpenCodeGoUsageError.missingCredential
        }

        let now = Date()

        let response: OpenCodeGoUsageResponse = try await apiClient.get(
            url: Self.usageURL,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json"
            ]
        )

        let result = UsageData(
            service: .opencode,
            fiveHourUsage: metric(from: response.rolling, now: now),
            weeklyUsage: metric(from: response.weekly, now: now),
            monthlyUsage: metric(from: response.monthly, now: now),
            lastUpdated: now,
            isAvailable: true,
            planName: "Go"
        )

        Self.updateCache(result, now: now)
        return result
    }

    // MARK: - Helpers

    /// Builds a percent-based metric: `used` is the server's usage percentage
    /// against a total of 100, with the reset time derived from the window.
    private func metric(
        from window: OpenCodeGoUsageWindow?,
        now: Date
    ) -> UsageMetric {
        UsageMetric(
            used: window?.resolvedPercent ?? 0,
            total: 100,
            unit: .percent,
            resetTime: window?.resolvedReset(relativeTo: now)
        )
    }

    // MARK: - Credentials

    private func resolveCredential() -> String? {
        credentialLock.lock()
        if let cachedCredential {
            credentialLock.unlock()
            return cachedCredential
        }

        let loadedCredential = credentialProvider()
        cachedCredential = loadedCredential
        credentialLock.unlock()
        return loadedCredential
    }

    /// Reads the plan API key from the opencode auth file:
    /// `~/.local/share/opencode/auth.json` → `opencode-go.key`.
    static func loadAPIKeyFromAuthFile(
        authFileURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> String? {
        let home = fileManager.homeDirectoryForCurrentUser
        let url = authFileURL ?? home.appendingPathComponent(".local/share/opencode/auth.json")
        guard let data = try? Data(contentsOf: url),
              let auth = try? JSONDecoder().decode(OpenCodeAuthFile.self, from: data) else {
            return nil
        }
        return auth.opencodeGo?.key
    }
}

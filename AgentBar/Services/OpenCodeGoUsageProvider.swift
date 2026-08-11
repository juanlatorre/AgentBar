import Foundation

// MARK: - OpenCode Go Usage API Response (actual format, verified 2026-08)

/// GET https://opencode.ai/zen/go/v1/usage with the plan API key returns:
/// {"useBalance":false,
///  "rollingUsage":{"status":"ok","resetInSec":13561,"usagePercent":0},
///  "weeklyUsage":{"status":"ok","resetInSec":441666,"usagePercent":69},
///  "monthlyUsage":{"status":"ok","resetInSec":2068758,"usagePercent":49}}
struct OpenCodeGoUsageResponse: Decodable, Sendable {
    let useBalance: Bool?
    let rollingUsage: OpenCodeGoUsageWindow?
    let weeklyUsage: OpenCodeGoUsageWindow?
    let monthlyUsage: OpenCodeGoUsageWindow?
}

struct OpenCodeGoUsageWindow: Decodable, Sendable {
    let status: String?
    let resetInSec: Int?
    let usagePercent: Double?
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
            fiveHourUsage: metric(
                from: response.rollingUsage,
                resetInSec: response.rollingUsage?.resetInSec,
                now: now
            ),
            weeklyUsage: metric(
                from: response.weeklyUsage,
                resetInSec: response.weeklyUsage?.resetInSec,
                now: now
            ),
            monthlyUsage: metric(
                from: response.monthlyUsage,
                resetInSec: response.monthlyUsage?.resetInSec,
                now: now
            ),
            lastUpdated: now,
            isAvailable: true,
            planName: "Go"
        )

        Self.updateCache(result, now: now)
        return result
    }

    // MARK: - Helpers

    /// Builds a percent-based metric: `used` is the server's usage percentage
    /// against a total of 100, with the reset time derived from `resetInSec`.
    private func metric(
        from window: OpenCodeGoUsageWindow?,
        resetInSec: Int?,
        now: Date
    ) -> UsageMetric {
        let resetTime = resetInSec.flatMap { sec -> Date? in
            sec >= 0 ? now.addingTimeInterval(TimeInterval(sec)) : nil
        }
        return UsageMetric(
            used: window?.usagePercent ?? 0,
            total: 100,
            unit: .percent,
            resetTime: resetTime
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

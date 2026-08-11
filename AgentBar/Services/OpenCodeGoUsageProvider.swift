import Foundation
import SQLite3

// MARK: - OpenCode Go Message Record Models (matches actual opencode SQLite database)

/// Subset of the `message` row JSON payload stored in `~/.local/share/opencode/opencode.db`.
///
/// OpenCode Go messages carry `providerID == "opencode-go"` and a per-request
/// `cost` in USD, which is what the plan's usage limits are denominated in
/// (see https://opencode.ai/docs/go: 5h limit $12, weekly limit $30, monthly $60).
struct OpenCodeGoMessageRecord: Decodable, Sendable {
    struct Model: Decodable, Sendable {
        let providerID: String?
    }

    let providerID: String?
    let model: Model?
    let cost: Double?

    /// Whether this message was served through the OpenCode Go plan.
    var isOpenCodeGo: Bool {
        providerID == "opencode-go" || model?.providerID == "opencode-go"
    }
}

enum OpenCodeGoUsageError: Error, Sendable {
    case databaseUnavailable
    case missingMessageTable
}

// MARK: - Provider

/// Reads OpenCode Go plan usage from the local opencode SQLite database
/// (`~/.local/share/opencode/opencode.db`, table `message`).
///
/// Each message row stores `time_created` (epoch milliseconds) and a JSON
/// payload in `data` that includes `providerID` and `cost` (USD). Only
/// messages served through the `opencode-go` provider are counted, summed
/// across the three plan windows (5h / weekly / monthly). Limits default to
/// the published Go plan values ($12 / $30 / $60) and are configurable in
/// Settings.
final class OpenCodeGoUsageProvider: UsageProviderProtocol, @unchecked Sendable {
    let serviceType: ServiceType = .opencode

    private let databaseURL: URL
    private let fiveHourDollarLimit: Double
    private let weeklyDollarLimit: Double
    private let monthlyDollarLimit: Double

    init(
        databaseURL: URL? = nil,
        fiveHourDollarLimit: Double = 12,
        weeklyDollarLimit: Double = 30,
        monthlyDollarLimit: Double = 60
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.databaseURL = databaseURL
            ?? home.appendingPathComponent(".local/share/opencode/opencode.db")
        self.fiveHourDollarLimit = fiveHourDollarLimit
        self.weeklyDollarLimit = weeklyDollarLimit
        self.monthlyDollarLimit = monthlyDollarLimit
    }

    func isConfigured() async -> Bool {
        FileManager.default.fileExists(atPath: databaseURL.path)
    }

    func fetchUsage() async throws -> UsageData {
        let now = Date()
        let totals = try sumCostFromDatabase(now: now)

        return UsageData(
            service: .opencode,
            fiveHourUsage: UsageMetric(
                used: totals.fiveHour,
                total: fiveHourDollarLimit,
                unit: .dollars,
                resetTime: nil
            ),
            weeklyUsage: UsageMetric(
                used: totals.weekly,
                total: weeklyDollarLimit,
                unit: .dollars,
                resetTime: nil
            ),
            monthlyUsage: UsageMetric(
                used: totals.monthly,
                total: monthlyDollarLimit,
                unit: .dollars,
                resetTime: nil
            ),
            lastUpdated: now,
            isAvailable: true,
            planName: "Go"
        )
    }

    // MARK: - Database Reading

    private func sumCostFromDatabase(now: Date) throws -> (fiveHour: Double, weekly: Double, monthly: Double) {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw OpenCodeGoUsageError.databaseUnavailable
        }

        var handle: OpaquePointer?
        let openFlags = SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(databaseURL.path, &handle, openFlags, nil) == SQLITE_OK,
              let handle else {
            sqlite3_close(handle)
            throw OpenCodeGoUsageError.databaseUnavailable
        }
        defer { sqlite3_close(handle) }

        // One query for the 30d window; the 5h / 7d splits happen in Swift.
        let monthlyCutoffMillis = Int64(DateUtils.monthlyWindowStart(relativeTo: now)
            .timeIntervalSince1970 * 1000)

        let query = """
            SELECT time_created, data FROM message WHERE time_created >= ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            throw OpenCodeGoUsageError.missingMessageTable
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_bind_int64(statement, 1, monthlyCutoffMillis) == SQLITE_OK else {
            throw OpenCodeGoUsageError.databaseUnavailable
        }

        let fiveHourCutoff = DateUtils.fiveHourWindowStart(relativeTo: now)
        let weeklyCutoff = DateUtils.weeklyWindowStart(relativeTo: now)
        let decoder = JSONDecoder()
        var fiveHourTotal: Double = 0
        var weeklyTotal: Double = 0
        var monthlyTotal: Double = 0

        while sqlite3_step(statement) == SQLITE_ROW {
            let createdMillis = sqlite3_column_int64(statement, 0)
            guard createdMillis > 0 else { continue }

            guard let dataPointer = sqlite3_column_text(statement, 1) else { continue }
            let jsonString = String(cString: dataPointer)
            guard let jsonData = jsonString.data(using: .utf8),
                  let record = try? decoder.decode(OpenCodeGoMessageRecord.self, from: jsonData),
                  record.isOpenCodeGo,
                  let cost = record.cost, cost > 0 else { continue }

            let messageDate = Date(timeIntervalSince1970: TimeInterval(createdMillis) / 1000)
            if messageDate >= fiveHourCutoff {
                fiveHourTotal += cost
            }
            if messageDate >= weeklyCutoff {
                weeklyTotal += cost
            }
            monthlyTotal += cost
        }

        return (fiveHourTotal, weeklyTotal, monthlyTotal)
    }
}

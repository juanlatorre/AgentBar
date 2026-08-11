import Foundation
import SQLite3

// MARK: - OpenCode Message Record Models (matches actual opencode SQLite database)

/// Subset of the `message` row JSON payload stored in `~/.local/share/opencode/opencode.db`.
struct OpenCodeMessageRecord: Decodable, Sendable {
    struct Tokens: Decodable, Sendable {
        let total: Int?
    }

    let tokens: Tokens?
}

enum OpenCodeUsageError: Error, Sendable {
    case databaseUnavailable
    case missingMessageTable
}

// MARK: - Provider

/// Reads token usage from the local opencode SQLite database
/// (`~/.local/share/opencode/opencode.db`, table `message`).
///
/// Each message row stores `time_created` (epoch milliseconds) and a JSON
/// payload in `data` that includes `tokens.total`. Usage is summed across the
/// standard 5h / 7d sliding windows, mirroring the Codex provider's approach.
final class OpenCodeUsageProvider: UsageProviderProtocol, @unchecked Sendable {
    let serviceType: ServiceType = .opencode

    private let databaseURL: URL
    private let fiveHourTokenLimit: Double
    private let weeklyTokenLimit: Double

    init(
        databaseURL: URL? = nil,
        fiveHourTokenLimit: Double = 10_000_000,
        weeklyTokenLimit: Double = 100_000_000
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.databaseURL = databaseURL
            ?? home.appendingPathComponent(".local/share/opencode/opencode.db")
        self.fiveHourTokenLimit = fiveHourTokenLimit
        self.weeklyTokenLimit = weeklyTokenLimit
    }

    func isConfigured() async -> Bool {
        FileManager.default.fileExists(atPath: databaseURL.path)
    }

    func fetchUsage() async throws -> UsageData {
        let now = Date()
        let totals = try sumTokensFromDatabase(now: now)

        return UsageData(
            service: .opencode,
            fiveHourUsage: UsageMetric(
                used: Double(totals.fiveHour),
                total: fiveHourTokenLimit,
                unit: .tokens,
                resetTime: nil
            ),
            weeklyUsage: UsageMetric(
                used: Double(totals.weekly),
                total: weeklyTokenLimit,
                unit: .tokens,
                resetTime: nil
            ),
            lastUpdated: now,
            isAvailable: true
        )
    }

    // MARK: - Database Reading

    private func sumTokensFromDatabase(now: Date) throws -> (fiveHour: Int, weekly: Int) {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw OpenCodeUsageError.databaseUnavailable
        }

        var handle: OpaquePointer?
        let openFlags = SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(databaseURL.path, &handle, openFlags, nil) == SQLITE_OK,
              let handle else {
            sqlite3_close(handle)
            throw OpenCodeUsageError.databaseUnavailable
        }
        defer { sqlite3_close(handle) }

        // One query for the 7d window; the 5h split happens in Swift.
        let weeklyCutoffMillis = Int64(DateUtils.weeklyWindowStart(relativeTo: now)
            .timeIntervalSince1970 * 1000)

        let query = """
            SELECT time_created, data FROM message WHERE time_created >= ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            throw OpenCodeUsageError.missingMessageTable
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_bind_int64(statement, 1, weeklyCutoffMillis) == SQLITE_OK else {
            throw OpenCodeUsageError.databaseUnavailable
        }

        let fiveHourCutoff = DateUtils.fiveHourWindowStart(relativeTo: now)
        let decoder = JSONDecoder()
        var fiveHourTotal = 0
        var weeklyTotal = 0

        while sqlite3_step(statement) == SQLITE_ROW {
            let createdMillis = sqlite3_column_int64(statement, 0)
            guard createdMillis > 0 else { continue }

            guard let dataPointer = sqlite3_column_text(statement, 1) else { continue }
            let jsonString = String(cString: dataPointer)
            guard let jsonData = jsonString.data(using: .utf8),
                  let record = try? decoder.decode(OpenCodeMessageRecord.self, from: jsonData),
                  let total = record.tokens?.total, total > 0 else { continue }

            let messageDate = Date(timeIntervalSince1970: TimeInterval(createdMillis) / 1000)
            if messageDate >= fiveHourCutoff {
                fiveHourTotal += total
            }
            weeklyTotal += total
        }

        return (fiveHourTotal, weeklyTotal)
    }
}

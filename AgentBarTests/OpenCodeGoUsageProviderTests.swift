import XCTest
import SQLite3
@testable import AgentBar

final class OpenCodeGoUsageProviderTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeGoUsageProviderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testIsConfiguredFalseWhenDatabaseMissing() async {
        let provider = OpenCodeGoUsageProvider(databaseURL: tempDirectory.appendingPathComponent("missing.db"))

        let configured = await provider.isConfigured()

        XCTAssertFalse(configured)
    }

    func testFetchUsageThrowsWhenDatabaseMissing() async {
        let provider = OpenCodeGoUsageProvider(databaseURL: tempDirectory.appendingPathComponent("missing.db"))

        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected fetchUsage to throw when the database file is missing.")
        } catch {
            XCTAssertEqual(error as? OpenCodeGoUsageError, .databaseUnavailable)
        }
    }

    func testFetchUsageThrowsWhenMessageTableMissing() async throws {
        let dbURL = tempDirectory.appendingPathComponent("empty.db")
        try createDatabase(at: dbURL, createMessageTable: false)

        let provider = OpenCodeGoUsageProvider(databaseURL: dbURL)

        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected fetchUsage to throw when the message table is missing.")
        } catch {
            XCTAssertEqual(error as? OpenCodeGoUsageError, .missingMessageTable)
        }
    }

    func testFetchUsageSumsCostWithinWindows() async throws {
        let dbURL = tempDirectory.appendingPathComponent("usage.db")
        try createDatabase(at: dbURL, createMessageTable: true)

        let now = Date()
        try insertMessage(
            into: dbURL,
            timeCreated: now.addingTimeInterval(-1 * 3600),   // inside 5h and 7d
            providerID: "opencode-go",
            cost: 1.50
        )
        try insertMessage(
            into: dbURL,
            timeCreated: now.addingTimeInterval(-4 * 3600),   // inside 5h and 7d
            providerID: "opencode-go",
            cost: 2.25
        )
        try insertMessage(
            into: dbURL,
            timeCreated: now.addingTimeInterval(-6 * 3600),   // only inside 7d
            providerID: "opencode-go",
            cost: 4.00
        )
        try insertMessage(
            into: dbURL,
            timeCreated: now.addingTimeInterval(-8 * 24 * 3600), // outside both windows
            providerID: "opencode-go",
            cost: 8.00
        )
        // Messages from other providers must never count toward the Go plan.
        try insertMessage(
            into: dbURL,
            timeCreated: now.addingTimeInterval(-2 * 3600),
            providerID: "zai-coding-plan",
            cost: 99.00
        )
        try insertMessage(
            into: dbURL,
            timeCreated: now.addingTimeInterval(-2 * 3600),
            providerID: "opencode",
            cost: 99.00
        )

        let provider = OpenCodeGoUsageProvider(
            databaseURL: dbURL,
            fiveHourDollarLimit: 12,
            weeklyDollarLimit: 30
        )

        let usage = try await provider.fetchUsage()

        XCTAssertEqual(usage.service, .opencode)
        XCTAssertEqual(usage.planName, "Go")
        XCTAssertEqual(usage.fiveHourUsage.unit, .dollars)
        XCTAssertEqual(
            usage.fiveHourUsage.used,
            3.75,
            accuracy: 0.001,
            "Expected 5h window to include only the two newest opencode-go messages."
        )
        XCTAssertEqual(usage.fiveHourUsage.total, 12)
        XCTAssertEqual(usage.fiveHourUsage.remaining, 8.25, accuracy: 0.001)
        XCTAssertEqual(usage.fiveHourUsage.remainingPercentage, 0.6875, accuracy: 0.001)
        XCTAssertEqual(
            usage.weeklyUsage?.used ?? 0,
            7.75,
            accuracy: 0.001,
            "Expected 7d window to include the three recent opencode-go messages."
        )
        XCTAssertEqual(usage.weeklyUsage?.total, 30)
        XCTAssertEqual(usage.weeklyUsage?.remaining ?? 0, 22.25, accuracy: 0.001)
    }

    func testFetchUsageIgnoresMessagesWithoutCost() async throws {
        let dbURL = tempDirectory.appendingPathComponent("partial.db")
        try createDatabase(at: dbURL, createMessageTable: true)

        let now = Date()
        try insertMessage(
            into: dbURL,
            timeCreated: now.addingTimeInterval(-1 * 3600),
            dataJSON: #"{"role":"user","providerID":"opencode-go","cost":0}"#
        )
        try insertMessage(
            into: dbURL,
            timeCreated: now.addingTimeInterval(-2 * 3600),
            dataJSON: #"{"role":"assistant","providerID":"opencode-go","cost":0.75}"#
        )
        try insertMessage(
            into: dbURL,
            timeCreated: now.addingTimeInterval(-3 * 3600),
            dataJSON: #"{"role":"assistant","providerID":"opencode-go"}"#
        )

        let provider = OpenCodeGoUsageProvider(
            databaseURL: dbURL,
            fiveHourDollarLimit: 12,
            weeklyDollarLimit: 30
        )

        let usage = try await provider.fetchUsage()

        XCTAssertEqual(usage.fiveHourUsage.used, 0.75, accuracy: 0.001)
        XCTAssertEqual(usage.weeklyUsage?.used ?? 0, 0.75, accuracy: 0.001)
    }

    // MARK: - Test Database Helpers

    private func createDatabase(at url: URL, createMessageTable: Bool) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw NSError(domain: "OpenCodeGoUsageProviderTests", code: 1)
        }
        defer { sqlite3_close(handle) }

        if createMessageTable {
            let createSQL = """
                CREATE TABLE message (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    time_created INTEGER NOT NULL,
                    time_updated INTEGER NOT NULL,
                    data TEXT NOT NULL
                )
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, createSQL, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw NSError(domain: "OpenCodeGoUsageProviderTests", code: 2)
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw NSError(domain: "OpenCodeGoUsageProviderTests", code: 3)
            }
        }
    }

    private func insertMessage(
        into url: URL,
        timeCreated: Date,
        providerID: String,
        cost: Double
    ) throws {
        let json = #"{"role":"assistant","providerID":"\#(providerID)","cost":\#(cost)}"#
        try insertMessage(into: url, timeCreated: timeCreated, dataJSON: json)
    }

    private func insertMessage(
        into url: URL,
        timeCreated: Date,
        dataJSON: String
    ) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw NSError(domain: "OpenCodeGoUsageProviderTests", code: 10)
        }
        defer { sqlite3_close(handle) }

        let insertSQL = """
            INSERT INTO message (id, session_id, time_created, time_updated, data)
            VALUES (?, ?, ?, ?, ?)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, insertSQL, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw NSError(domain: "OpenCodeGoUsageProviderTests", code: 11)
        }
        defer { sqlite3_finalize(statement) }

        let id = "msg_\(UUID().uuidString)" as NSString
        let sessionID = "ses_\(UUID().uuidString)" as NSString
        let json = dataJSON as NSString
        let createdMillis = Int64(timeCreated.timeIntervalSince1970 * 1000)
        let updatedMillis = createdMillis
        let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        sqlite3_bind_text(statement, 1, id.utf8String, -1, transientDestructor)
        sqlite3_bind_text(statement, 2, sessionID.utf8String, -1, transientDestructor)
        sqlite3_bind_int64(statement, 3, createdMillis)
        sqlite3_bind_int64(statement, 4, updatedMillis)
        sqlite3_bind_text(statement, 5, json.utf8String, -1, transientDestructor)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "OpenCodeGoUsageProviderTests", code: 12)
        }
    }
}

import XCTest
import SQLite3
@testable import AgentBar

final class OpenCodeUsageProviderTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeUsageProviderTests-\(UUID().uuidString)")
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
        let provider = OpenCodeUsageProvider(databaseURL: tempDirectory.appendingPathComponent("missing.db"))

        let configured = await provider.isConfigured()

        XCTAssertFalse(configured)
    }

    func testFetchUsageThrowsWhenDatabaseMissing() async {
        let provider = OpenCodeUsageProvider(databaseURL: tempDirectory.appendingPathComponent("missing.db"))

        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected fetchUsage to throw when the database file is missing.")
        } catch {
            XCTAssertEqual(error as? OpenCodeUsageError, .databaseUnavailable)
        }
    }

    func testFetchUsageThrowsWhenMessageTableMissing() async throws {
        let dbURL = tempDirectory.appendingPathComponent("empty.db")
        try createDatabase(at: dbURL, createMessageTable: false)

        let provider = OpenCodeUsageProvider(databaseURL: dbURL)

        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected fetchUsage to throw when the message table is missing.")
        } catch {
            XCTAssertEqual(error as? OpenCodeUsageError, .missingMessageTable)
        }
    }

    func testFetchUsageSumsTokensWithinWindows() async throws {
        let dbURL = tempDirectory.appendingPathComponent("usage.db")
        try createDatabase(at: dbURL, createMessageTable: true)

        let now = Date()
        try insertMessage(
            into: dbURL,
            timeCreated: now.addingTimeInterval(-1 * 3600),   // inside 5h and 7d
            totalTokens: 1_000
        )
        try insertMessage(
            into: dbURL,
            timeCreated: now.addingTimeInterval(-4 * 3600),   // inside 5h and 7d
            totalTokens: 2_000
        )
        try insertMessage(
            into: dbURL,
            timeCreated: now.addingTimeInterval(-6 * 3600),   // only inside 7d
            totalTokens: 4_000
        )
        try insertMessage(
            into: dbURL,
            timeCreated: now.addingTimeInterval(-8 * 24 * 3600), // outside both windows
            totalTokens: 8_000
        )

        let provider = OpenCodeUsageProvider(
            databaseURL: dbURL,
            fiveHourTokenLimit: 10_000,
            weeklyTokenLimit: 20_000
        )

        let usage = try await provider.fetchUsage()

        XCTAssertEqual(usage.service, .opencode)
        XCTAssertEqual(usage.fiveHourUsage.used, 3_000, "Expected 5h window to include the two newest messages.")
        XCTAssertEqual(usage.fiveHourUsage.total, 10_000)
        XCTAssertEqual(usage.weeklyUsage?.used, 7_000, "Expected 7d window to include the three recent messages.")
        XCTAssertEqual(usage.weeklyUsage?.total, 20_000)
        XCTAssertEqual(usage.weeklyUsage?.remaining, 13_000)
        XCTAssertEqual(usage.fiveHourUsage.remaining, 7_000)
    }

    func testFetchUsageSkipsMessagesWithoutTokenData() async throws {
        let dbURL = tempDirectory.appendingPathComponent("partial.db")
        try createDatabase(at: dbURL, createMessageTable: true)

        let now = Date()
        try insertMessage(
            into: dbURL,
            timeCreated: now.addingTimeInterval(-1 * 3600),
            dataJSON: #"{"role":"user","content":"hello"}"#
        )
        try insertMessage(
            into: dbURL,
            timeCreated: now.addingTimeInterval(-2 * 3600),
            dataJSON: #"{"role":"assistant","tokens":{"total":500}}"#
        )
        try insertMessage(
            into: dbURL,
            timeCreated: now.addingTimeInterval(-3 * 3600),
            dataJSON: #"{"role":"assistant","tokens":null}"#
        )

        let provider = OpenCodeUsageProvider(
            databaseURL: dbURL,
            fiveHourTokenLimit: 10_000,
            weeklyTokenLimit: 20_000
        )

        let usage = try await provider.fetchUsage()

        XCTAssertEqual(usage.fiveHourUsage.used, 500, "Expected only the message with token data to count.")
        XCTAssertEqual(usage.weeklyUsage?.used, 500)
    }

    // MARK: - Test Database Helpers

    private func createDatabase(at url: URL, createMessageTable: Bool) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw NSError(domain: "OpenCodeUsageProviderTests", code: 1)
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
                throw NSError(domain: "OpenCodeUsageProviderTests", code: 2)
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw NSError(domain: "OpenCodeUsageProviderTests", code: 3)
            }
        }
    }

    private func insertMessage(
        into url: URL,
        timeCreated: Date,
        totalTokens: Int
    ) throws {
        let json = #"{"role":"assistant","tokens":{"total":\#(totalTokens)}}"#
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
            throw NSError(domain: "OpenCodeUsageProviderTests", code: 10)
        }
        defer { sqlite3_close(handle) }

        let insertSQL = """
            INSERT INTO message (id, session_id, time_created, time_updated, data)
            VALUES (?, ?, ?, ?, ?)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, insertSQL, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw NSError(domain: "OpenCodeUsageProviderTests", code: 11)
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
            throw NSError(domain: "OpenCodeUsageProviderTests", code: 12)
        }
    }
}

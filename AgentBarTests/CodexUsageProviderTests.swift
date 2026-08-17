import XCTest
@testable import AgentBar

final class CodexUsageProviderTests: XCTestCase {

    var tempDir: URL!
    var testDefaults: UserDefaults!
    private var suiteName: String!

    /// Auth file path that does not exist — forces JSONL fallback in legacy tests.
    private var noAuthURL: URL {
        tempDir.appendingPathComponent("no-auth.json")
    }

    override func setUp() {
        super.setUp()
        CodexUsageProvider.updateCache(CodexUsageProviderTests.staleCachedData(), now: .distantPast)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        suiteName = "CodexUsageProviderTests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
    }

    /// Returns a cached UsageData far in the past so it's never "fresh".
    private static func staleCachedData() -> UsageData {
        UsageData(
            service: .codex,
            fiveHourUsage: UsageMetric(used: 0, total: 0, unit: .tokens, resetTime: nil),
            weeklyUsage: nil,
            lastUpdated: .distantPast,
            isAvailable: true,
            planName: nil
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Directory Traversal

    func testFindsFilesInDateSubdirectories() async throws {
        // Create YYYY/MM/DD/ structure
        let dateDir = tempDir.appendingPathComponent("2026/02/13")
        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)

        let now = ISO8601DateFormatter().string(from: Date())
        let weeklyReset = Int(Date().addingTimeInterval(7 * 24 * 3600).timeIntervalSince1970)
        let content = """
        {"timestamp":"\(now)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"output_tokens":500,"cached_input_tokens":200,"reasoning_output_tokens":100},"total_token_usage":{"input_tokens":1000,"output_tokens":500,"cached_input_tokens":200,"reasoning_output_tokens":100}},"rate_limits":{"primary":{"used_percent":5.0,"window_minutes":10080,"resets_at":\(weeklyReset)}}}}
        """
        let file = dateDir.appendingPathComponent("rollout-2026-02-13T00-00-00-test.jsonl")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let provider = CodexUsageProvider(
            sessionsDir: tempDir,
            weeklyTokenLimit: 100_000_000,
            defaults: testDefaults,
            authFileURL: noAuthURL
        )
        let usage = try await provider.fetchUsage()

        XCTAssertEqual(usage.service, .codex)
        XCTAssertTrue(usage.isAvailable)
        // 5% of 100M = 5,000,000 — single weekly window
        XCTAssertEqual(usage.fiveHourUsage.used, 5_000_000, accuracy: 1)
        XCTAssertNil(usage.weeklyUsage, "ChatGPT has no secondary window anymore.")
        XCTAssertEqual(usage.fiveHourUsage.unit, .tokens)
    }

    // MARK: - Rate Limits Parsing

    func testUsesLatestRateLimitsFromMostRecentFile() async throws {
        let dateDir = tempDir.appendingPathComponent("2026/02/13")
        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)

        let now = ISO8601DateFormatter().string(from: Date())
        let weeklyReset = Int(Date().addingTimeInterval(7 * 24 * 3600).timeIntervalSince1970)

        // First event: 1%
        // Second event: 3% (latest)
        let content = """
        {"timestamp":"\(now)","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":1.0,"window_minutes":10080,"resets_at":\(weeklyReset)}}}}
        {"timestamp":"\(now)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500,"output_tokens":200},"total_token_usage":{"input_tokens":500,"output_tokens":200}},"rate_limits":{"primary":{"used_percent":3.0,"window_minutes":10080,"resets_at":\(weeklyReset)}}}}
        """
        let file = dateDir.appendingPathComponent("rollout-test.jsonl")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let provider = CodexUsageProvider(
            sessionsDir: tempDir,
            weeklyTokenLimit: 100_000_000,
            defaults: testDefaults,
            authFileURL: noAuthURL
        )
        let usage = try await provider.fetchUsage()

        // Should use the latest (3%)
        XCTAssertEqual(usage.fiveHourUsage.used, 3_000_000, accuracy: 1)
        XCTAssertNil(usage.weeklyUsage)
    }

    func testResetWindowMeansZeroUsage() async throws {
        let dateDir = tempDir.appendingPathComponent("2026/02/13")
        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)

        let now = ISO8601DateFormatter().string(from: Date())
        // resets_at is in the past = window has already reset
        let pastReset = Int(Date().addingTimeInterval(-3600).timeIntervalSince1970)

        let content = """
        {"timestamp":"\(now)","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":50.0,"window_minutes":10080,"resets_at":\(pastReset)}}}}
        """
        let file = dateDir.appendingPathComponent("rollout-test.jsonl")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let provider = CodexUsageProvider(
            sessionsDir: tempDir,
            weeklyTokenLimit: 100_000_000,
            defaults: testDefaults,
            authFileURL: noAuthURL
        )
        let usage = try await provider.fetchUsage()

        // Past resets_at means usage has reset to 0
        XCTAssertEqual(usage.fiveHourUsage.used, 0)
        XCTAssertNil(usage.weeklyUsage)
    }

    func testLegacyFormatFallsBackToSecondaryWeeklyWindow() async throws {
        let dateDir = tempDir.appendingPathComponent("2026/02/13")
        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)

        let now = ISO8601DateFormatter().string(from: Date())
        let weeklyReset = Int(Date().addingTimeInterval(7 * 24 * 3600).timeIntervalSince1970)

        // Legacy sessions expose primary=5h and secondary=7d; the weekly window
        // must be taken from secondary.
        let content = """
        {"timestamp":"\(now)","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":90.0,"window_minutes":300,"resets_at":\(weeklyReset)},"secondary":{"used_percent":4.0,"window_minutes":10080,"resets_at":\(weeklyReset)}}}}
        """
        let file = dateDir.appendingPathComponent("rollout-test.jsonl")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let provider = CodexUsageProvider(
            sessionsDir: tempDir,
            weeklyTokenLimit: 100_000_000,
            defaults: testDefaults,
            authFileURL: noAuthURL
        )
        let usage = try await provider.fetchUsage()

        // 4% of 100M = 4,000,000 (from secondary), not the 5h primary.
        XCTAssertEqual(usage.fiveHourUsage.used, 4_000_000, accuracy: 1)
        XCTAssertNil(usage.weeklyUsage)
    }

    // MARK: - Event Type Filtering

    func testFiltersOnlyEventMsgTokenCount() async throws {
        let dateDir = tempDir.appendingPathComponent("2026/02/14")
        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)

        let now = ISO8601DateFormatter().string(from: Date())
        let weeklyReset = Int(Date().addingTimeInterval(7 * 24 * 3600).timeIntervalSince1970)

        let content = """
        {"timestamp":"\(now)","type":"session_meta","payload":{"id":"test"}}
        {"timestamp":"\(now)","type":"response_item","payload":{"type":"message"}}
        {"timestamp":"\(now)","type":"event_msg","payload":{"type":"user_message"}}
        {"timestamp":"\(now)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":50},"total_token_usage":{"input_tokens":100,"output_tokens":50}},"rate_limits":{"primary":{"used_percent":1.0,"window_minutes":10080,"resets_at":\(weeklyReset)}}}}
        """
        let file = dateDir.appendingPathComponent("rollout-test.jsonl")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let provider = CodexUsageProvider(
            sessionsDir: tempDir,
            weeklyTokenLimit: 100_000_000,
            defaults: testDefaults,
            authFileURL: noAuthURL
        )
        let usage = try await provider.fetchUsage()

        // Only the token_count event_msg should be processed
        XCTAssertEqual(usage.fiveHourUsage.used, 1_000_000, accuracy: 1)
    }

    // MARK: - Token Summing Fallback

    func testFallsBackToTokenSummingWithoutRateLimits() async throws {
        let dateDir = tempDir.appendingPathComponent("2026/02/14")
        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)

        let now = ISO8601DateFormatter().string(from: Date())

        // event_msg with token_count but no rate_limits
        let content = """
        {"timestamp":"\(now)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"output_tokens":500,"cached_input_tokens":200,"reasoning_output_tokens":100},"total_token_usage":{"input_tokens":1000,"output_tokens":500,"cached_input_tokens":200,"reasoning_output_tokens":100}}}}
        {"timestamp":"\(now)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":2000,"output_tokens":800,"cached_input_tokens":300,"reasoning_output_tokens":150},"total_token_usage":{"input_tokens":3000,"output_tokens":1300,"cached_input_tokens":500,"reasoning_output_tokens":250}}}}
        """
        let file = dateDir.appendingPathComponent("rollout-test.jsonl")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let provider = CodexUsageProvider(
            sessionsDir: tempDir,
            weeklyTokenLimit: 100_000_000,
            defaults: testDefaults,
            authFileURL: noAuthURL
        )
        let usage = try await provider.fetchUsage()

        // Fallback: sum last_token_usage from both events
        // Event 1: 1000+500+200+100 = 1800
        // Event 2: 2000+800+300+150 = 3250
        // Total: 5050
        XCTAssertEqual(usage.fiveHourUsage.used, 5050)
        XCTAssertNil(usage.weeklyUsage)
    }

    // MARK: - Multiple limit_id Merging

    func testMergesMultipleLimitIDs() async throws {
        let dateDir = tempDir.appendingPathComponent("2026/02/15")
        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)

        let now = ISO8601DateFormatter().string(from: Date())
        let weeklyReset1 = Int(Date().addingTimeInterval(7 * 24 * 3600).timeIntervalSince1970)
        let weeklyReset2 = Int(Date().addingTimeInterval(8 * 24 * 3600).timeIntervalSince1970)

        // Two different limit_ids interleaved in the same session
        let content = """
        {"timestamp":"\(now)","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":12.0,"window_minutes":10080,"resets_at":\(weeklyReset1)}}}}
        {"timestamp":"\(now)","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex_bengalfox","primary":{"used_percent":3.0,"window_minutes":10080,"resets_at":\(weeklyReset2)}}}}
        """
        let file = dateDir.appendingPathComponent("rollout-test.jsonl")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let provider = CodexUsageProvider(
            sessionsDir: tempDir,
            weeklyTokenLimit: 100_000_000,
            defaults: testDefaults,
            authFileURL: noAuthURL
        )
        let usage = try await provider.fetchUsage()

        // Should sum: 12% + 3% = 15% of 100M = 15,000,000
        XCTAssertEqual(usage.fiveHourUsage.used, 15_000_000, accuracy: 1)
        // Reset time should be the earliest (most conservative)
        XCTAssertNotNil(usage.fiveHourUsage.resetTime)
        XCTAssertEqual(
            usage.fiveHourUsage.resetTime!.timeIntervalSince1970,
            Double(weeklyReset1),
            accuracy: 1
        )
    }

    func testMergedLimitIDsKeepActiveUsageWhenOnePrimaryWindowIsStale() async throws {
        let dateDir = tempDir.appendingPathComponent("2026/02/15")
        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)

        let now = ISO8601DateFormatter().string(from: Date())
        let staleReset = Int(Date().addingTimeInterval(-3600).timeIntervalSince1970)
        let activeReset = Int(Date().addingTimeInterval(7 * 24 * 3600).timeIntervalSince1970)

        let content = """
        {"timestamp":"\(now)","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":12.0,"window_minutes":10080,"resets_at":\(staleReset)}}}}
        {"timestamp":"\(now)","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex_bengalfox","primary":{"used_percent":3.0,"window_minutes":10080,"resets_at":\(activeReset)}}}}
        """
        let file = dateDir.appendingPathComponent("rollout-test.jsonl")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let provider = CodexUsageProvider(
            sessionsDir: tempDir,
            weeklyTokenLimit: 100_000_000,
            defaults: testDefaults,
            authFileURL: noAuthURL
        )
        let usage = try await provider.fetchUsage()

        // Stale window should resolve to 0, while active window is still counted.
        XCTAssertEqual(usage.fiveHourUsage.used, 3_000_000, accuracy: 1)
        XCTAssertNotNil(usage.fiveHourUsage.resetTime)
        XCTAssertEqual(
            usage.fiveHourUsage.resetTime!.timeIntervalSince1970,
            Double(activeReset),
            accuracy: 1
        )
    }

    func testSingleLimitIDNotAffectedByMerge() async throws {
        let dateDir = tempDir.appendingPathComponent("2026/02/15")
        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)

        let now = ISO8601DateFormatter().string(from: Date())
        let weeklyReset = Int(Date().addingTimeInterval(7 * 24 * 3600).timeIntervalSince1970)

        let content = """
        {"timestamp":"\(now)","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":10.0,"window_minutes":10080,"resets_at":\(weeklyReset)}}}}
        """
        let file = dateDir.appendingPathComponent("rollout-test.jsonl")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let provider = CodexUsageProvider(
            sessionsDir: tempDir,
            weeklyTokenLimit: 100_000_000,
            defaults: testDefaults,
            authFileURL: noAuthURL
        )
        let usage = try await provider.fetchUsage()

        // Single limit_id: 10% of 100M = 10,000,000
        XCTAssertEqual(usage.fiveHourUsage.used, 10_000_000, accuracy: 1)
        XCTAssertNil(usage.weeklyUsage)
    }

    // MARK: - Edge Cases

    func testHandlesMissingDirectory() async {
        let provider = CodexUsageProvider(
            sessionsDir: URL(fileURLWithPath: "/nonexistent/path"),
            defaults: testDefaults,
            authFileURL: noAuthURL
        )
        let isConfigured = await provider.isConfigured()
        XCTAssertFalse(isConfigured)
    }

    func testHandlesEmptyDirectory() async throws {
        let provider = CodexUsageProvider(sessionsDir: tempDir, defaults: testDefaults, authFileURL: noAuthURL)
        let usage = try await provider.fetchUsage()

        XCTAssertEqual(usage.fiveHourUsage.used, 0)
        XCTAssertNil(usage.weeklyUsage)
        XCTAssertTrue(usage.isAvailable)
    }

    // MARK: - Idle Session Caching

    func testPrefersCachedUsageWhenWindowBecomesStale() async throws {
        let dateDir = tempDir.appendingPathComponent("2026/02/14")
        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)

        let now = ISO8601DateFormatter().string(from: Date())
        let weeklyReset = Int(Date().addingTimeInterval(7 * 24 * 3600).timeIntervalSince1970)

        // First fetch: active session with 10% usage
        let activeContent = """
        {"timestamp":"\(now)","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":10.0,"window_minutes":10080,"resets_at":\(weeklyReset)}}}}
        """
        let file = dateDir.appendingPathComponent("rollout-test.jsonl")
        try activeContent.write(to: file, atomically: true, encoding: .utf8)

        let provider = CodexUsageProvider(
            sessionsDir: tempDir,
            weeklyTokenLimit: 100_000_000,
            defaults: testDefaults,
            authFileURL: noAuthURL
        )
        let firstUsage = try await provider.fetchUsage()
        XCTAssertEqual(firstUsage.fiveHourUsage.used, 10_000_000, accuracy: 1)

        // Second fetch: rewrite with stale resets_at but same future reset (simulates idle)
        // The window rolled over, resolveWindow returns 0, but cache should preserve value
        let staleReset = Int(Date().addingTimeInterval(-60).timeIntervalSince1970)
        let staleContent = """
        {"timestamp":"\(now)","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":10.0,"window_minutes":10080,"resets_at":\(staleReset)}}}}
        """
        try staleContent.write(to: file, atomically: true, encoding: .utf8)

        let secondUsage = try await provider.fetchUsage()

        // Cache should preserve the non-zero weekly value (reset time still in the future)
        XCTAssertEqual(secondUsage.fiveHourUsage.used, 10_000_000, accuracy: 1)
        XCTAssertNotNil(secondUsage.fiveHourUsage.resetTime)
    }

    func testCacheExpiredWhenResetTimePasses() async throws {
        // Pre-seed cache with usage that has an already-expired reset time
        let pastReset = Date().addingTimeInterval(-60)
        testDefaults.set(Double(50_000_000), forKey: "codexUsageCache.weekly.used")
        testDefaults.set(Double(100_000_000), forKey: "codexUsageCache.weekly.total")
        testDefaults.set(pastReset.timeIntervalSince1970, forKey: "codexUsageCache.weekly.resetTime")

        let provider = CodexUsageProvider(
            sessionsDir: tempDir,
            weeklyTokenLimit: 100_000_000,
            defaults: testDefaults,
            authFileURL: noAuthURL
        )
        let usage = try await provider.fetchUsage()

        // Cache expired → should return 0, not cached value
        XCTAssertEqual(usage.fiveHourUsage.used, 0)
    }

    func testResetTimeFromRateLimits() async throws {
        let dateDir = tempDir.appendingPathComponent("2026/02/14")
        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)

        let now = ISO8601DateFormatter().string(from: Date())
        let weeklyReset = Int(Date().addingTimeInterval(7 * 24 * 3600).timeIntervalSince1970)

        let content = """
        {"timestamp":"\(now)","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":1.0,"window_minutes":10080,"resets_at":\(weeklyReset)}}}}
        """
        let file = dateDir.appendingPathComponent("rollout-test.jsonl")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let provider = CodexUsageProvider(sessionsDir: tempDir, defaults: testDefaults, authFileURL: noAuthURL)
        let usage = try await provider.fetchUsage()

        XCTAssertNotNil(usage.fiveHourUsage.resetTime)
        XCTAssertNil(usage.weeklyUsage)
    }

    // MARK: - ChatGPT Usage API

    /// Writes a fake `~/.codex/auth.json` into the temp dir.
    private func writeAuthFile(accessToken: String = "test-access-token", accountID: String = "acct-1") throws {
        let auth = """
        {"auth_mode":"chatgpt","tokens":{"access_token":"\(accessToken)","account_id":"\(accountID)"}}
        """
        try auth.write(to: tempDir.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
    }

    func testFetchUsageFromAPI() async throws {
        try writeAuthFile()
        CodexMockURLProtocol.reset()
        let json = """
        {"user_id":"user-1","account_id":"acct-1","email":"a@b.c","plan_type":"prolite",
         "rate_limit":{"allowed":true,"limit_reached":false,
           "primary_window":{"used_percent":96.0,"limit_window_seconds":604800,
                             "reset_after_seconds":261623,"reset_at":1787196781},
           "secondary_window":null},
         "additional_rate_limits":[],
         "credits":{"has_credits":false,"balance":"0"},
         "spend_control":{"reached":false},
         "rate_limit_reached_type":{"type":"none"},
         "rate_limit_reset_credits":{"available_count":0}}
        """
        CodexMockURLProtocol.stubResponse(data: Data(json.utf8), statusCode: 200)

        let provider = CodexUsageProvider(
            sessionsDir: tempDir,
            weeklyTokenLimit: 100_000_000,
            defaults: testDefaults,
            apiClient: APIClient(session: CodexMockURLProtocol.session()),
            authFileURL: tempDir.appendingPathComponent("auth.json")
        )

        let usage = try await provider.fetchUsage()

        XCTAssertEqual(usage.service, .codex)
        XCTAssertEqual(usage.planName, "prolite")
        XCTAssertNil(usage.weeklyUsage)
        // 96% of 100M = 96,000,000
        XCTAssertEqual(usage.fiveHourUsage.used, 96_000_000, accuracy: 1)
        XCTAssertEqual(usage.fiveHourUsage.total, 100_000_000)
        XCTAssertEqual(usage.fiveHourUsage.remainingPercentage, 0.04, accuracy: 0.001)
        XCTAssertEqual(usage.fiveHourUsage.resetTime?.timeIntervalSince1970 ?? 0, 1787196781, accuracy: 1)
        // Uses the weekly cache key
        XCTAssertEqual(testDefaults.double(forKey: "codexUsageCache.weekly.used"), 96_000_000, accuracy: 1)
        XCTAssertEqual(CodexMockURLProtocol.requestCount, 1)
    }

    func testFetchUsageFromAPIAtLimit() async throws {
        try writeAuthFile()
        CodexMockURLProtocol.reset()
        let json = """
        {"plan_type":"prolite",
         "rate_limit":{"allowed":false,"limit_reached":true,
           "primary_window":{"used_percent":100.0,"limit_window_seconds":604800,
                             "reset_after_seconds":261623,"reset_at":1787196781},
           "secondary_window":null},
         "rate_limit_reached_type":{"type":"rate_limit_reached"},
         "rate_limit_reset_credits":{"available_count":0}}
        """
        CodexMockURLProtocol.stubResponse(data: Data(json.utf8), statusCode: 200)

        let provider = CodexUsageProvider(
            sessionsDir: tempDir,
            weeklyTokenLimit: 100_000_000,
            defaults: testDefaults,
            apiClient: APIClient(session: CodexMockURLProtocol.session()),
            authFileURL: tempDir.appendingPathComponent("auth.json")
        )

        let usage = try await provider.fetchUsage()

        XCTAssertEqual(usage.fiveHourUsage.used, 100_000_000, accuracy: 1)
        XCTAssertEqual(usage.fiveHourUsage.remainingPercentage, 0.0, accuracy: 0.001)
        XCTAssertEqual(CodexMockURLProtocol.authorizations, ["Bearer test-access-token"])
        XCTAssertEqual(CodexMockURLProtocol.accountIDs, ["acct-1"])
    }

    func testFallsBackToJSONLWhenAPIFails() async throws {
        try writeAuthFile()
        CodexMockURLProtocol.reset()
        // API returns 500 → provider should fall back to local JSONL
        CodexMockURLProtocol.stubResponse(data: Data("error".utf8), statusCode: 500)

        let dateDir = tempDir.appendingPathComponent("2026/02/14")
        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().string(from: Date())
        let weeklyReset = Int(Date().addingTimeInterval(7 * 24 * 3600).timeIntervalSince1970)
        let content = """
        {"timestamp":"\(now)","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":10.0,"window_minutes":10080,"resets_at":\(weeklyReset)}}}}
        """
        try content.write(
            to: dateDir.appendingPathComponent("rollout-test.jsonl"),
            atomically: true, encoding: .utf8
        )

        let provider = CodexUsageProvider(
            sessionsDir: tempDir,
            weeklyTokenLimit: 100_000_000,
            defaults: testDefaults,
            apiClient: APIClient(session: CodexMockURLProtocol.session()),
            authFileURL: tempDir.appendingPathComponent("auth.json")
        )

        let usage = try await provider.fetchUsage()

        // JSONL fallback: 10% of 100M
        XCTAssertEqual(usage.fiveHourUsage.used, 10_000_000, accuracy: 1)
        XCTAssertNotNil(usage.fiveHourUsage.resetTime)
    }

    func testMissingAuthFileFallsBackToJSONL() async throws {
        CodexMockURLProtocol.reset()

        let dateDir = tempDir.appendingPathComponent("2026/02/14")
        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().string(from: Date())
        let weeklyReset = Int(Date().addingTimeInterval(7 * 24 * 3600).timeIntervalSince1970)
        let content = """
        {"timestamp":"\(now)","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":7.0,"window_minutes":10080,"resets_at":\(weeklyReset)}}}}
        """
        try content.write(
            to: dateDir.appendingPathComponent("rollout-test.jsonl"),
            atomically: true, encoding: .utf8
        )

        // No auth file → no API call, straight to JSONL
        let provider = CodexUsageProvider(
            sessionsDir: tempDir,
            weeklyTokenLimit: 100_000_000,
            defaults: testDefaults,
            apiClient: APIClient(session: CodexMockURLProtocol.session()),
            authFileURL: tempDir.appendingPathComponent("does-not-exist.json")
        )

        let usage = try await provider.fetchUsage()

        XCTAssertEqual(usage.fiveHourUsage.used, 7_000_000, accuracy: 1)
        XCTAssertEqual(CodexMockURLProtocol.requestCount, 0)
    }

    func testIsConfiguredWithAuthFileOnly() async {
        try? writeAuthFile()
        let provider = CodexUsageProvider(
            sessionsDir: tempDir.appendingPathComponent("missing"),
            defaults: testDefaults,
            authFileURL: tempDir.appendingPathComponent("auth.json")
        )
        let configured = await provider.isConfigured()
        XCTAssertTrue(configured)
    }

    func testLoadAuthTokens() throws {
        try writeAuthFile(accessToken: "tok-abc", accountID: "acct-xyz")
        let provider = CodexUsageProvider(
            sessionsDir: tempDir,
            defaults: testDefaults,
            authFileURL: tempDir.appendingPathComponent("auth.json")
        )
        let tokens = provider.loadAuthTokens()
        XCTAssertEqual(tokens?.accessToken, "tok-abc")
        XCTAssertEqual(tokens?.accountId, "acct-xyz")
    }
}

// MARK: - Mock URLProtocol

private final class CodexMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) private static var responseData: Data?
    nonisolated(unsafe) private static var statusCode = 200
    nonisolated(unsafe) private static var lastAuthorization: String?
    nonisolated(unsafe) private static var lastAccountID: String?

    static func reset() {
        requestCount = 0
        responseData = nil
        statusCode = 200
        lastAuthorization = nil
        lastAccountID = nil
    }

    static func stubResponse(data: Data, statusCode: Int) {
        responseData = data
        self.statusCode = statusCode
    }

    static var authorizations: [String] {
        lastAuthorization.map { [$0] } ?? []
    }

    static var accountIDs: [String] {
        lastAccountID.map { [$0] } ?? []
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CodexMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        Self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
        Self.lastAccountID = request.value(forHTTPHeaderField: "ChatGPT-Account-Id")

        if let data = Self.responseData {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: Self.statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

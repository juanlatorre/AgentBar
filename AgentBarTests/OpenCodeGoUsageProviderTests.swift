import XCTest
@testable import AgentBar

final class OpenCodeGoUsageProviderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        OpenCodeGoMockURLProtocol.reset()
        OpenCodeGoUsageProvider.updateCache(OpenCodeGoUsageProviderTests.staleCachedData(), now: .distantPast)
    }

    override func tearDown() {
        OpenCodeGoMockURLProtocol.reset()
        super.tearDown()
    }

    func testFetchUsageParsesRollingWeeklyMonthlyPercentages() async throws {
        let json = """
        {"useBalance":false,
         "rollingUsage":{"status":"ok","resetInSec":13561,"usagePercent":0},
         "weeklyUsage":{"status":"ok","resetInSec":441666,"usagePercent":69},
         "monthlyUsage":{"status":"ok","resetInSec":2068758,"usagePercent":49}}
        """
        OpenCodeGoMockURLProtocol.stubResponse(data: Data(json.utf8), statusCode: 200)

        let provider = OpenCodeGoUsageProvider(
            apiClient: APIClient(session: OpenCodeGoMockURLProtocol.session()),
            credentialProvider: { "sk-test-key" }
        )

        let usage = try await provider.fetchUsage()

        XCTAssertEqual(usage.service, .opencode)
        XCTAssertEqual(usage.planName, "Go")
        XCTAssertEqual(usage.fiveHourUsage.unit, .percent)
        XCTAssertEqual(usage.fiveHourUsage.used, 0, accuracy: 0.001)
        XCTAssertEqual(usage.fiveHourUsage.total, 100)
        XCTAssertEqual(usage.fiveHourUsage.remainingPercentage, 1.0, accuracy: 0.001)
        XCTAssertEqual(
            usage.fiveHourUsage.resetTime?.timeIntervalSinceNow ?? 0,
            13561,
            accuracy: 5
        )
        XCTAssertEqual(usage.weeklyUsage?.used ?? 0, 69, accuracy: 0.001)
        XCTAssertEqual(usage.weeklyUsage?.remainingPercentage ?? 0, 0.31, accuracy: 0.001)
        XCTAssertEqual(
            usage.weeklyUsage?.resetTime?.timeIntervalSinceNow ?? 0,
            441666,
            accuracy: 5
        )
        XCTAssertEqual(usage.monthlyUsage?.used ?? 0, 49, accuracy: 0.001)
        XCTAssertEqual(usage.monthlyUsage?.remainingPercentage ?? 0, 0.51, accuracy: 0.001)
        XCTAssertEqual(
            usage.monthlyUsage?.resetTime?.timeIntervalSinceNow ?? 0,
            2068758,
            accuracy: 5
        )
        XCTAssertEqual(OpenCodeGoMockURLProtocol.authorizations, ["Bearer sk-test-key"])
    }

    func testFetchUsageParsesCurrentUsageGroupShape() async throws {
        // Current backend shape: usage.{rolling,weekly,monthly} with percent + ISO resetsAt.
        let json = """
        {"usage":{"rolling":{"status":"ok","percent":0,"resetsAt":"2026-08-12T01:04:55.135Z"},
                   "weekly":{"status":"ok","percent":69,"resetsAt":"2026-08-17T00:00:00.135Z"},
                   "monthly":{"status":"ok","percent":49,"resetsAt":"2026-09-04T19:58:12.135Z"}}}
        """
        OpenCodeGoMockURLProtocol.stubResponse(data: Data(json.utf8), statusCode: 200)

        let provider = OpenCodeGoUsageProvider(
            apiClient: APIClient(session: OpenCodeGoMockURLProtocol.session()),
            credentialProvider: { "sk-test-key" }
        )

        let usage = try await provider.fetchUsage()

        XCTAssertEqual(usage.fiveHourUsage.used, 0, accuracy: 0.001)
        XCTAssertEqual(usage.weeklyUsage?.used ?? 0, 69, accuracy: 0.001)
        XCTAssertEqual(usage.weeklyUsage?.remainingPercentage ?? 0, 0.31, accuracy: 0.001)
        XCTAssertEqual(usage.monthlyUsage?.used ?? 0, 49, accuracy: 0.001)
        XCTAssertNotNil(usage.fiveHourUsage.resetTime)
        XCTAssertNotNil(usage.weeklyUsage?.resetTime)
        XCTAssertNotNil(usage.monthlyUsage?.resetTime)
    }

    func testFetchUsageDefaultsToZeroWhenWindowsMissing() async throws {
        let json = #"{"useBalance":false}"#
        OpenCodeGoMockURLProtocol.stubResponse(data: Data(json.utf8), statusCode: 200)

        let provider = OpenCodeGoUsageProvider(
            apiClient: APIClient(session: OpenCodeGoMockURLProtocol.session()),
            credentialProvider: { "sk-test-key" }
        )

        let usage = try await provider.fetchUsage()

        XCTAssertEqual(usage.fiveHourUsage.used, 0)
        XCTAssertEqual(usage.weeklyUsage?.used, 0)
        XCTAssertEqual(usage.monthlyUsage?.used, 0)
        XCTAssertNil(usage.fiveHourUsage.resetTime)
    }

    func testFetchUsageThrowsWhenAPIKeyMissing() async {
        let provider = OpenCodeGoUsageProvider(
            apiClient: APIClient(session: OpenCodeGoMockURLProtocol.session()),
            credentialProvider: { nil }
        )

        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected fetchUsage to throw when the API key is missing.")
        } catch {
            XCTAssertEqual(error as? OpenCodeGoUsageError, .missingCredential)
        }
        XCTAssertEqual(OpenCodeGoMockURLProtocol.requestCount, 0)
    }

    func testFetchUsageUsesCacheWithinTTL() async throws {
        let fresh = UsageData(
            service: .opencode,
            fiveHourUsage: UsageMetric(used: 10, total: 100, unit: .percent, resetTime: nil),
            weeklyUsage: nil,
            monthlyUsage: nil,
            lastUpdated: Date(),
            isAvailable: true,
            planName: "Go"
        )
        OpenCodeGoUsageProvider.updateCache(fresh, now: Date())

        let provider = OpenCodeGoUsageProvider(
            apiClient: APIClient(session: OpenCodeGoMockURLProtocol.session()),
            credentialProvider: { "sk-test-key" }
        )

        let usage = try await provider.fetchUsage()

        XCTAssertEqual(usage.fiveHourUsage.used, 10)
        XCTAssertEqual(OpenCodeGoMockURLProtocol.requestCount, 0, "Expected no network call when cache is fresh.")
    }

    func testIsConfiguredReflectsCredentialProvider() async {
        let configured = OpenCodeGoUsageProvider(credentialProvider: { "sk-test-key" })
        let notConfigured = OpenCodeGoUsageProvider(credentialProvider: { nil })

        let a = await configured.isConfigured()
        let b = await notConfigured.isConfigured()

        XCTAssertTrue(a)
        XCTAssertFalse(b)
    }

    func testLoadAPIKeyFromAuthFile() throws {
        let authFile = """
        {"zai-coding-plan":{"type":"api","key":"other-key"},
         "opencode-go":{"type":"api","key":"sk-opencode-go-key"}}
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-\(UUID().uuidString).json")
        try Data(authFile.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(OpenCodeGoUsageProvider.loadAPIKeyFromAuthFile(authFileURL: url), "sk-opencode-go-key")
    }

    func testLoadAPIKeyFromAuthFileReturnsNilWhenKeyMissing() throws {
        let authFile = #"{"other":{"type":"api","key":"x"}}"#
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-\(UUID().uuidString).json")
        try Data(authFile.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(OpenCodeGoUsageProvider.loadAPIKeyFromAuthFile(authFileURL: url))
    }

    /// Ensures a previous cached response never leaks across tests.
    private static func staleCachedData() -> UsageData {
        UsageData(
            service: .opencode,
            fiveHourUsage: UsageMetric(used: 99, total: 100, unit: .percent, resetTime: .distantPast),
            weeklyUsage: nil,
            monthlyUsage: nil,
            lastUpdated: .distantPast,
            isAvailable: true
        )
    }
}

// MARK: - Mock URL Protocol

private final class OpenCodeGoMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) private static var responseData: Data?
    nonisolated(unsafe) private static var statusCode = 200
    nonisolated(unsafe) private static var lastAuthorization: String?

    static func reset() {
        requestCount = 0
        responseData = nil
        statusCode = 200
        lastAuthorization = nil
    }

    static func stubResponse(data: Data, statusCode: Int) {
        responseData = data
        self.statusCode = statusCode
    }

    static var authorizations: [String] {
        lastAuthorization.map { [$0] } ?? []
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpenCodeGoMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        Self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")

        if let data = Self.responseData {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: Self.statusCode,
                httpVersion: nil,
                headerFields: nil
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

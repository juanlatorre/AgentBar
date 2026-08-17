import XCTest
@testable import AgentBar

final class CommandCodeUsageProviderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CommandCodeMockURLProtocol.reset()
        CommandCodeUsageProvider.updateCache(CommandCodeUsageProviderTests.staleCachedData(), now: .distantPast)
    }

    override func tearDown() {
        CommandCodeMockURLProtocol.reset()
        super.tearDown()
    }

    /// Returns a cached UsageData far in the past so it's never "fresh".
    private static func staleCachedData() -> UsageData {
        UsageData(
            service: .cmd,
            fiveHourUsage: UsageMetric(used: 0, total: 0, unit: .dollars, resetTime: nil),
            weeklyUsage: nil,
            lastUpdated: .distantPast,
            isAvailable: true,
            planName: nil
        )
    }

    private func makeProvider(authFile: URL? = nil) -> CommandCodeUsageProvider {
        CommandCodeUsageProvider(
            apiClient: APIClient(session: CommandCodeMockURLProtocol.session()),
            authFileURL: authFile ?? tempAuthURL()
        )
    }

    private func tempAuthURL() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("auth.json")
        try? """
        {"apiKey":"user_test-key","userId":"u1","userName":"juan"}
        """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Parsing

    func testFetchUsageParsesFiveHourAndWeeklyWindows() async throws {
        let json = """
        {"credits":{"monthlyCredits":69.33,"purchasedCredits":0,"freeCredits":0},
         "windowLimits":{"limited":true,"exceeded":null,
           "fiveHour":{"used":0.0347760235,"cap":14,"exceeded":false,"resetAt":1786989474547},
           "weekly":{"used":0.6660109257,"cap":35,"exceeded":false,"resetAt":1787536922055}}}
        """
        CommandCodeMockURLProtocol.stubResponse(data: Data(json.utf8), statusCode: 200)

        let provider = makeProvider()
        let usage = try await provider.fetchUsage()

        XCTAssertEqual(usage.service, .cmd)
        XCTAssertTrue(usage.isAvailable)
        XCTAssertEqual(usage.fiveHourUsage.unit, .dollars)
        XCTAssertEqual(usage.fiveHourUsage.used, 0.0347760235, accuracy: 0.0001)
        XCTAssertEqual(usage.fiveHourUsage.total, 14, accuracy: 0.0001)
        // resetAt is epoch ms → divide by 1000
        XCTAssertEqual(
            usage.fiveHourUsage.resetTime?.timeIntervalSince1970 ?? 0,
            1786989474.547,
            accuracy: 0.1
        )
        XCTAssertEqual(usage.weeklyUsage?.used ?? 0, 0.6660109257, accuracy: 0.0001)
        XCTAssertEqual(usage.weeklyUsage?.total ?? 0, 35, accuracy: 0.0001)
        XCTAssertEqual(
            usage.weeklyUsage?.resetTime?.timeIntervalSince1970 ?? 0,
            1787536922.055,
            accuracy: 0.1
        )
        XCTAssertEqual(CommandCodeMockURLProtocol.authorizations, ["Bearer user_test-key"])
        XCTAssertEqual(CommandCodeMockURLProtocol.userAgents, ["command-code-cli/1.26.0"])
    }

    func testFetchUsageWithoutWindowsYieldsZero() async throws {
        CommandCodeMockURLProtocol.stubResponse(data: Data("{}".utf8), statusCode: 200)

        let provider = makeProvider()
        let usage = try await provider.fetchUsage()

        XCTAssertEqual(usage.fiveHourUsage.used, 0)
        XCTAssertEqual(usage.fiveHourUsage.total, 0)
        XCTAssertNil(usage.fiveHourUsage.resetTime)
        XCTAssertNil(usage.weeklyUsage?.resetTime)
    }

    func testPlanNameFromSubscription() async throws {
        let credits = """
        {"credits":{"monthlyCredits":69.33},
         "windowLimits":{"fiveHour":{"used":0.03,"cap":14,"resetAt":1786989474547},
                         "weekly":{"used":0.6,"cap":35,"resetAt":1787536922055}}}
        """
        let subscription = """
        {"success":true,"data":{"planId":"individual-goat","status":"active"}}
        """
        CommandCodeMockURLProtocol.stubResponses([
            Data(credits.utf8),
            Data(subscription.utf8)
        ])

        let provider = makeProvider()
        let usage = try await provider.fetchUsage()

        XCTAssertEqual(usage.planName, "Goat")
    }

    func testMissingAuthFileThrows() async {
        let provider = CommandCodeUsageProvider(
            apiClient: APIClient(session: CommandCodeMockURLProtocol.session()),
            authFileURL: URL(fileURLWithPath: "/nonexistent/auth.json")
        )
        let isConfigured = await provider.isConfigured()
        XCTAssertFalse(isConfigured)
        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected missingCredential error")
        } catch {
            XCTAssertEqual(error as? CommandCodeUsageError, .missingCredential)
        }
    }

    func testIsConfiguredWithAuthFile() async {
        let provider = makeProvider()
        let configured = await provider.isConfigured()
        XCTAssertTrue(configured)
    }

    func testDisplayPlanName() {
        XCTAssertEqual(CommandCodeUsageProvider.displayPlanName("individual-goat"), "Goat")
        XCTAssertEqual(CommandCodeUsageProvider.displayPlanName("individual-max"), "Max")
        XCTAssertEqual(CommandCodeUsageProvider.displayPlanName("individual-go"), "Go")
        XCTAssertEqual(CommandCodeUsageProvider.displayPlanName("team-enterprise"), "Enterprise")
    }
}

// MARK: - Mock URLProtocol

private final class CommandCodeMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) private static var responseData: [Data] = []
    nonisolated(unsafe) private static var statusCode = 200
    nonisolated(unsafe) private static var lastAuthorization: String?
    nonisolated(unsafe) private static var lastUserAgent: String?

    static func reset() {
        requestCount = 0
        responseData = []
        statusCode = 200
        lastAuthorization = nil
        lastUserAgent = nil
    }

    static func stubResponse(data: Data, statusCode: Int) {
        responseData = [data]
        self.statusCode = statusCode
    }

    /// Stub sequential responses for multiple requests (e.g. credits then subscription).
    static func stubResponses(_ datas: [Data], statusCode: Int = 200) {
        responseData = datas
        self.statusCode = statusCode
    }

    static var authorizations: [String] {
        lastAuthorization.map { [$0] } ?? []
    }

    static var userAgents: [String] {
        lastUserAgent.map { [$0] } ?? []
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CommandCodeMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        Self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
        Self.lastUserAgent = request.value(forHTTPHeaderField: "User-Agent")

        let index = min(Self.requestCount - 1, Self.responseData.count - 1)
        if Self.responseData.indices.contains(index) {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: Self.statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.responseData[index])
            client?.urlProtocolDidFinishLoading(self)
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        }
    }

    override func stopLoading() {}
}

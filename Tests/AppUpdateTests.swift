import Foundation
import Testing
@testable import SerialDebugToolCore

private func releaseFixture(_ tag: String = "v1.2.3", host: String = "github.com", draft: Bool = false, prerelease: Bool = false) -> AppRelease {
    AppRelease(tagName: tag, htmlURL: URL(string: "https://\(host)/txgde-space/serial_debug_tool/releases/tag/\(tag)")!, body: "Release notes", draft: draft, prerelease: prerelease)
}

private let updateFeedFixture = """
<feed xmlns="http://www.w3.org/2005/Atom">
<entry><link rel="alternate" href="https://github.com/txgde-space/serial_debug_tool/releases/tag/v9.0.0"/>
<content type="html">Wrong release notes</content></entry>
<entry><link rel="alternate" href="https://github.com/txgde-space/serial_debug_tool/releases/tag/v1.2.3"/>
<content type="html">&lt;h2&gt;更新内容&lt;/h2&gt;&lt;ul&gt;&lt;li&gt;新增发送 &amp;amp; 接收 &amp;lt;value&amp;gt; &amp;#x1F680;&lt;/li&gt;&lt;/ul&gt;</content></entry>
</feed>
"""

private final class UpdateStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let code = Int(request.value(forHTTPHeaderField: "X-Stub-Status") ?? "200")!
        let fallback = request.httpMethod == "HEAD"
        let feed = request.url?.lastPathComponent == "releases.atom"
        let missingNotes = feed && request.value(forHTTPHeaderField: "X-Stub-No-Notes") == "true"
        let responseURL = fallback ? releaseFixture().htmlURL : request.url!
        let response = HTTPURLResponse(url: responseURL, statusCode: missingNotes ? 503 : (fallback || feed ? 200 : code), httpVersion: nil,
                                       headerFields: ["X-RateLimit-Remaining": "0"])!
        let data = feed ? Data(updateFeedFixture.utf8) : (request.value(forHTTPHeaderField: "X-Stub-Invalid") == "true" ? Data("invalid".utf8) : Data(#"{"tag_name":"v1.2.3","html_url":"https://github.com/txgde-space/serial_debug_tool/releases/tag/v1.2.3","body":"Notes","draft":false,"prerelease":false}"#.utf8))
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Application updates")
struct AppUpdateTests {
    @Test func releaseNotesKeepTheMatchingVersionsFeaturesAndDecodeMarkup() throws {
        let notes = try #require(ReleaseNotes.fromFeed(Data(updateFeedFixture.utf8), releaseURL: releaseFixture().htmlURL))
        #expect(notes.contains("更新内容"))
        #expect(notes.contains("• 新增发送 & 接收 <value> 🚀"))
        #expect(!notes.contains("Wrong release notes"))
        #expect(!notes.contains("<li>"))
        #expect(ReleaseNotes.fromFeed(Data(updateFeedFixture.utf8), releaseURL: releaseFixture("v1.2.4").htmlURL) == nil)
        #expect(ReleaseNotes.fromFeed(Data("<feed>".utf8), releaseURL: releaseFixture().htmlURL) == nil)
    }

    @Test func versionsCompareNumericallyAndRejectNonStableTags() throws {
        #expect(try #require(AppVersion("v1.10.0")) > #require(AppVersion("1.9.9")))
        #expect(try #require(AppVersion("2.0.0")) > #require(AppVersion("1.99.99")))
        #expect(AppVersion("v1.2.3") == AppVersion("1.2.3"))
        for invalid in ["", "1.2", "1.2.3-beta.1", "1.-2.3", "1.2.3.4", "1.2.x", "１.2.3"] {
            #expect(AppVersion(invalid) == nil)
        }
    }

    @Test func releaseMustBeStableAndBelongToTheOfficialRepository() {
        #expect(releaseFixture().isValidStableRelease)
        #expect(!releaseFixture(draft: true).isValidStableRelease)
        #expect(!releaseFixture(prerelease: true).isValidStableRelease)
        #expect(!releaseFixture("v1.3.0-beta.1").isValidStableRelease)
        #expect(!releaseFixture(host: "github.com.example.com").isValidStableRelease)
        let wrongRepo = AppRelease(tagName: "v1.2.3", htmlURL: URL(string: "https://github.com/other/repo/releases/tag/v1.2.3")!, body: nil, draft: false, prerelease: false)
        #expect(!wrongRepo.isValidStableRelease)
    }

    @Test func serviceHandlesSuccessInvalidDataAndHTTPFailures() async throws {
        func session(status: Int = 200, invalid: Bool = false, noNotes: Bool = false) -> URLSession {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [UpdateStub.self]
            config.httpAdditionalHeaders = ["X-Stub-Status": String(status), "X-Stub-Invalid": String(invalid), "X-Stub-No-Notes": String(noNotes)]
            return URLSession(configuration: config)
        }
        let success = session()
        defer { success.invalidateAndCancel() }
        #expect(try await ReleaseService.latest(using: success).tagName == "v1.2.3")
        for code in [403, 429] {
            let connection = session(status: code)
            defer { connection.invalidateAndCancel() }
            let fallback = try await ReleaseService.latest(using: connection)
            #expect(fallback.tagName == "v1.2.3")
            #expect(fallback.body?.contains("新增发送") == true)
        }
        let missingNotes = session(status: 403, noNotes: true)
        defer { missingNotes.invalidateAndCancel() }
        let withoutNotes = try await ReleaseService.latest(using: missingNotes)
        #expect(withoutNotes.tagName == "v1.2.3")
        #expect(withoutNotes.body == nil, "Unavailable notes must not hide a valid new version")
        for code in [404, 503] {
            let connection = session(status: code)
            defer { connection.invalidateAndCancel() }
            await #expect(throws: UpdateCheckError.httpStatus(code)) {
                try await ReleaseService.latest(using: connection)
            }
        }
        let invalid = session(invalid: true)
        defer { invalid.invalidateAndCancel() }
        await #expect(throws: UpdateCheckError.invalidResponse) {
            try await ReleaseService.latest(using: invalid)
        }
    }

    @MainActor
    @Test func checkerDoesNotOfferDowngradesAndCanRetryAfterFailure() async throws {
        let latest = releaseFixture()
        for installed in ["1.2.3", "1.3.0", "1.10.0"] {
            let checker = AppUpdateChecker(currentVersion: installed, fetch: { latest })
            await checker.check()
            #expect(checker.status == .upToDate)
        }
        let newer = AppUpdateChecker(currentVersion: "1.2.2", fetch: { latest })
        await newer.check()
        #expect(newer.status == .available(latest))
        let counter = UpdateRequestCounter()
        let retry = AppUpdateChecker(currentVersion: "1.2.2", fetch: {
            if await counter.next() == 1 { throw URLError(.notConnectedToInternet) }
            return latest
        })
        await retry.check()
        guard case .failed = retry.status else { Issue.record("Offline check must fail without offering an update"); return }
        await retry.check()
        #expect(retry.status == .available(latest))
    }

    @MainActor
    @Test func automaticChecksAreOptionalThrottledAndDeduplicatedAcrossWindows() async throws {
        let domain = "SerialDebugTool.UpdateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let counter = UpdateRequestCounter()
        let latest = releaseFixture()
        let checker = AppUpdateChecker(currentVersion: "1.2.2", defaults: defaults, fetch: {
            _ = await counter.next()
            try await Task.sleep(for: .milliseconds(20))
            return latest
        })
        defaults.set(false, forKey: AppUpdateChecker.automaticKey)
        #expect(await checker.checkAutomatically() == false)
        #expect(await counter.count == 0)
        defaults.set(true, forKey: AppUpdateChecker.automaticKey)
        let now = Date()
        async let first = checker.checkAutomatically(now: now)
        async let second = checker.checkAutomatically(now: now)
        let outcomes = await [first, second]
        #expect(outcomes.filter { $0 }.count == 1)
        #expect(await counter.count == 1)
        #expect(await checker.checkAutomatically(now: now.addingTimeInterval(86_399)) == false)
        #expect(await checker.checkAutomatically(now: now.addingTimeInterval(86_401)))
        #expect(await counter.count == 2)
        await checker.check()
        #expect(await counter.count == 3, "Manual checks bypass the daily automatic limit")
    }
}

private actor UpdateRequestCounter {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}

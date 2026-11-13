import Foundation
import Observation

/// Numeric stable releases only; compare components rather than version strings.
struct AppVersion: Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

struct AppRelease: Decodable, Sendable, Equatable {
    let tagName: String
    let htmlURL: URL
    let body: String?
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body, draft, prerelease
    }

    var version: AppVersion? { AppVersion(tagName) }

    var isValidStableRelease: Bool {
        !draft && !prerelease && version != nil &&
        htmlURL.scheme == "https" && htmlURL.host == "github.com" &&
        htmlURL.user == nil && htmlURL.password == nil && htmlURL.port == nil &&
        htmlURL.path == "/txgde-space/serial_debug_tool/releases/tag/\(tagName)"
    }
}

enum UpdateCheckError: Error, Equatable {
    case rateLimited
    case invalidResponse
    case invalidVersion
    case httpStatus(Int)
}

enum ReleaseService {
    static let latestURL = URL(string: "https://api.github.com/repos/txgde-space/serial_debug_tool/releases/latest")!
    static let releasesURL = URL(string: "https://github.com/txgde-space/serial_debug_tool/releases")!

    static func latest(using session: URLSession = .shared) async throws -> AppRelease {
        var request = URLRequest(url: latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Serial-Debug-Tool-Update-Check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw UpdateCheckError.invalidResponse }
        guard response.statusCode == 200 else {
            if response.statusCode == 429 ||
                (response.statusCode == 403 && response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0") {
                return try await latestFromReleasePage(using: session)
            }
            throw UpdateCheckError.httpStatus(response.statusCode)
        }
        guard data.count <= 1_000_000,
              let release = try? JSONDecoder().decode(AppRelease.self, from: data),
              release.isValidStableRelease else { throw UpdateCheckError.invalidResponse }
        return release
    }

    /// GitHub redirects this URL to its latest stable release without using the API quota.
    private static func latestFromReleasePage(using session: URLSession) async throws -> AppRelease {
        var request = URLRequest(url: releasesURL.appendingPathComponent("latest"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let url = response.url else { throw UpdateCheckError.rateLimited }
        let release = AppRelease(tagName: url.lastPathComponent, htmlURL: url,
                                 body: nil, draft: false, prerelease: false)
        guard release.isValidStableRelease else { throw UpdateCheckError.invalidResponse }
        return release
    }

}

@MainActor
@Observable
final class AppUpdateChecker {
    static let shared = AppUpdateChecker()
    static let automaticKey = "updates.checkAutomatically"
    private static let lastAttemptKey = "updates.lastAutomaticCheck"

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case failed(String)
    }

    private(set) var status: Status = .idle
    let currentVersion: String
    private let defaults: UserDefaults
    private let fetch: @Sendable () async throws -> AppRelease

    init(currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
         defaults: UserDefaults = .standard,
         fetch: @escaping @Sendable () async throws -> AppRelease = { try await ReleaseService.latest() }) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.fetch = fetch
    }

    var isChecking: Bool { status == .checking }

    /// Shared across windows: at most one automatic request per day, including failures.
    func checkAutomatically(now: Date = Date()) async -> Bool {
        guard defaults.object(forKey: Self.automaticKey) as? Bool ?? true, !isChecking else { return false }
        if let previous = defaults.object(forKey: Self.lastAttemptKey) as? Date,
           now.timeIntervalSince(previous) < 86_400 { return false }
        defaults.set(now, forKey: Self.lastAttemptKey)
        await check()
        if case .available = status { return true }
        return false
    }

    func check() async {
        guard !isChecking else { return }
        status = .checking
        do {
            guard let installed = AppVersion(currentVersion) else { throw UpdateCheckError.invalidVersion }
            let release = try await fetch()
            guard release.isValidStableRelease, let latest = release.version else { throw UpdateCheckError.invalidResponse }
            status = latest > installed ? .available(release) : .upToDate
        } catch {
            switch error {
            case UpdateCheckError.rateLimited: status = .failed(AppText.updateRateLimited)
            case UpdateCheckError.invalidVersion: status = .failed(AppText.updateInvalidVersion)
            case is UpdateCheckError, is DecodingError: status = .failed(AppText.updateInvalidResponse)
            default: status = .failed(error.localizedDescription)
            }
        }
    }
}

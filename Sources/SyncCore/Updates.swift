import Foundation

public struct ReleaseVersion: Comparable, Equatable {
    let components: [Int]
    public let description: String
    public init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        guard value.range(of: "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$", options: .regularExpression) != nil else { return nil }
        let parts = value.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        components = parts; description = value
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.components == rhs.components }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

public struct AppRelease: Codable, Equatable {
    public let tag: String
    public let name: String
    public let notes: String
    public let page: URL
    public var version: ReleaseVersion? { ReleaseVersion(tag) }
    public var isTrusted: Bool {
        guard version != nil else { return false }
        return page.absoluteString == "https://github.com/Chiiz0/Sync-Claude/releases/tag/\(tag)"
    }
    public func isNewer(than current: String) -> Bool {
        guard isTrusted, let version, let installed = ReleaseVersion(current) else { return false }
        return version > installed
    }
}

public enum UpdateChecker {
    public static let endpoint = URL(string: "https://api.github.com/repos/Chiiz0/Sync-Claude/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/Chiiz0/Sync-Claude/releases")!

    public static func shouldCheck(now: Date, lastAttempt: Date?, lastSuccess: Date?) -> Bool {
        // A failed request backs off for an hour; successful checks are daily, across restarts.
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < 3600 && lastAttempt <= now { return false }
        if let lastSuccess, now.timeIntervalSince(lastSuccess) < 86400 && lastSuccess <= now { return false }
        return true
    }

    public static func latest(session: URLSession? = nil) async throws -> AppRelease? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let client = session ?? URLSession(configuration: configuration)
        defer { if session == nil { client.finishTasksAndInvalidate() } }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Sync-Claude-Update-Check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await client.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncError("更新服务返回了无法识别的响应。") }
        return try parse(data: data, statusCode: http.statusCode)
    }

    static func parse(data: Data, statusCode: Int) throws -> AppRelease? {
        if statusCode == 404 { return nil }
        if statusCode == 403 || statusCode == 429 { throw SyncError("GitHub 暂时限制了检查频率，请稍后重试。") }
        guard statusCode == 200 else { throw SyncError("检查更新失败（HTTP \(statusCode)）。请稍后重试。") }
        guard data.count <= 2 * 1024 * 1024 else { throw SyncError("版本信息过大，已停止检查。") }
        struct Response: Decodable {
            let tag_name: String
            let name: String?
            let body: String?
            let html_url: URL
            let draft: Bool
            let prerelease: Bool
        }
        let value = try JSONDecoder().decode(Response.self, from: data)
        guard !value.draft, !value.prerelease else { return nil }
        let release = AppRelease(tag: value.tag_name, name: value.name ?? value.tag_name, notes: value.body ?? "", page: value.html_url)
        guard release.isTrusted else { throw SyncError("版本号或下载页面无法验证，已停止检查。") }
        return release
    }
}

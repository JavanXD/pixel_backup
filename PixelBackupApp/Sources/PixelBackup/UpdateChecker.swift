import Foundation
import SwiftUI

/// Checks GitHub releases for a newer `tag_name` and shows a dismissible banner.
/// Requirement: no telemetry — only fetch + version string comparison.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct BannerState: Equatable {
        let currentVersion: String
        let latestVersion: String
        let latestTag: String
        let releaseURL: URL
    }

    @Published private(set) var banner: BannerState? = nil

    private let dismissedTagKey = "updateBanner.dismissedTag"
    private var checkTask: Task<Void, Never>?

    // For personal tools: keep endpoint fixed; avoid config files / user input.
    private let releasesLatestURL = URL(string: "https://api.github.com/repos/JavanXD/pixel_backup/releases/latest")!

    func start() {
        guard checkTask == nil else { return } // ensure we only check once per app run

        checkTask = Task { [weak self] in
            await self?.checkLatestReleaseAndUpdateBanner()
        }
    }

    func dismissCurrentBanner() {
        guard let banner else { return }
        UserDefaults.standard.set(banner.latestTag, forKey: dismissedTagKey)
        self.banner = nil
    }

    // MARK: - Check flow

    private struct GitHubLatestReleaseResponse: Decodable {
        let tag_name: String
        let html_url: String?
    }

    private func checkLatestReleaseAndUpdateBanner() async {
        let current = Bundle.main.shortVersionString ?? ""
        guard !current.isEmpty else { return }

        // If user already dismissed this same tag, do nothing.
        let dismissedTag = UserDefaults.standard.string(forKey: dismissedTagKey)

        var request = URLRequest(url: releasesLatestURL)
        request.httpMethod = "GET"
        request.setValue("PixelBackup", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return
            }

            let decoded = try JSONDecoder().decode(GitHubLatestReleaseResponse.self, from: data)
            let latestTag = decoded.tag_name
            if latestTag == dismissedTag { return }

            guard
                let currentVer = SemVer.parse(current),
                let latestVer = SemVer.parse(latestTag)
            else {
                return
            }

            guard latestVer > currentVer else { return }

            // Prefer `html_url`, but fall back to GitHub releases search by tag.
            let url = decoded.html_url.flatMap(URL.init(string:))
                ?? URL(string: "https://github.com/JavanXD/pixel_backup/releases/tag/\(latestTag)")!

            banner = BannerState(
                currentVersion: current,
                latestVersion: latestTagStripped(latestTag),
                latestTag: latestTag,
                releaseURL: url
            )
        } catch {
            // Silent failure: this is a best-effort convenience feature.
            return
        }
    }

    private func latestTagStripped(_ tag: String) -> String {
        // Display without leading `v` (common GitHub convention).
        tag.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("v")
            ? String(tag.dropFirst())
            : tag
    }
}

private extension Bundle {
    var shortVersionString: String? {
        infoDictionary?["CFBundleShortVersionString"] as? String
    }
}

/// Minimal SemVer implementation sufficient for typical tags like `v1.2.3` or `v1.2.3-beta.1`.
private struct SemVer: Comparable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [Identifier]?

    enum Identifier: Comparable {
        case numeric(Int)
        case alpha(String)

        static func < (lhs: Identifier, rhs: Identifier) -> Bool {
            switch (lhs, rhs) {
            case let (.numeric(a), .numeric(b)):
                return a < b
            case let (.alpha(a), .alpha(b)):
                return a < b
            case (.numeric, .alpha):
                // SemVer rule: numeric identifiers always have lower precedence than non-numeric.
                return true
            case (.alpha, .numeric):
                return false
            }
        }
    }

    static func parse(_ raw: String) -> SemVer? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("v") ? String(raw.dropFirst()) : raw

        // Strip build metadata (e.g. `+build.123`)
        let withoutBuild = cleaned.split(separator: "+", maxSplits: 1).map(String.init)[0]

        let parts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
        let corePart = String(parts[0])
        let core = corePart.split(separator: ".").map(String.init)
        guard let major = core[safe: 0].flatMap(Int.init),
              let minor = core[safe: 1].flatMap(Int.init),
              let patch = core[safe: 2].flatMap(Int.init) else {
            // Require at least `x.y.z` style for predictable comparisons.
            return nil
        }

        let prerelease: [Identifier]? = parts.count > 1 ? {
            let pr = String(parts[1])
            let ids = pr.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
            return ids.map { id in
                if let n = Int(id) {
                    if String(n) == id { return .numeric(n) }
                }
                return .alpha(id)
            }
        }() : nil

        return SemVer(major: major, minor: minor, patch: patch, prerelease: prerelease)
    }

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // Handle prerelease precedence.
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (nil, _?):
            // A stable release has higher precedence than a pre-release.
            return false
        case (_?, nil):
            return true
        case let (lpr?, rpr?):
            // Compare identifier by identifier.
            for i in 0..<min(lpr.count, rpr.count) {
                if lpr[i] != rpr[i] { return lpr[i] < rpr[i] }
            }
            // If all equal up to shorter length, longer set has higher precedence.
            return lpr.count < rpr.count
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0 && index < count else { return nil }
        return self[index]
    }
}


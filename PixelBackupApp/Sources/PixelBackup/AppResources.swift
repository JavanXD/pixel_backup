import Foundation

/// Resource lookup that works for both the packaged `.app` and `swift run`.
///
/// Never uses `Bundle.module` — that accessor `fatalError`s when the SPM
/// resource bundle is missing from the app (which used to crash on launch).
enum AppResources {
    private static let spmBundleName = "PixelBackup_PixelBackup.bundle"

    /// Prefer the SPM resource bundle when present; otherwise `Bundle.main`
    /// (flat `Contents/Resources` layout from `build.sh`).
    static let bundle: Bundle = {
        for url in spmBundleCandidates() {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return .main
    }()

    static func url(forResource name: String, withExtension ext: String?) -> URL? {
        if let url = bundle.url(forResource: name, withExtension: ext) {
            return url
        }
        // `.copy("Resources")` nests files under a Resources/ subdirectory in some layouts.
        if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Resources") {
            return url
        }
        if bundle !== Bundle.main {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        return nil
    }

    private static func spmBundleCandidates() -> [URL] {
        var urls: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent(spmBundleName))
        }
        let main = Bundle.main.bundleURL
        // PixelBackup.app → Contents/Resources/…
        urls.append(
            main
                .appendingPathComponent("Contents")
                .appendingPathComponent("Resources")
                .appendingPathComponent(spmBundleName)
        )
        // Executable next to the SPM bundle (`swift run` / `.build/.../debug`)
        urls.append(main.deletingLastPathComponent().appendingPathComponent(spmBundleName))
        // Contents/MacOS/PixelBackup → Contents/Resources/…
        urls.append(
            main
                .deletingLastPathComponent()
                .appendingPathComponent("Resources")
                .appendingPathComponent(spmBundleName)
        )
        urls.append(main.appendingPathComponent(spmBundleName))
        return urls
    }
}

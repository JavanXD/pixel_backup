// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PixelBackup",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PixelBackup",
            path: "Sources/PixelBackup",
            exclude: [
                "Info.plist"    // handled by Xcode / build.sh, not SPM resource pipeline
            ],
            resources: [
                .copy("Resources")
            ]
        )
    ]
)

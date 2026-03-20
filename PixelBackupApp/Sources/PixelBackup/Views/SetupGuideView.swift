import SwiftUI

struct SetupGuideView: View {
    @EnvironmentObject var deviceManager: DeviceManager
    @State private var isInstalling = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("adb Not Found")
                .font(.title.bold())

            Text("`adb` (Android Debug Bridge) is required to communicate with your Pixel phone.\nInstall it with Homebrew to continue.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)

            VStack(alignment: .leading, spacing: 12) {
                step(number: 1, title: "Install Homebrew (if missing)",
                     code: "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"")
                step(number: 2, title: "Install adb",
                     code: "brew install android-platform-tools")
                step(number: 3, title: "Verify",
                     code: "adb version")
            }
            .padding(20)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: 480)

            HStack(spacing: 12) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install android-platform-tools", forType: .string)
                } label: {
                    Label("Copy install command", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Button {
                    Task {
                        await deviceManager.resolveAdb()
                    }
                } label: {
                    Label("Retry Detection", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
    }

    private func step(number: Int, title: String, code: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.blue, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.bold())
                Text(code)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

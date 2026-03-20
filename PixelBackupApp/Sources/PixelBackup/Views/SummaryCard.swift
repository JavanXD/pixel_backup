import SwiftUI
import AppKit

struct SummaryCard: View {
    let summary: BackupSummary
    let onNewBackup: () -> Void

    var body: some View {
        VStack(spacing: 24) {

            // Header
            VStack(spacing: 8) {
                Image(systemName: headerIcon)
                    .font(.system(size: 52))
                    .foregroundStyle(headerColor)
                Text(summary.wasCancelled ? "Backup Cancelled" : "Backup Complete")
                    .font(.title.bold())
                if summary.wasCancelled {
                    Text("Transfer was stopped early — files copied so far are shown below.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if summary.failed > 0 {
                    Text("\(summary.failed) file(s) could not be copied — see failures log.")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }

            // Stats grid
            LazyVGrid(columns: [.init(), .init()], spacing: 12) {
                statCell(title: "Copied this run",  value: "\(summary.runCopied) files",
                         sub: String(format: "%.2f GB", summary.runGB), color: .blue)
                statCell(title: "All-time total",   value: "\(summary.totalCopied) files",
                         sub: String(format: "%.2f GB", summary.totalGB), color: .purple)
                statCell(title: "Failed",            value: "\(summary.failed)",
                         sub: summary.failed > 0 ? "See failures log" : "None",
                         color: summary.failed > 0 ? .red : .green)
                statCell(title: "Destination",       value: "Dated folder",
                         sub: summary.destRoot.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                         color: .teal)
            }
            .frame(maxWidth: 500)

            // Action buttons
            HStack(spacing: 12) {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: summary.destRoot))
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                if !summary.logPath.isEmpty {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: summary.logPath))
                    } label: {
                        Label("View Log", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button {
                    onNewBackup()
                } label: {
                    Label(summary.wasCancelled ? "Back" : "New Backup",
                          systemImage: summary.wasCancelled ? "chevron.left" : "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: 500)
        }
        .padding(32)
    }

    private var headerIcon: String {
        if summary.wasCancelled { return "stop.circle.fill" }
        return summary.failed == 0 ? "checkmark.seal.fill" : "checkmark.seal"
    }

    private var headerColor: Color {
        if summary.wasCancelled { return .orange }
        return summary.failed == 0 ? .green : .orange
    }

    private func statCell(title: String, value: String, sub: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .foregroundStyle(color)
            Text(sub)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

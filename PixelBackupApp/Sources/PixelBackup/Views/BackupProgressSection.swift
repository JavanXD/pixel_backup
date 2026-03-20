import SwiftUI

struct BackupProgressSection: View {
    let state: BackupState
    let progress: BackupProgress
    let scanFileCount: Int
    let logLines: [LogLine]
    let hints: [String]
    let speedMBps: Double
    let etaSeconds: Int?
    let elapsedSeconds: Int
    let currentFile: String
    let onCancel: () -> Void
    var onNewBackup: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Header
            HStack {
                Image(systemName: stateIcon)
                    .font(.title3)
                    .foregroundStyle(stateColor)
                Text(state.label)
                    .font(.title3.bold())
                Spacer()
                if state.isRunning {
                    ProgressView().controlSize(.small)
                }
            }

            // Hints
            if !hints.isEmpty {
                HintBannerView(hints: hints)
            }

            // Progress bar + counters
            if state.isRunning || state == .cancelled {
                progressStats
            }

            Divider()

            // Live log tail
            LogView(lines: logLines)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Cancel button
            if state.isRunning {
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        onCancel()
                    } label: {
                        Label("Cancel Transfer", systemImage: "stop.circle")
                    }
                    .buttonStyle(.bordered)
                }
            }

        if case .failed(let msg) = state {
            HStack {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(msg).font(.caption).foregroundStyle(.red)
                Spacer()
                if let restart = onNewBackup {
                    Button { restart() } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        if state == .cancelled {
            HStack {
                Label("Cancelled — already-copied files will be skipped on the next run.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let restart = onNewBackup {
                    Button { restart() } label: {
                        Label("New Backup", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        }
    }

    @ViewBuilder
    private var progressStats: some View {
        VStack(alignment: .leading, spacing: 8) {
            if progress.seen > 0 {
                ProgressView(value: progress.fractionComplete)
                    .tint(.blue)
                    .animation(.easeInOut(duration: 0.3), value: progress.fractionComplete)
            }

            HStack(spacing: 20) {
                stat(label: "Seen",    value: progress.seen,    color: .primary)
                stat(label: "Copied",  value: progress.copied,  color: .green)
                stat(label: "Skipped", value: progress.skipped, color: .secondary)
                stat(label: "Failed",  value: progress.failed,  color: progress.failed > 0 ? .red : .secondary)
                Spacer()
                if progress.copiedGB > 0 {
                    Text(String(format: "%.2f GB copied", progress.copiedGB))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            // Speed + ETA + elapsed row
            HStack(spacing: 16) {
                if speedMBps > 0.05 {
                    Label(speedLabel, systemImage: "gauge.medium")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.blue)
                    if let eta = etaSeconds, eta > 0 {
                        Label(etaLabel(eta) + " remaining", systemImage: "clock")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if elapsedSeconds > 0 {
                    Label(elapsedLabel, systemImage: "timer")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if !currentFile.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    Text(currentFile)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else if scanFileCount > 0 {
                Text("\(scanFileCount) files found across all scanned folders")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func stat(label: String, value: Int, color: Color) -> some View {
        VStack(spacing: 1) {
            Text("\(value)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var speedLabel: String {
        if speedMBps >= 100 { return String(format: "%.0f MB/s", speedMBps) }
        return String(format: "%.1f MB/s", speedMBps)
    }

    private var elapsedLabel: String {
        let s = elapsedSeconds
        if s < 60   { return "\(s)s elapsed" }
        if s < 3600 { let m = s/60; let r = s%60; return r > 0 ? "\(m)m \(r)s elapsed" : "\(m)m elapsed" }
        let h = s/3600; let m = (s%3600)/60; return m > 0 ? "\(h)h \(m)m elapsed" : "\(h)h elapsed"
    }

    private func etaLabel(_ seconds: Int) -> String {
        if seconds < 60   { return "\(seconds)s" }
        if seconds < 3600 {
            let m = seconds / 60; let s = seconds % 60
            return s > 0 ? "\(m)m \(s)s" : "\(m)m"
        }
        let h = seconds / 3600; let m = (seconds % 3600) / 60
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }

    private var stateIcon: String {
        switch state {
        case .scanning:         return "magnifyingglass"
        case .copying:          return "arrow.down.circle"
        case .retrying:         return "arrow.clockwise"
        case .finishing:        return "checkmark.circle"
        case .resolvingDevice:  return "cable.connector"
        case .cancelled:        return "stop.circle"
        case .failed:           return "xmark.octagon"
        default:                return "arrow.down.circle"
        }
    }

    private var stateColor: Color {
        switch state {
        case .failed:    return .red
        case .cancelled: return .orange
        default:         return .blue
        }
    }
}

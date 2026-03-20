import SwiftUI
import AppKit

struct BackupHistoryView: View {
    let destRootBase: String
    @Environment(\.dismiss) private var dismiss

    @State private var records: [BackupRecord] = []
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toolbar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Backup History")
                        .font(.title2.bold())
                    Text(destRootBase.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: destRootBase))
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding()

            Divider()

            if isLoading {
                HStack {
                    Spacer()
                    ProgressView("Scanning backup folders…")
                    Spacer()
                }
                .padding(40)
            } else if records.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("No backups found")
                        .font(.title3)
                    Text("Backups will appear here after your first run.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(60)
            } else {
                List(records) { record in
                    BackupRecordRow(record: record)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .onAppear { Task { await loadRecords() } }
    }

    // MARK: - Load

    private func loadRecords() async {
        isLoading = true
        let fm = FileManager.default
        var result: [BackupRecord] = []

        if let items = try? fm.contentsOfDirectory(atPath: destRootBase) {
            let dated = items
                .filter { $0.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil }
                .sorted(by: >)

            for name in dated {
                let path = "\(destRootBase)/\(name)"
                var record = BackupRecord(folderName: name, path: path)
                // Read stats from manifest.tsv (one line per file, col 1 = bytes).
                // This is O(lines) vs O(file-system-nodes) and orders of magnitude
                // faster for large backups (140 GB = 18k files = 18k stat() calls).
                let (count, bytes) = manifestStats(at: path)
                record.fileCount = count
                record.sizeBytes = bytes
                result.append(record)
            }
        }

        await MainActor.run {
            records = result
            isLoading = false
        }
    }

    /// Read file-count and total bytes from `.transfer_meta/manifest.tsv`.
    /// Each line is:  bytes TAB remote_path TAB local_path
    /// Falls back to a quick filesystem count if the manifest is absent.
    private func manifestStats(at path: String) -> (Int, Int64) {
        let manifestPath = "\(path)/.transfer_meta/manifest.tsv"
        if let content = try? String(contentsOfFile: manifestPath, encoding: .utf8) {
            let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
            var bytes: Int64 = 0
            for line in lines {
                let col = line.prefix(while: { $0 != "\t" })
                bytes += Int64(col) ?? 0
            }
            return (lines.count, bytes)
        }
        // Fallback: count direct children (fast, no recursion)
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(atPath: path))?.filter { !$0.hasPrefix(".") } ?? []
        return (children.count, 0)
    }
}

// MARK: - Row

struct BackupRecordRow: View {
    let record: BackupRecord

    // Checked once when the row appears — no continuous scanning.
    @State private var folderExists: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            // Date badge
            VStack(spacing: 2) {
                Text(record.month)
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                    .background(folderExists ? .blue : .gray)
                Text(record.day)
                    .font(.title3.bold())
                    .padding(.bottom, 4)
            }
            .frame(width: 44)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(record.folderName)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                    .foregroundStyle(folderExists ? .primary : .secondary)
                if folderExists {
                    HStack(spacing: 12) {
                        Label("\(record.fileCount) files", systemImage: "photo.stack")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Label(record.sizeLabel, systemImage: "internaldrive")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label("Folder moved or deleted", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: record.path))
            } label: {
                Label("Open", systemImage: "folder")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!folderExists)
        }
        .padding(.vertical, 4)
        .onAppear {
            folderExists = FileManager.default.fileExists(atPath: record.path)
        }
    }
}

// MARK: - Data model

struct BackupRecord: Identifiable {
    let id = UUID()
    let folderName: String
    let path: String
    var fileCount: Int = 0
    var sizeBytes: Int64 = 0

    var sizeLabel: String {
        let gb = Double(sizeBytes) / 1_073_741_824
        if gb >= 0.1 { return String(format: "%.2f GB", gb) }
        let mb = Double(sizeBytes) / 1_048_576
        if mb >= 0.1 { return String(format: "%.0f MB", mb) }
        return "\(sizeBytes) B"
    }

    // Extract month and day from name like "2026-03-19_DeviceName..."
    var month: String {
        guard folderName.count >= 7 else { return "" }
        let idx = folderName.index(folderName.startIndex, offsetBy: 5)
        let end = folderName.index(idx, offsetBy: 2)
        let mm = String(folderName[idx..<end])
        let months = ["","Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        return months[Int(mm) ?? 0]
    }

    var day: String {
        guard folderName.count >= 10 else { return "" }
        let idx = folderName.index(folderName.startIndex, offsetBy: 8)
        let end = folderName.index(idx, offsetBy: 2)
        return String(folderName[idx..<end])
    }
}

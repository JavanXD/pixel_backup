import SwiftUI
import AppKit

struct BackupHistoryView: View {
    let destRootBase: String
    var onContinue: ((BackupRecord) -> Void)? = nil
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
                    BackupRecordRow(
                        record: record,
                        onContinue: onContinue.map { callback in
                            {
                                callback(record)
                                dismiss()
                            }
                        }
                    )
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
        let base = destRootBase
        let result: [BackupRecord] = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let items = try? fm.contentsOfDirectory(atPath: base) else { return [] }
            let dated = items
                .filter { $0.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil }
                .sorted(by: >)

            return dated.map { name -> BackupRecord in
                let path = "\(base)/\(name)"
                var record = BackupRecord(folderName: name, path: path)
                let (count, bytes) = BackupFolderIndex.manifestStats(at: path)
                record.fileCount = count
                record.sizeBytes = bytes
                record.isIncomplete = BackupFolderIndex.looksIncomplete(at: path)
                    || (!BackupFolderIndex.hasCompleteStatus(at: path)
                        && !BackupFolderIndex.folderDateIsToday(name))
                return record
            }
        }.value

        await MainActor.run {
            records = result
            isLoading = false
        }
    }
}

// MARK: - Row

struct BackupRecordRow: View {
    let record: BackupRecord
    var onContinue: (() -> Void)? = nil

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
                    .background(folderExists ? (record.isIncomplete ? .orange : .blue) : .gray)
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
                        if record.isIncomplete {
                            Label("Unfinished", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
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

            if folderExists, let onContinue {
                Button {
                    onContinue()
                } label: {
                    Label(record.isIncomplete ? "Continue" : "Add to", systemImage: "play.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(record.isIncomplete ? .orange : .accentColor)
                .controlSize(.small)
                .help(record.isIncomplete
                      ? "Resume this unfinished backup into the same dated folder"
                      : "Copy more files into this existing backup folder")
            }

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
    /// True when this folder looks like an unfinished run (paused / interrupted / failed).
    var isIncomplete: Bool = false

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

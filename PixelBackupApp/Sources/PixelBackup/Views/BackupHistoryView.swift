import SwiftUI
import AppKit

struct BackupHistoryView: View {
    let destRootBase: String
    var onContinue: ((BackupRecord) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var backupManager: BackupManager

    @State private var records: [BackupRecord] = []
    @State private var isLoading = true
    @State private var reduceTarget: BackupRecord?
    @State private var showReduceSheet = false

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
                        canReduce: canReduce(record),
                        alreadyReduced: isAlreadyReduced(record),
                        reduceDisabled: backupManager.state.isRunning || record.isIncomplete,
                        onContinue: onContinue.map { callback in
                            {
                                callback(record)
                                dismiss()
                            }
                        },
                        onReduce: {
                            reduceTarget = record
                            showReduceSheet = true
                        }
                    )
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 620, minHeight: 380)
        .onAppear { Task { await loadRecords() } }
        .sheet(isPresented: $showReduceSheet, onDismiss: {
            reduceTarget = nil
            Task { await loadRecords() }
        }) {
            if let target = reduceTarget {
                ReduceDuplicatesSheet(
                    target: target,
                    destRootBase: destRootBase,
                    scriptPath: backupManager.resolvedDedupeScriptPath(),
                    backupRunning: backupManager.state.isRunning
                )
            }
        }
    }

    /// True when this complete row has at least one other complete same-device backup to pair with.
    private func canReduce(_ record: BackupRecord) -> Bool {
        guard !record.isIncomplete else { return false }
        let peers = BackupFolderIndex.completeSameDevice(as: record.folderName, in: destRootBase)
        return peers.contains(where: { $0.folderName != record.folderName })
    }

    private func isAlreadyReduced(_ record: BackupRecord) -> Bool {
        guard let prev = BackupFolderIndex.previousComplete(before: record.folderName, in: destRootBase)
        else { return false }
        // State lives on the older folder, keyed by canonical (newer / selected) name.
        return BackupFolderIndex.isAlreadyReduced(at: prev.path, againstCanonical: record.folderName)
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
    var canReduce: Bool = false
    var alreadyReduced: Bool = false
    var reduceDisabled: Bool = false
    var onContinue: (() -> Void)? = nil
    var onReduce: (() -> Void)? = nil

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
                        if alreadyReduced {
                            Label("Reduced", systemImage: "link")
                                .font(.caption)
                                .foregroundStyle(.green)
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

            if folderExists, onReduce != nil, canReduce {
                Button {
                    onReduce?()
                } label: {
                    Label(alreadyReduced ? "Reduce again…" : "Reduce duplicates…",
                          systemImage: "arrow.triangle.branch")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(reduceDisabled)
                .help("Compare two same-device backups and replace duplicate files in one with links to the baseline. Both folders stay browsable.")
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

// MARK: - Reduce sheet

private struct DedupeCandidateRow: Identifiable {
    /// Relative path under the reduce/older backup folder (unique per dry-run).
    var id: String { relativePath }
    let relativePath: String
    let sizeBytes: Int64
}

private struct ReduceDuplicatesSheet: View {
    let target: BackupRecord
    let destRootBase: String
    let scriptPath: String?
    let backupRunning: Bool

    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .idle
    @State private var eligibleFolders: [BackupRecord] = []
    /// Folder that keeps real bytes (baseline / canonical).
    @State private var baselineFolderName: String = ""
    /// Folder that will get links for matching duplicates (reduce / older role).
    @State private var reduceFolderName: String = ""
    @State private var logText: String = ""
    @State private var candidates: Int = 0
    @State private var reclaimableBytes: Int64 = 0
    /// Top-N by size only (see `maxListedCandidates`); totals come from SUMMARY / scan count.
    @State private var candidateRows: [DedupeCandidateRow] = []
    @State private var candidatesSeenDuringScan: Int = 0
    @State private var summaryLine: String = ""
    @State private var errorMessage: String?
    @State private var process: Process?
    @State private var alreadyReducedNote: Bool = false
    @State private var showLogDetails: Bool = true
    /// Suppresses picker onChange dry-runs while defaults are applied.
    @State private var ignorePairChanges: Bool = false
    /// Soft hint when same volume but APFS clone is unavailable (hardlink-only).
    @State private var volumeHint: String?
    /// Live apply progress from script `PROGRESS` lines.
    @State private var applyPhaseLabel: String = "" // "hash" | "link" | ""
    @State private var applyLinked: Int = 0
    @State private var applyHashed: Int = 0
    @State private var applyErrors: Int = 0
    @State private var applyHashMismatch: Int = 0
    @State private var applyReclaimableBytes: Int64 = 0
    @State private var applyTotalCandidates: Int = 0

    /// Max paths kept in the SwiftUI list (largest first). Totals stay accurate via SUMMARY.
    private static let maxListedCandidates = 150

    private enum Phase {
        case idle
        case estimating
        case readyToApply
        case applying
        case done
        case failed
    }

    private var pickersEnabled: Bool {
        switch phase {
        case .applying, .done: return false
        default: return true
        }
    }

    private var baselineRecord: BackupRecord? {
        eligibleFolders.first { $0.folderName == baselineFolderName }
    }

    private var reduceRecord: BackupRecord? {
        eligibleFolders.first { $0.folderName == reduceFolderName }
    }

    private var reduceChoices: [BackupRecord] {
        eligibleFolders.filter { $0.folderName != baselineFolderName }
    }

    private var baselineChoices: [BackupRecord] {
        eligibleFolders.filter { $0.folderName != reduceFolderName }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reduce duplicates")
                .font(.title2.bold())

            Text("Pick two complete same-device backups. The baseline keeps the real files; matching files in the other backup become APFS clones or hardlinks (same volume). Both trees stay fully browsable.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            pairSelectionSection

            contentForPhase

            if showsCandidateList {
                candidateListSection
            }

            DisclosureGroup(isExpanded: $showLogDetails) {
                ScrollView {
                    Text(logText.isEmpty ? "Waiting…" : logText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 80, maxHeight: showsCandidateList ? 120 : 200)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            } label: {
                Text(showsCandidateList ? "Script log" : "Log")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack {
                if phase == .readyToApply || phase == .failed {
                    Button("Re-estimate") { startDryRun() }
                        .disabled(!pickersEnabled || backupRunning || scriptPath == nil)
                }
                Spacer()
                switch phase {
                case .idle, .estimating, .applying:
                    Button("Cancel") { cancelProcess(); dismiss() }
                        .keyboardShortcut(.cancelAction)
                case .readyToApply:
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Apply reduce") { startApply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(backupRunning || scriptPath == nil || candidates == 0 && !alreadyReducedNote)
                        .keyboardShortcut(.defaultAction)
                case .done, .failed:
                    Button("Close") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 580, minHeight: 520)
        .onAppear { preparePairAndEstimate() }
        .onDisappear { cancelProcess() }
    }

    private var showsCandidateList: Bool {
        !candidateRows.isEmpty && (phase == .readyToApply || phase == .estimating)
    }

    @ViewBuilder
    private var pairSelectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Reduce this backup")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Matching duplicates here become links (space reclaimed).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Picker("Reduce this backup", selection: $reduceFolderName) {
                    ForEach(reduceChoices, id: \.folderName) { folder in
                        Text(folderLabel(folder)).tag(folder.folderName)
                    }
                }
                .labelsHidden()
                .disabled(!pickersEnabled || reduceChoices.isEmpty)
                .onChange(of: reduceFolderName) { _ in
                    guard pickersEnabled, !ignorePairChanges else { return }
                    alreadyReducedNote = false
                    startDryRun()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Using baseline")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Keeps the physical copy for matching files (typically a newer backup).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Picker("Using baseline", selection: $baselineFolderName) {
                    ForEach(baselineChoices, id: \.folderName) { folder in
                        Text(folderLabel(folder)).tag(folder.folderName)
                    }
                }
                .labelsHidden()
                .disabled(!pickersEnabled || baselineChoices.isEmpty)
                .onChange(of: baselineFolderName) { newValue in
                    guard pickersEnabled, !ignorePairChanges else { return }
                    ignorePairChanges = true
                    // Keep reduce pointing at a different folder; prefer previous of new baseline.
                    if reduceFolderName == newValue
                        || !eligibleFolders.contains(where: {
                            $0.folderName == reduceFolderName && $0.folderName != newValue
                        }) {
                        if let prev = BackupFolderIndex.previousComplete(before: newValue, in: destRootBase) {
                            reduceFolderName = prev.folderName
                        } else if let alt = eligibleFolders.first(where: { $0.folderName != newValue }) {
                            reduceFolderName = alt.folderName
                        }
                    }
                    ignorePairChanges = false
                    alreadyReducedNote = false
                    startDryRun()
                }
            }

            if let reduce = reduceRecord, let baseline = baselineRecord {
                let already = BackupFolderIndex.isAlreadyReduced(
                    at: reduce.path,
                    againstCanonical: baseline.folderName
                )
                if already {
                    Label("This pair was already reduced earlier.", systemImage: "link")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if reduce.folderName > baseline.folderName {
                    Label("Tip: the reduce folder is newer than the baseline. Usually baseline is the newer backup.",
                          systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            if let volumeHint {
                Label(volumeHint, systemImage: "externaldrive")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var applyProgressFraction: Double? {
        let total = applyTotalCandidates > 0 ? applyTotalCandidates : candidates
        guard total > 0 else { return nil }
        // Hash is most of the wall time (~70% of the bar); linking fills the rest.
        if applyPhaseLabel == "hash" || (applyPhaseLabel.isEmpty && applyHashed > 0 && applyLinked == 0) {
            return 0.7 * min(1, Double(applyHashed) / Double(total))
        }
        let matchTotal = max(0, applyHashed - applyHashMismatch)
        if matchTotal > 0 {
            let linkFrac = min(1, Double(applyLinked + applyErrors) / Double(matchTotal))
            return min(1, 0.7 + 0.3 * linkFrac)
        }
        if applyHashed > 0 {
            return 1
        }
        return nil
    }

    @ViewBuilder
    private var applyProgressSection: some View {
        let total = applyTotalCandidates > 0 ? applyTotalCandidates : candidates
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let fraction = applyProgressFraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(applyStatusText(total: total))
                .font(.callout)
            if applyReclaimableBytes > 0 || applyLinked > 0 {
                Text("Reclaimable so far: \(byteLabel(applyReclaimableBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if applyErrors > 0 || applyHashMismatch > 0 {
                Text("Mismatches: \(applyHashMismatch) · Errors: \(applyErrors)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func applyStatusText(total: Int) -> String {
        switch applyPhaseLabel {
        case "hash":
            if total > 0 {
                return "Verifying SHA-256… \(applyHashed) / \(total)"
            }
            return "Verifying SHA-256… \(applyHashed) hashed"
        case "link":
            if total > 0 {
                return "Linking duplicates… \(applyLinked) linked · \(applyHashed) / \(total) verified"
            }
            return "Linking duplicates… \(applyLinked) linked"
        default:
            if applyLinked > 0 || applyHashed > 0 {
                return "Reducing… linked \(applyLinked)"
            }
            return "Linking duplicates…"
        }
    }

    private var candidateTotalForDisplay: Int {
        max(candidates, candidatesSeenDuringScan)
    }

    private var candidateOmittedCount: Int {
        max(0, candidateTotalForDisplay - candidateRows.count)
    }

    @ViewBuilder
    private var candidateListSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(candidateOmittedCount > 0 ? "Largest duplicate files" : "Duplicate files found")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if candidateOmittedCount > 0 {
                    Text("\(candidateRows.count) of \(candidateTotalForDisplay)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("\(candidateRows.count) listed")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(candidateRows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(row.relativePath)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            Text(byteLabel(row.sizeBytes))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                    if candidateOmittedCount > 0 {
                        Text("+\(candidateOmittedCount) more not shown (totals above still include all)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 6)
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 200)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var contentForPhase: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .estimating:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(candidatesSeenDuringScan == 0
                     ? "Estimating reclaimable space…"
                     : "Estimating… \(candidatesSeenDuringScan) candidates so far")
                    .font(.callout)
            }
        case .readyToApply:
            VStack(alignment: .leading, spacing: 6) {
                if alreadyReducedNote {
                    Label("Already reduced for this pair. Re-apply will re-scan (use only if needed).",
                          systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                }
                Text("Candidates: \(candidates)")
                Text("Estimated reclaimable: \(byteLabel(reclaimableBytes))")
                Text("Apply verifies SHA-256 before linking. The last real copy is never deleted.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        case .applying:
            applyProgressSection
        case .done:
            VStack(alignment: .leading, spacing: 4) {
                Label("Reduce finished", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if !summaryLine.isEmpty {
                    Text(summaryLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .failed:
            Label(errorMessage ?? "Reduce failed", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.callout)
        }
    }

    private func folderLabel(_ folder: BackupRecord) -> String {
        var parts = [folder.folderName, folder.sizeLabel]
        if folder.folderName == target.folderName { parts.append("opened") }
        if let prev = BackupFolderIndex.previousComplete(before: baselineFolderName, in: destRootBase),
           prev.folderName == folder.folderName,
           folder.folderName != baselineFolderName {
            parts.append("previous")
        }
        return parts.joined(separator: " · ")
    }

    private func byteLabel(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 0.1 { return String(format: "%.2f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        if mb >= 0.1 { return String(format: "%.1f MB", mb) }
        if bytes >= 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return "\(bytes) B"
    }

    private func preparePairAndEstimate() {
        ignorePairChanges = true
        eligibleFolders = BackupFolderIndex.completeSameDevice(
            as: target.folderName,
            in: destRootBase
        )
        // Prefer opened row as baseline when it is complete; otherwise newest complete.
        if eligibleFolders.contains(where: { $0.folderName == target.folderName }) {
            baselineFolderName = target.folderName
        } else if let newest = eligibleFolders.first {
            baselineFolderName = newest.folderName
        }

        if let prev = BackupFolderIndex.previousComplete(before: baselineFolderName, in: destRootBase) {
            reduceFolderName = prev.folderName
        } else if let alt = eligibleFolders.first(where: { $0.folderName != baselineFolderName }) {
            reduceFolderName = alt.folderName
        }
        ignorePairChanges = false

        startDryRun()
    }

    private func startDryRun() {
        guard let scriptPath else {
            phase = .failed
            errorMessage = "dedupe_backups.sh not found in the app bundle."
            return
        }
        if backupRunning {
            phase = .failed
            errorMessage = "Finish or pause the active backup before reducing duplicates."
            return
        }
        guard let baseline = baselineRecord, let reduce = reduceRecord else {
            phase = .failed
            errorMessage = "Pick two different complete same-device backups to compare."
            return
        }
        guard baseline.folderName != reduce.folderName else {
            phase = .failed
            errorMessage = "Baseline and reduce folders must be different."
            return
        }
        guard passLinkPreflight(baseline: baseline, reduce: reduce) else { return }
        phase = .estimating
        alreadyReducedNote = BackupFolderIndex.isAlreadyReduced(
            at: reduce.path,
            againstCanonical: baseline.folderName
        )
        runScript(
            scriptPath: scriptPath,
            apply: false,
            force: false,
            canonicalPath: baseline.path,
            olderPath: reduce.path
        )
    }

    private func startApply() {
        guard let scriptPath, let baseline = baselineRecord, let reduce = reduceRecord else { return }
        guard passLinkPreflight(baseline: baseline, reduce: reduce) else { return }
        phase = .applying
        applyPhaseLabel = ""
        applyLinked = 0
        applyHashed = 0
        applyErrors = 0
        applyHashMismatch = 0
        applyReclaimableBytes = 0
        applyTotalCandidates = candidates
        let force = alreadyReducedNote
        runScript(
            scriptPath: scriptPath,
            apply: true,
            force: force,
            canonicalPath: baseline.path,
            olderPath: reduce.path
        )
    }

    /// Fail fast on different volumes / unsupported FS; set hardlink-only hint when clone unavailable.
    @discardableResult
    private func passLinkPreflight(baseline: BackupRecord, reduce: BackupRecord) -> Bool {
        switch BackupFolderIndex.DedupeLinkPreflight.evaluate(
            baselinePath: baseline.path,
            reducePath: reduce.path
        ) {
        case .ready(let supportsClone, let volumeName):
            if supportsClone {
                volumeHint = nil
            } else {
                let vol = volumeName.map { " (\($0))" } ?? ""
                volumeHint = "This volume\(vol) is not APFS (or clone is unavailable). Reduce will use hardlinks only."
            }
            return true
        case .failed(let message):
            volumeHint = nil
            phase = .failed
            errorMessage = message
            return false
        }
    }

    private func runScript(
        scriptPath: String,
        apply: Bool,
        force: Bool,
        canonicalPath: String,
        olderPath: String
    ) {
        cancelProcess()
        logText = ""
        errorMessage = nil
        if !apply {
            candidateRows = []
            candidates = 0
            candidatesSeenDuringScan = 0
            reclaimableBytes = 0
            showLogDetails = true
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        var args = [scriptPath, apply ? "--apply" : "--dry-run"]
        if force { args.append("--force") }
        args += ["--canonical", canonicalPath, "--older", olderPath]
        p.arguments = args
        p.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "dumb",
        ]
        p.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let handle = pipe.fileHandleForReading
        let bufferQueue = DispatchQueue(label: "dedupe.buffer", qos: .utility)
        var buffer = ""
        handle.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            bufferQueue.async {
                buffer += chunk
                var lines: [String] = []
                while let nl = buffer.firstIndex(of: "\n") {
                    lines.append(String(buffer[buffer.startIndex..<nl]))
                    buffer.removeSubrange(buffer.startIndex...nl)
                }
                guard !lines.isEmpty else { return }
                DispatchQueue.main.async {
                    for line in lines { self.handleLine(line, apply: apply) }
                }
            }
        }

        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            DispatchQueue.main.async {
                handle.readabilityHandler = nil
                self.process = nil
                self.handleExit(code: code, apply: apply)
            }
        }

        do {
            try p.run()
            process = p
        } catch {
            phase = .failed
            errorMessage = "Failed to launch reduce script: \(error.localizedDescription)"
        }
    }

    private func handleLine(_ line: String, apply: Bool) {
        if logText.count > 20_000 {
            logText = String(logText.suffix(16_000))
        }
        logText += line + "\n"

        if line.hasPrefix("OK already_reduced") {
            alreadyReducedNote = true
        }
        if !apply, let parsed = Self.parseCandidateLine(line) {
            considerCandidate(path: parsed.path, size: parsed.size)
        }
        if apply, line.hasPrefix("INFO apply_candidates="),
           let value = intValue(after: "apply_candidates=", in: line) {
            applyTotalCandidates = value
        }
        if apply, line.hasPrefix("PROGRESS ") {
            if let phaseToken = stringValue(after: "phase=", in: line) {
                applyPhaseLabel = phaseToken
            }
            if let value = intValue(after: "linked=", in: line) {
                applyLinked = value
            }
            if let value = intValue(after: "hashed=", in: line) {
                applyHashed = value
            }
            if let value = intValue(after: "errors=", in: line) {
                applyErrors = value
            }
            if let value = intValue(after: "hash_mismatch=", in: line) {
                applyHashMismatch = value
            }
            if let value = int64Value(after: "reclaimable_bytes=", in: line) {
                applyReclaimableBytes = value
            }
            if let value = intValue(after: "candidates=", in: line) {
                applyTotalCandidates = value
            }
        }
        if line.hasPrefix("SUMMARY ") {
            summaryLine = line
            if let value = intValue(after: "candidates=", in: line) {
                candidates = value
            }
            if let value = int64Value(after: "reclaimable_bytes=", in: line) {
                reclaimableBytes = value
                if apply { applyReclaimableBytes = value }
            }
            if let value = intValue(after: "linked=", in: line) {
                // Prefer linked count after apply
                if apply {
                    candidates = value
                    applyLinked = value
                }
            }
        }
    }

    private func handleExit(code: Int32, apply: Bool) {
        switch code {
        case 0:
            if apply {
                phase = .done
            } else {
                phase = .readyToApply
                // Prefer the curated list once dry-run finishes; log stays available.
                if !candidateRows.isEmpty {
                    showLogDetails = false
                }
            }
        case 2:
            phase = .failed
            errorMessage = "No eligible same-device backup pair found."
        case 3:
            phase = .failed
            errorMessage = "Incomplete backup — finish it first (or pick a complete pair)."
        case 4:
            phase = .failed
            errorMessage = "Cannot link (different volume or link errors). See log."
        default:
            phase = .failed
            errorMessage = "Reduce script exited with code \(code). See log."
        }
    }

    private func cancelProcess() {
        if let p = process, p.isRunning {
            p.interrupt()
        }
        process = nil
    }

    private func intValue(after key: String, in line: String) -> Int? {
        guard let range = line.range(of: key) else { return nil }
        let rest = line[range.upperBound...]
        let token = rest.prefix(while: { $0.isNumber })
        return Int(token)
    }

    private func int64Value(after key: String, in line: String) -> Int64? {
        guard let range = line.range(of: key) else { return nil }
        let rest = line[range.upperBound...]
        let token = rest.prefix(while: { $0.isNumber })
        return Int64(token)
    }

    private func stringValue(after key: String, in line: String) -> String? {
        guard let range = line.range(of: key) else { return nil }
        let rest = line[range.upperBound...]
        let token = rest.prefix(while: { !$0.isWhitespace })
        let value = String(token)
        return value.isEmpty ? nil : value
    }

    /// Keep only the largest `maxListedCandidates` paths in the UI list (sorted by size desc).
    private func considerCandidate(path: String, size: Int64) {
        candidatesSeenDuringScan += 1
        let row = DedupeCandidateRow(relativePath: path, sizeBytes: size)
        let limit = Self.maxListedCandidates

        if candidateRows.count < limit {
            if let idx = candidateRows.firstIndex(where: { $0.sizeBytes < size }) {
                candidateRows.insert(row, at: idx)
            } else {
                candidateRows.append(row)
            }
            return
        }
        guard let smallest = candidateRows.last, size > smallest.sizeBytes else { return }
        candidateRows.removeLast()
        if let idx = candidateRows.firstIndex(where: { $0.sizeBytes < size }) {
            candidateRows.insert(row, at: idx)
        } else {
            candidateRows.append(row)
        }
    }

    /// Parses dry-run `CANDIDATE` lines.
    /// Preferred: `CANDIDATE size=<bytes> <relpath>` (path may contain spaces).
    /// Legacy: `CANDIDATE <relpath> size=<bytes>`.
    static func parseCandidateLine(_ line: String) -> (path: String, size: Int64)? {
        let prefix = "CANDIDATE "
        guard line.hasPrefix(prefix) else { return nil }
        let rest = String(line.dropFirst(prefix.count))

        if rest.hasPrefix("size=") {
            let afterKey = rest.dropFirst("size=".count)
            guard let space = afterKey.firstIndex(of: " ") else { return nil }
            let sizeToken = afterKey[..<space]
            guard let size = Int64(sizeToken) else { return nil }
            let path = String(afterKey[afterKey.index(after: space)...])
            guard !path.isEmpty else { return nil }
            return (path, size)
        }

        guard let sizeRange = rest.range(of: " size=", options: .backwards) else { return nil }
        let path = String(rest[..<sizeRange.lowerBound])
        let sizeToken = rest[sizeRange.upperBound...].prefix(while: { $0.isNumber })
        guard let size = Int64(sizeToken), !path.isEmpty else { return nil }
        return (path, size)
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

import Foundation
import Combine

@MainActor
final class BackupManager: ObservableObject {

    // MARK: - Published state

    @Published var state: BackupState = .idle
    @Published var progress = BackupProgress()
    @Published var logLines: [LogLine] = []
    @Published var hints: [String] = []
    @Published var scanFileCount: Int = 0
    @Published var currentDir: String = ""

    // Speed & ETA (updated every PROGRESS line)
    @Published var speedMBps: Double = 0
    @Published var etaSeconds: Int? = nil

    // Elapsed time
    @Published var elapsedSeconds: Int = 0
    @Published var currentFile: String = ""

    // MARK: - Private

    private var process: Process?
    private var destRoot: String = ""
    private let maxLogLines = 500
    private var startTime: Date?
    private var elapsedTimer: Timer?

    // Tracks which backup "session" is current so that a stale terminationHandler
    // from a previously-cancelled process cannot corrupt a newly-started backup.
    private var currentBackupID: UUID?

    // Retained so we can nil the readabilityHandler in handleTermination.
    private var outputFileHandle: FileHandle?

    // Set to true the moment handleTermination begins; guards handleLogLine from
    // overriding the final state with late-arriving log-line tasks.
    private var isTerminating = false

    // Rolling throughput window (last 60 s)
    private struct SpeedSample { let time: Date; let copiedGB: Double }
    private var speedSamples: [SpeedSample] = []
    private let speedWindowSeconds: TimeInterval = 60

    // MARK: - Script / adb resolution

    func resolvedScriptPath() -> String? {
        if let bundled = Bundle.module.url(forResource: "pixel_backup", withExtension: "sh") {
            ensureExecutable(bundled.path)
            return bundled.path
        }
        // Development fallback — script alongside the built binary
        let devPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/pixel_backup.sh").path
        if FileManager.default.isExecutableFile(atPath: devPath) { return devPath }
        return nil
    }

    private func ensureExecutable(_ path: String) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let perms = (attrs?[.posixPermissions] as? Int) ?? 0
        guard perms & 0o111 == 0 else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    // MARK: - Start

    func startBackup(
        serial: String,
        adbPath: String,
        destRootBase: String,
        folders: [RemoteFolder]
    ) {
        guard !state.isRunning else { return }

        guard let scriptPath = resolvedScriptPath() else {
            state = .failed(message: "pixel_backup.sh not found in app bundle.")
            return
        }

        logLines = []
        hints = []
        progress = BackupProgress()
        scanFileCount = 0
        speedMBps = 0
        etaSeconds = nil
        speedSamples = []
        elapsedSeconds = 0
        currentFile = ""
        isTerminating = false
        startTime = Date()
        state = .resolvingDevice

        let myBackupID = UUID()
        currentBackupID = myBackupID

        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.startTime else { return }
                self.elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
        }

        BackupCoordinator.shared.didStart()
        NotificationManager.shared.requestPermission()

        let adbDir = URL(fileURLWithPath: adbPath).deletingLastPathComponent().path
        let enabledFolders = folders.filter(\.enabled).map(\.remoteName).joined(separator: ":")
        destRoot = destRootBase

        let env: [String: String] = [
            "PATH": "\(adbDir):/usr/bin:/bin:/usr/sbin:/sbin",
            "DEVICE_SERIAL": serial,
            "DEST_ROOT_BASE": destRootBase,
            "REMOTE_DIRS_CSV": enabledFolders,
            "PROGRESS_EVERY_FILES": "50",   // more frequent progress in UI
            "PRECHECK_FREE_SPACE": "1",
            "SHOW_RUNTIME_HINTS": "1",
            "HEALTHCHECK_INTERVAL_SECONDS": "30",
            "TERM": "dumb",
        ]

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [scriptPath]
        p.environment = env
        p.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        outputFileHandle = pipe.fileHandleForReading

        // Stream output line by line.
        // Use a serial queue for the buffer so reads/writes are thread-safe,
        // then hop to @MainActor (not just DispatchQueue.main) for UI updates.
        let bufferQueue = DispatchQueue(label: "backup.buffer.\(serial)", qos: .utility)
        var buffer = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            bufferQueue.async {
                buffer += chunk
                var lines: [String] = []
                while let nl = buffer.firstIndex(of: "\n") {
                    lines.append(String(buffer[buffer.startIndex..<nl]))
                    buffer.removeSubrange(buffer.startIndex...nl)
                }
                guard !lines.isEmpty else { return }
                Task { @MainActor [weak self] in
                    for line in lines { self?.handleLogLine(line) }
                }
            }
        }

        // terminationHandler fires on an arbitrary background thread.
        // We clear the process's I/O here (safe — `proc` is already terminated
        // and is the specific process object, not `self.process` which may have
        // been replaced by a newer backup).  Then we hop to @MainActor for all
        // state mutations; passing myBackupID lets handleTermination detect and
        // ignore stale terminations from previously-cancelled processes.
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            proc.standardOutput = nil
            proc.standardError = nil
            Task { @MainActor [weak self] in
                self?.handleTermination(exitCode: code, backupID: myBackupID)
            }
        }

        do {
            try p.run()
            process = p
        } catch {
            state = .failed(message: "Failed to launch script: \(error.localizedDescription)")
        }
    }

    // MARK: - Cancel

    func cancel() {
        guard let p = process, p.isRunning else { return }
        p.interrupt()   // SIGINT → triggers on_interrupt() in the script
        // terminationHandler will call BackupCoordinator.shared.didFinish()
        state = .cancelled
    }

    // MARK: - Log handling

    private func handleLogLine(_ raw: String) {
        // Once handleTermination has started, ignore any log-line tasks that were
        // already queued — they must not override the final state.
        guard !isTerminating else { return }

        let line = LogParser.parse(raw)
        appendLog(line)

        switch line.level {
        case .copy:
            // Body is like: "/sdcard/DCIM/Camera/PXL_20260101.jpg (attempt 1/3)"
            let filename = line.body
                .components(separatedBy: " (attempt").first ?? line.body
            currentFile = URL(fileURLWithPath: filename).lastPathComponent

        case .progress:
            if let p = LogParser.parseProgress(line) {
                updateThroughput(newGB: p.copiedGB, fraction: p.fractionComplete)
                progress = p
                if state == .resolvingDevice || state == .scanning(dir: currentDir) {
                    state = .copying
                }
            }

        case .hint, .warn:
            hints.append(line.body)

        case .fatal, .error:
            state = .failed(message: line.body)

        case .info:
            if let (count, _) = LogParser.parseScanComplete(line) {
                scanFileCount += count
            } else if let dir = LogParser.parseScanningDir(line) {
                currentDir = dir
                state = .scanning(dir: dir)
            } else if line.body.contains("Starting transfer") {
                state = .copying
            } else if line.body.contains("Retrying failed") {
                state = .retrying
            }

        default:
            break
        }
    }

    private func appendLog(_ line: LogLine) {
        logLines.append(line)
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
    }

    // MARK: - Throughput

    private func updateThroughput(newGB: Double, fraction: Double) {
        let now = Date()
        speedSamples.append(SpeedSample(time: now, copiedGB: newGB))
        // Drop samples outside the rolling window
        speedSamples.removeAll { now.timeIntervalSince($0.time) > speedWindowSeconds }

        guard speedSamples.count >= 2, let oldest = speedSamples.first else {
            speedMBps = 0; etaSeconds = nil; return
        }

        let elapsed = now.timeIntervalSince(oldest.time)
        guard elapsed > 1 else { return }

        let deltaGB = newGB - oldest.copiedGB
        let mbps = max(0, deltaGB * 1024.0 / elapsed)
        speedMBps = mbps

        // ETA: estimate remaining GB using current fraction of file count
        guard mbps > 0.01, fraction > 0.001, fraction < 1 else { etaSeconds = nil; return }
        let totalEstimatedGB = newGB / fraction
        let remainingGB = totalEstimatedGB - newGB
        etaSeconds = Int((remainingGB * 1024.0) / mbps)
    }

    // MARK: - Termination

    private func handleTermination(exitCode: Int32, backupID: UUID) {
        // Stale termination from a previously-cancelled process — the user already
        // started a new backup.  Still decrement the coordinator count (didStart was
        // called for that old backup) but leave all other state alone.
        guard currentBackupID == backupID else {
            BackupCoordinator.shared.didFinish()
            return
        }

        isTerminating = true
        outputFileHandle?.readabilityHandler = nil
        outputFileHandle = nil
        process = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        currentFile = ""
        BackupCoordinator.shared.didFinish()

        switch exitCode {
        case 0:
            let summary = LogParser.parseSummary(from: logLines, destRoot: destRoot)
                ?? BackupSummary(
                    runCopied: progress.copied, runGB: 0,
                    totalCopied: progress.copied + progress.skipped, totalGB: 0,
                    failed: progress.failed,
                    destRoot: destRoot, logPath: "", failedPath: ""
                )
            NotificationManager.shared.sendCompletion(
                filesCopied: summary.runCopied,
                gb: summary.runGB > 0 ? summary.runGB : progress.copiedGB,
                failed: summary.failed
            )
            speedMBps = 0
            etaSeconds = nil
            state = .done(summary: summary)

        case 130:
            // The script's on_interrupt() trap still prints a partial summary
            // before exiting — show it as a SummaryCard so the user sees their
            // progress instead of just a "Cancelled" label and log tail.
            if var summary = LogParser.parseSummary(from: logLines, destRoot: destRoot) {
                summary.wasCancelled = true
                speedMBps = 0
                etaSeconds = nil
                state = .done(summary: summary)
            } else {
                state = .cancelled
            }

        default:
            if case .failed = state { break }
            state = .failed(message: "Script exited with code \(exitCode). See log for details.")
        }
    }
}

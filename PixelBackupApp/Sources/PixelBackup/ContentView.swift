import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var backupManager: BackupManager

    @Environment(\.openWindow) private var openWindow

    @ObservedObject private var updateChecker = UpdateChecker.shared

    @State private var selectedSerial: String? = nil
    @AppStorage("destRootBase") private var destRootBase: String = "\(NSHomeDirectory())/Pictures/pixel_backup"
    @State private var folders: [RemoteFolder] = RemoteFolder.loadSaved()
    @State private var showHistory = false
    @State private var isDragTargeted = false
    @State private var lastBackupRecord: BackupRecord? = nil
    @State private var unfinishedForDevice: BackupRecord? = nil

    var body: some View {
        VStack(spacing: 12) {
            if let banner = updateChecker.banner {
                UpdateBannerView(
                    banner: banner,
                    onDismiss: { updateChecker.dismissCurrentBanner() },
                    onOpenRelease: { NSWorkspace.shared.open(banner.releaseURL) }
                )
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Group {
                if !deviceManager.adbAvailable {
                    SetupGuideView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    mainContent
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: updateChecker.banner)
        .toolbar {
            // ── Leading: new window / tab ─────────────────────────────────
            ToolbarItem(placement: .navigation) {
                Button {
                    openWindow(id: "main")
                } label: {
                    Label("New Window", systemImage: "plus")
                }
                .help("Open a new independent backup window (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            }


            // ── Trailing: History + Refresh ───────────────────────────────
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showHistory = true
                } label: {
                    Label("History", systemImage: "clock")
                }
                .help("View backup history")
                // Use popover so it always anchors to this button on the
                // correct screen, even in multi-display setups.
                .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                    BackupHistoryView(
                        destRootBase: destRootBase,
                        onContinue: { record in
                            startBackup(into: record.path)
                        }
                    )
                    .frame(minWidth: 540, minHeight: 380)
                }

                Button {
                    Task { await deviceManager.refresh() }
                } label: {
                    Label("Refresh Devices", systemImage: "arrow.clockwise")
                }
                .help("Refresh device list (⌘R)")
                .disabled(deviceManager.isRefreshing || backupManager.state.isRunning)
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if case .done(let summary) = backupManager.state {
            SummaryCard(summary: summary) {
                backupManager.state = .idle
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if backupManager.state.isRunning || backupManager.state.isTerminal {
            BackupProgressSection(
                state: backupManager.state,
                progress: backupManager.progress,
                scanFileCount: backupManager.scanFileCount,
                logLines: backupManager.logLines,
                hints: backupManager.hints,
                speedMBps: backupManager.speedMBps,
                etaSeconds: backupManager.etaSeconds,
                elapsedSeconds: backupManager.elapsedSeconds,
                currentFile: backupManager.currentFile,
                onCancel: { backupManager.cancel() },
                onPause: { backupManager.pause() },
                onResume: { backupManager.resume() },
                onNewBackup: { backupManager.state = .idle }
            )
            .padding()
        } else {
            configPanel
        }
    }

    // MARK: - Config panel

    private var configPanel: some View {
        VStack(alignment: .leading, spacing: 20) {

            // Device picker
            DeviceSectionView(
                devices: deviceManager.devices,
                selectedSerial: $selectedSerial,
                isRefreshing: deviceManager.isRefreshing,
                savedWirelessAddresses: deviceManager.savedWirelessAddresses,
                onConnect:    { addr        in await deviceManager.connect(address: addr) },
                onPair:       { addr, code  in await deviceManager.pair(address: addr, code: code) },
                onDisconnect: { serial      in await deviceManager.disconnect(serial: serial) }
            )

            // Folder selection
            FolderSelectionView(folders: $folders)
                .onChange(of: folders) { newFolders in
                    RemoteFolder.saveCurrent(newFolders)
                }

            // Destination
            DestinationPickerView(destRootBase: $destRootBase)

            if let unfinished = unfinishedForDevice {
                unfinishedBanner(unfinished)
            }

            Spacer()

            // Last backup summary strip
            lastBackupStrip

            // Start button
            HStack {
                if case .failed(let msg) = backupManager.state {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .lineLimit(2)
                }
                Spacer()
                let canStart = selectedSerial != nil && !folders.filter(\.enabled).isEmpty
                if unfinishedForDevice != nil {
                    Button {
                        startBackup(into: nil)   // today's new dated folder
                    } label: {
                        Label("Start New Today", systemImage: "calendar.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(!canStart)

                    Button {
                        if let path = unfinishedForDevice?.path {
                            startBackup(into: path)
                        }
                    } label: {
                        Label("Continue Unfinished", systemImage: "play.circle.fill")
                            .font(.body.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.large)
                    .disabled(!canStart)
                    .keyboardShortcut(.return, modifiers: .command)
                } else {
                    Button {
                        startBackup(into: nil)
                    } label: {
                        Label("Start Backup", systemImage: "arrow.down.circle.fill")
                            .font(.body.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canStart)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(24)
        // ── Window-level drag-and-drop ────────────────────────────────────
        .onDrop(of: [UTType.fileURL], isTargeted: $isDragTargeted, perform: acceptFolderDrop)
        .overlay {
            if isDragTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.blue.opacity(0.06))
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.blue, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                    Label("Drop folder here to set destination", systemImage: "folder.badge.plus")
                        .font(.title3.bold())
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isDragTargeted)
        .onAppear {
            loadLastBackup()
            refreshUnfinished()
        }
        .onChange(of: destRootBase) { _ in
            loadLastBackup()
            refreshUnfinished()
        }
        .onChange(of: selectedSerial) { _ in refreshUnfinished() }
    }

    @ViewBuilder
    private func unfinishedBanner(_ record: BackupRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Unfinished backup from \(record.month) \(record.day)")
                    .font(.subheadline.bold())
                Text("\(record.fileCount) files · \(record.sizeLabel) already copied. Continue into that folder instead of starting a new dated one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("History") { showHistory = true }
                .font(.caption)
                .buttonStyle(.borderless)
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Last backup strip

    @ViewBuilder
    private var lastBackupStrip: some View {
        if let rec = lastBackupRecord {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Last backup: **\(rec.month) \(rec.day)** · \(rec.fileCount) files · \(rec.sizeLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("View") { showHistory = true }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.blue)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func loadLastBackup() {
        let base = destRootBase
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let items = try? fm.contentsOfDirectory(atPath: base) else { return }
            let latest = items
                .filter { $0.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil }
                .sorted(by: >).first
            guard let name = latest else { return }
            let path = "\(base)/\(name)"
            var record = BackupRecord(folderName: name, path: path)
            let (count, bytes) = BackupFolderIndex.manifestStats(at: path)
            record.fileCount = count
            record.sizeBytes = bytes
            record.isIncomplete = BackupFolderIndex.looksIncomplete(at: path)
            let finalRecord = record
            await MainActor.run { lastBackupRecord = finalRecord }
        }
    }

    private func refreshUnfinished() {
        guard let serial = selectedSerial else {
            unfinishedForDevice = nil
            return
        }
        let base = destRootBase
        Task.detached(priority: .utility) {
            let found = BackupFolderIndex.resumeCandidate(in: base, matchingSerial: serial)
            await MainActor.run { unfinishedForDevice = found }
        }
    }

    private func acceptFolderDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSURL.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: NSURL.self) { reading, _ in
            guard let url = reading as? URL else { return }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue else { return }
            DispatchQueue.main.async { destRootBase = url.path }
        }
        return true
    }

    private func startBackup(into destRootOverride: String?) {
        guard let serial = selectedSerial else { return }
        backupManager.startBackup(
            serial: serial,
            adbPath: deviceManager.adbPath,
            destRootBase: destRootBase,
            folders: folders,
            destRootOverride: destRootOverride
        )
    }
}

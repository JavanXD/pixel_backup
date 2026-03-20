import Foundation

// MARK: - Device

struct AndroidDevice: Identifiable, Equatable {
    let serial: String
    var modelName: String
    var id: String { serial }
    var displayName: String { modelName.isEmpty ? serial : "\(modelName) (\(serial))" }
    /// TCP/IP serials look like "192.168.1.10:5555"; USB serials never contain a colon.
    var isWireless: Bool { serial.contains(":") }
}

// MARK: - Backup state machine

enum BackupState: Equatable {
    case idle
    case resolvingDevice
    case scanning(dir: String)
    case copying
    case retrying
    case finishing
    case done(summary: BackupSummary)
    case failed(message: String)
    case cancelled

    var isRunning: Bool {
        switch self {
        case .resolvingDevice, .scanning, .copying, .retrying, .finishing: return true
        default: return false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .cancelled, .failed: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .idle:                        return L10n("backup.state.ready")
        case .resolvingDevice:             return L10n("backup.state.connecting")
        case .scanning(let dir):           return L10n("backup.state.scanning",
                                                       (dir as NSString).lastPathComponent)
        case .copying:                     return L10n("backup.state.copying")
        case .retrying:                    return L10n("backup.state.retrying")
        case .finishing:                   return L10n("backup.state.finishing")
        case .done:                        return L10n("backup.state.done")
        case .failed(let msg):             return L10n("backup.state.failed", msg)
        case .cancelled:                   return L10n("backup.state.cancelled")
        }
    }
}

// MARK: - Progress

struct BackupProgress {
    var seen: Int = 0
    var copied: Int = 0
    var skipped: Int = 0
    var failed: Int = 0
    var copiedGB: Double = 0

    var fractionComplete: Double {
        guard seen > 0 else { return 0 }
        return Double(copied + skipped) / Double(seen)
    }
}

// MARK: - Summary

struct BackupSummary: Equatable {
    let runCopied: Int
    let runGB: Double
    let totalCopied: Int
    let totalGB: Double
    let failed: Int
    let destRoot: String
    let logPath: String
    let failedPath: String
    var wasCancelled: Bool = false
}

// MARK: - Log line

struct LogLine: Identifiable {
    let id = UUID()
    let raw: String
    let level: LogLevel
    let timestamp: String
    let body: String
}

enum LogLevel {
    case info, skip, copy, ok, fail, warn, hint, progress, fatal, error

    var color: String {
        switch self {
        case .ok:       return "green"
        case .fail:     return "red"
        case .fatal:    return "red"
        case .error:    return "red"
        case .warn:     return "orange"
        case .hint:     return "yellow"
        case .progress: return "blue"
        case .skip:     return "secondary"
        default:        return "primary"
        }
    }
}

// MARK: - Folder choice

struct RemoteFolder: Identifiable, Equatable {
    let id: String
    let displayName: String
    let remoteName: String   // path on device (relative, e.g. "DCIM", or absolute "/sdcard/MyDir")
    var enabled: Bool
    var isCustom: Bool = false

    // Built-in folders shown by default. Add new ones here; they're enabled unless
    // the user explicitly disables them (storage tracks disabled IDs, not enabled ones,
    // so new additions are automatically on for existing users too).
    static let builtInFolders: [RemoteFolder] = [
        RemoteFolder(id: "dcim",      displayName: "DCIM",      remoteName: "DCIM",      enabled: true),
        RemoteFolder(id: "pictures",  displayName: "Pictures",  remoteName: "Pictures",  enabled: true),
        RemoteFolder(id: "documents", displayName: "Documents", remoteName: "Documents", enabled: true),
        RemoteFolder(id: "download",  displayName: "Download",  remoteName: "Download",  enabled: true),
        RemoteFolder(id: "music",     displayName: "Music",     remoteName: "Music",     enabled: true),
        RemoteFolder(id: "backups",   displayName: "Backups",   remoteName: "Backups",   enabled: true),
        RemoteFolder(id: "movies",    displayName: "Movies",    remoteName: "Movies",    enabled: false),
    ]

    // IDs that existed before Music + Backups were added — used for one-time migration
    // of the old "enabledFolderIDs" storage format to the new "disabledFolderIDs" format.
    private static let legacyBuiltInIDs: Set<String> = ["dcim", "pictures", "movies", "download"]

    static func loadSaved() -> [RemoteFolder] {
        let ud = UserDefaults.standard

        // ── One-time migration from old enabledFolderIDs → disabledFolderIDs ──
        if let oldEnabled = ud.stringArray(forKey: "enabledFolderIDs"),
           ud.object(forKey: "folderPrefsVersion") == nil {
            // Only carry the disabled state for folders that existed before;
            // newly added built-ins (Music, Backups) stay at their default (enabled).
            let disabled = legacyBuiltInIDs.filter { !oldEnabled.contains($0) }
            ud.set(Array(disabled), forKey: "disabledFolderIDs")
            ud.removeObject(forKey: "enabledFolderIDs")
            ud.set(1, forKey: "folderPrefsVersion")
        }

        let disabledIDs = Set(ud.stringArray(forKey: "disabledFolderIDs") ?? [])

        var result = builtInFolders.map { folder -> RemoteFolder in
            var f = folder
            f.enabled = !disabledIDs.contains(folder.id)
            return f
        }

        // Append user-defined custom folders
        let customPaths = ud.stringArray(forKey: "customFolderPaths") ?? []
        for path in customPaths {
            let fid = "custom_\(path)"
            result.append(RemoteFolder(
                id: fid,
                displayName: (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent,
                remoteName: path,
                enabled: !disabledIDs.contains(fid),
                isCustom: true
            ))
        }
        return result
    }

    static func saveCurrent(_ folders: [RemoteFolder]) {
        let ud = UserDefaults.standard
        ud.set(1, forKey: "folderPrefsVersion")

        // Store disabled IDs so newly added built-ins default to enabled automatically
        let disabledIDs = folders.filter { !$0.enabled }.map(\.id)
        ud.set(disabledIDs, forKey: "disabledFolderIDs")

        // Store custom folder remote paths
        let customPaths = folders.filter(\.isCustom).map(\.remoteName)
        ud.set(customPaths, forKey: "customFolderPaths")
    }

    // Legacy aliases
    static var allFolders:  [RemoteFolder] { loadSaved() }
    static var defaults:    [RemoteFolder] { loadSaved() }
}

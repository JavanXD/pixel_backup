import Foundation

/// Shared helpers for dated backup folders under DEST_ROOT_BASE.
enum BackupFolderIndex {

    /// Match shell `sanitize_name()` closely enough for serial suffix matching.
    static func sanitizeForPath(_ raw: String) -> String {
        let ascii = raw.unicodeScalars
            .filter { $0.value >= 0x20 && $0.value <= 0x7E }
            .map(Character.init)
        var result = String(ascii)
        // Replace runs of non [A-Za-z0-9._-] with _
        let pattern = "[^A-Za-z0-9._-]+"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "_")
        }
        while result.contains("__") { result = result.replacingOccurrences(of: "__", with: "_") }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if result.count > 64 { result = String(result.prefix(64)) }
        return result.isEmpty ? "unknown_device" : result
    }

    /// Dated folders for a device serial, newest first (`YYYY-MM-DD_…_Serial`).
    static func folders(in destRootBase: String, matchingSerial serial: String) -> [BackupRecord] {
        let safe = sanitizeForPath(serial)
        let suffix = "_\(safe)"
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: destRootBase) else { return [] }

        return items
            .filter { $0.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil }
            .filter { $0.hasSuffix(suffix) }
            .sorted(by: >)
            .map { name -> BackupRecord in
                let path = "\(destRootBase)/\(name)"
                var record = BackupRecord(folderName: name, path: path)
                let (count, bytes) = manifestStats(at: path)
                record.fileCount = count
                record.sizeBytes = bytes
                record.isIncomplete = looksIncomplete(at: path)
                return record
            }
    }

    /// Newest unfinished backup for this serial, if any.
    static func latestIncomplete(in destRootBase: String, matchingSerial serial: String) -> BackupRecord? {
        folders(in: destRootBase, matchingSerial: serial).first(where: \.isIncomplete)
    }

    /// Folder the UI should offer to continue into: explicit unfinished, or a legacy
    /// pre-status folder from a previous day (hard crashes left no PAUSED/FATAL marker).
    static func resumeCandidate(in destRootBase: String, matchingSerial serial: String) -> BackupRecord? {
        let all = folders(in: destRootBase, matchingSerial: serial)
        if let unfinished = all.first(where: \.isIncomplete) {
            return unfinished
        }
        guard let latest = all.first else { return nil }
        if hasCompleteStatus(at: latest.path) { return nil }
        // No run_status=complete and folder is not from today → offer continue
        // (covers hard kills that left a partial tree with a quiet log tail).
        guard !folderDateIsToday(latest.folderName) else { return nil }
        var candidate = latest
        candidate.isIncomplete = true
        return candidate
    }

    static func hasCompleteStatus(at path: String) -> Bool {
        let statusPath = "\(path)/.transfer_meta/run_status"
        guard let raw = try? String(contentsOfFile: statusPath, encoding: .utf8) else { return false }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines) == "complete"
    }

    static func folderDateIsToday(_ folderName: String) -> Bool {
        guard folderName.count >= 10 else { return false }
        let prefix = String(folderName.prefix(10))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return prefix == formatter.string(from: Date())
    }

    static func looksIncomplete(at path: String) -> Bool {
        let meta = "\(path)/.transfer_meta"
        let statusPath = "\(meta)/run_status"
        if let raw = try? String(contentsOfFile: statusPath, encoding: .utf8) {
            let status = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !status.isEmpty {
                return status != "complete"
            }
        }

        let logPath = "\(meta)/transfer.log"
        guard let log = try? String(contentsOfFile: logPath, encoding: .utf8), !log.isEmpty else {
            // No status and no log: only treat as incomplete if a manifest already has progress
            // (crashed before logging) — rare; prefer not to flag finished folders.
            return false
        }

        let lines = log.split(separator: "\n", omittingEmptySubsequences: true)
        let tail = lines.suffix(120).joined(separator: "\n")
        for marker in [
            "PAUSED",
            "INTERRUPTED",
            "FATAL ",
            "ERROR Script aborted",
            "critically low",
            "not enough free space",
            "Aborting to avoid",
            "Aborting: not enough free space",
        ] {
            if tail.localizedCaseInsensitiveContains(marker) { return true }
        }
        return false
    }

    static func manifestStats(at path: String) -> (Int, Int64) {
        let manifestPath = "\(path)/.transfer_meta/manifest.tsv"
        if let content = try? String(contentsOfFile: manifestPath, encoding: .utf8) {
            let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
            var bytes: Int64 = 0
            for line in lines {
                bytes += Int64(line.prefix(while: { $0 != "\t" })) ?? 0
            }
            return (lines.count, bytes)
        }
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(atPath: path))?
            .filter { !$0.hasPrefix(".") } ?? []
        return (children.count, 0)
    }
}

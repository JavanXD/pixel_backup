import Foundation

// Parses structured log lines emitted by pixel_backup.sh
// Format: [YYYY-MM-DD HH:MM:SS] LEVEL  body
struct LogParser {

    // MARK: - Public entry point

    static func parse(_ raw: String) -> LogLine {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let (ts, rest) = splitTimestamp(trimmed)
        let (level, body) = classifyLine(rest)
        return LogLine(raw: trimmed, level: level, timestamp: ts, body: body)
    }

    // MARK: - PROGRESS line
    // e.g. "PROGRESS seen=400 copied=312 skipped=82 failed=6 copied_gb=3.21"

    static func parseProgress(_ line: LogLine) -> BackupProgress? {
        guard line.level == .progress else { return nil }
        var p = BackupProgress()
        p.seen     = intField("seen",       in: line.body) ?? 0
        p.copied   = intField("copied",     in: line.body) ?? 0
        p.skipped  = intField("skipped",    in: line.body) ?? 0
        p.failed   = intField("failed",     in: line.body) ?? 0
        p.copiedGB = doubleField("copied_gb", in: line.body) ?? 0
        return p
    }

    // MARK: - Scan complete
    // e.g. "Scan complete: 4821 files found in /sdcard/DCIM"

    static func parseScanComplete(_ line: LogLine) -> (count: Int, dir: String)? {
        guard line.body.hasPrefix("Scan complete:") else { return nil }
        let pattern = #"Scan complete:\s+(\d+)\s+files found in\s+(.+)"#
        guard let m = line.body.firstMatch(pattern: pattern, groups: 2) else { return nil }
        guard let count = Int(m[0]) else { return nil }
        return (count, m[1])
    }

    // MARK: - Summary extraction
    // Matches the multi-line summary block at the end of a run

    static func parseSummary(from lines: [LogLine], destRoot: String) -> BackupSummary? {
        let bodies = lines.map(\.body)
        func valueAfterColon(_ prefix: String) -> String? {
            bodies.first { $0.hasPrefix(prefix) }
                  .flatMap { $0.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) }
        }

        guard
            let runLine = bodies.first(where: { $0.hasPrefix("Copied this run") }),
            let totalLine = bodies.first(where: { $0.hasPrefix("Copied total") })
        else { return nil }

        let failed    = intField("Failed files", colonDelimited: bodies) ?? 0
        let logPath   = valueAfterColon("Log          :") ?? ""
        let failPath  = valueAfterColon("Failures     :") ?? ""

        let (runCopied, runGB)     = parseCountGB(runLine)
        let (totalCopied, totalGB) = parseCountGB(totalLine)

        return BackupSummary(
            runCopied: runCopied, runGB: runGB,
            totalCopied: totalCopied, totalGB: totalGB,
            failed: failed,
            destRoot: destRoot,
            logPath: logPath,
            failedPath: failPath
        )
    }

    // MARK: - Scanning dir detection
    // "Scanning /sdcard/DCIM (building file list..."

    static func parseScanningDir(_ line: LogLine) -> String? {
        guard line.body.hasPrefix("Scanning ") else { return nil }
        let after = String(line.body.dropFirst("Scanning ".count))
        return after.components(separatedBy: " (").first
    }

    // MARK: - Private helpers

    private static func splitTimestamp(_ raw: String) -> (String, String) {
        guard raw.hasPrefix("[") else { return ("", raw) }
        let pattern = #"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]\s*(.*)"#
        guard let m = raw.firstMatch(pattern: pattern, groups: 2) else { return ("", raw) }
        return (m[0], m[1])
    }

    private static func classifyLine(_ text: String) -> (LogLevel, String) {
        let prefixes: [(String, LogLevel)] = [
            ("PROGRESS ",   .progress),
            ("FATAL ",      .fatal),
            ("ERROR ",      .error),
            ("HINT  ",      .hint),
            ("WARN  ",      .warn),
            ("OK    ",      .ok),
            ("COPY  ",      .copy),
            ("SKIP  ",      .skip),
            ("FAIL  ",      .fail),
            ("BADSIZE ",    .fail),
        ]
        for (prefix, level) in prefixes {
            if text.hasPrefix(prefix) {
                return (level, String(text.dropFirst(prefix.count)))
            }
        }
        return (.info, text)
    }

    private static func intField(_ key: String, in text: String) -> Int? {
        let pattern = "\(key)=(\\d+)"
        return text.firstMatch(pattern: pattern, groups: 1).flatMap { Int($0[0]) }
    }

    private static func doubleField(_ key: String, in text: String) -> Double? {
        let pattern = "\(key)=([\\d.]+)"
        return text.firstMatch(pattern: pattern, groups: 1).flatMap { Double($0[0]) }
    }

    private static func intField(_ prefix: String, colonDelimited lines: [String]) -> Int? {
        lines.first { $0.hasPrefix(prefix) }
             .flatMap { $0.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) }
             .flatMap { Int($0) }
    }

    // "Copied this run : 312 files (3.21 GB)" -> (312, 3.21)
    private static func parseCountGB(_ line: String) -> (Int, Double) {
        let pattern = #":\s*(\d+)\s+files?\s+\(([\d.]+)\s+GB\)"#
        guard let m = line.firstMatch(pattern: pattern, groups: 2),
              let count = Int(m[0]), let gb = Double(m[1]) else { return (0, 0) }
        return (count, gb)
    }
}

// MARK: - String regex helper

private extension String {
    func firstMatch(pattern: String, groups: Int) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(self.startIndex..., in: self))
        else { return nil }
        return (1...groups).map { i -> String in
            let range = match.range(at: i)
            guard range.location != NSNotFound,
                  let r = Range(range, in: self) else { return "" }
            return String(self[r])
        }
    }
}

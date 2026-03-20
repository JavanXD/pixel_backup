import SwiftUI

struct LogView: View {
    let lines: [LogLine]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines) { line in
                        logRow(line)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onChange(of: lines.count) { newCount in
                if let last = lines.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func logRow(_ line: LogLine) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if !line.timestamp.isEmpty {
                Text(shortTime(line.timestamp))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 50, alignment: .leading)
            }
            Text(levelBadge(line.level))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(levelColor(line.level))
                .frame(width: 52, alignment: .leading)
            Text(line.body)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(levelColor(line.level))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
    }

    private func shortTime(_ ts: String) -> String {
        // "2026-03-19 10:35:12" -> "10:35:12"
        ts.components(separatedBy: " ").last ?? ts
    }

    private func levelBadge(_ level: LogLevel) -> String {
        switch level {
        case .ok:       return "OK"
        case .copy:     return "COPY"
        case .skip:     return "SKIP"
        case .fail:     return "FAIL"
        case .warn:     return "WARN"
        case .hint:     return "HINT"
        case .progress: return "PROGRESS"
        case .fatal:    return "FATAL"
        case .error:    return "ERROR"
        default:        return ""
        }
    }

    private func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .ok:       return .green
        case .fail, .fatal, .error: return .red
        case .warn:     return .orange
        case .hint:     return colorScheme == .dark
                            ? Color(hue: 0.12, saturation: 0.95, brightness: 0.95)   // bright amber on dark
                            : Color(hue: 0.12, saturation: 0.90, brightness: 0.45)   // deep amber on light
        case .progress: return .blue
        case .skip:     return .secondary
        default:        return .primary
        }
    }
}

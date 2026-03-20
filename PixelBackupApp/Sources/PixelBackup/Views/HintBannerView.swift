import SwiftUI

struct HintBannerView: View {
    let hints: [String]
    @State private var dismissed: Set<Int> = []

    private var visible: [(Int, String)] {
        hints.enumerated().filter { !dismissed.contains($0.offset) }.suffix(3)
            .map { ($0.offset, $0.element) }
    }

    var body: some View {
        if !visible.isEmpty {
            VStack(spacing: 6) {
                ForEach(visible, id: \.0) { idx, hint in
                    hintRow(idx: idx, text: hint)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: hints.count)
        }
    }

    private func hintRow(idx: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconFor(text))
                .foregroundStyle(colorFor(text))
                .font(.caption)
                .padding(.top, 2)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                withAnimation { _ = dismissed.insert(idx) }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(backgroundFor(text), in: RoundedRectangle(cornerRadius: 7))
    }

    private func iconFor(_ text: String) -> String {
        if text.lowercased().contains("lock")   { return "lock.fill" }
        if text.lowercased().contains("usb")    { return "cable.connector" }
        if text.lowercased().contains("disk") || text.lowercased().contains("space") { return "internaldrive" }
        if text.lowercased().contains("fail")   { return "exclamationmark.triangle.fill" }
        return "info.circle.fill"
    }

    private func colorFor(_ text: String) -> Color {
        if text.lowercased().contains("fail") || text.lowercased().contains("critical") { return .red }
        if text.lowercased().contains("lock") || text.lowercased().contains("disk")     { return .orange }
        return .blue
    }

    private func backgroundFor(_ text: String) -> Color {
        colorFor(text).opacity(0.08)
    }
}

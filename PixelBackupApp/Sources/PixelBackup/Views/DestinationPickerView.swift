import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DestinationPickerView: View {
    @Binding var destRootBase: String
    @State private var isDropTargeted = false
    @State private var freeBytes: Int64 = -1   // -1 = unknown

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Save to", systemImage: "externaldrive")
                    .font(.headline)
                Spacer()
                if freeBytes >= 0 {
                    Label(freeBytesLabel, systemImage: freeBytesSFSymbol)
                        .font(.caption)
                        .foregroundStyle(freeBytesColor)
                }
            }

            HStack {
                Image(systemName: isDropTargeted ? "folder.badge.plus" : "folder")
                    .foregroundStyle(isDropTargeted ? .blue : .secondary)
                    .font(.body)
                    .animation(.easeInOut(duration: 0.15), value: isDropTargeted)

                Text(destRootBase.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.body.monospaced())
                    .foregroundStyle(isDropTargeted ? .blue : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Choose…") { pickFolder() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(10)
            .background(
                isDropTargeted
                    ? Color.blue.opacity(0.08)
                    : Color(nsColor: .quaternaryLabelColor).opacity(0.3),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isDropTargeted ? Color.blue : Color.clear, lineWidth: 1.5)
            )
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: acceptDrop)
            .animation(.easeInOut(duration: 0.15), value: isDropTargeted)

            Text("Drag a folder here or use Choose. Each backup is saved in a dated subfolder: YYYY-MM-DD_DeviceName_Serial/")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { refreshFreeSpace() }
        .onChange(of: destRootBase) { _ in refreshFreeSpace() }
    }

    // MARK: - Free space

    private func refreshFreeSpace() {
        DispatchQueue.global(qos: .utility).async {
            // Create the folder if it doesn't exist yet so we can query it
            try? FileManager.default.createDirectory(atPath: destRootBase,
                                                     withIntermediateDirectories: true)
            let attrs = try? FileManager.default.attributesOfFileSystem(forPath: destRootBase)
            let free = (attrs?[.systemFreeSize] as? Int64) ?? -1
            DispatchQueue.main.async { freeBytes = free }
        }
    }

    private var freeBytesLabel: String {
        guard freeBytes >= 0 else { return "" }
        let gb = Double(freeBytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.0f GB free", gb) }
        let mb = Double(freeBytes) / 1_048_576
        return String(format: "%.0f MB free", mb)
    }

    private var freeBytesSFSymbol: String {
        guard freeBytes >= 0 else { return "internaldrive" }
        let gb = Double(freeBytes) / 1_073_741_824
        if gb < 5  { return "exclamationmark.triangle.fill" }
        if gb < 20 { return "exclamationmark.triangle" }
        return "checkmark.circle"
    }

    private var freeBytesColor: Color {
        guard freeBytes >= 0 else { return .secondary }
        let gb = Double(freeBytes) / 1_073_741_824
        if gb < 5  { return .red }
        if gb < 20 { return .orange }
        return .secondary
    }

    // MARK: - Helpers

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Select Destination"
        panel.message = "Choose the base folder for backups"
        if panel.runModal() == .OK, let url = panel.url {
            destRootBase = url.path
        }
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
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
}

import SwiftUI

struct FolderSelectionView: View {
    @Binding var folders: [RemoteFolder]

    @State private var showAddField = false
    @State private var newFolderPath = ""
    @FocusState private var addFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Copy from", systemImage: "folder")
                .font(.headline)

            // ── Built-in folder toggles ───────────────────────────────────
            HStack(spacing: 6) {
                ForEach(folders.indices, id: \.self) { idx in
                    if !folders[idx].isCustom {
                        Toggle(folders[idx].displayName, isOn: $folders[idx].enabled)
                            .toggleStyle(.button)
                            .controlSize(.small)
                            .tint(.blue)
                    }
                }
            }

            // ── Custom folder pills + Add button ──────────────────────────
            HStack(spacing: 6) {
                ForEach(folders.indices, id: \.self) { idx in
                    if folders[idx].isCustom {
                        customPill(idx: idx)
                    }
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showAddField.toggle()
                        newFolderPath = ""
                    }
                    if showAddField { addFieldFocused = true }
                } label: {
                    Label(showAddField ? "Cancel" : "Add folder",
                          systemImage: showAddField ? "xmark" : "plus")
                        .font(.caption)
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }

            // ── Inline add-folder form ────────────────────────────────────
            if showAddField {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                        .foregroundStyle(.blue)
                        .font(.caption)
                    TextField("e.g. Music  or  /sdcard/MyFolder", text: $newFolderPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .focused($addFieldFocused)
                        .onSubmit { commitNewFolder() }
                    Button("Add") { commitNewFolder() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(newFolderPath.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if folders.filter(\.enabled).isEmpty {
                Label("Select at least one folder to copy.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Custom pill

    @ViewBuilder
    private func customPill(idx: Int) -> some View {
        let folder = folders[idx]
        HStack(spacing: 0) {
            Toggle(folder.displayName, isOn: $folders[idx].enabled)
                .toggleStyle(.button)
                .controlSize(.small)
                .tint(.purple)

            Button {
                let fid = folder.id
                withAnimation { folders.removeAll { $0.id == fid } }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .help("Remove \(folder.displayName)")
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.purple.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Add folder

    private func commitNewFolder() {
        let raw = newFolderPath.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }

        let last = (raw as NSString).lastPathComponent
        let displayName = last.isEmpty ? raw : last
        let fid = "custom_\(raw)"

        guard !folders.contains(where: { $0.id == fid }) else {
            newFolderPath = ""
            showAddField = false
            return
        }

        withAnimation {
            folders.append(RemoteFolder(
                id: fid,
                displayName: displayName,
                remoteName: raw,
                enabled: true,
                isCustom: true
            ))
        }
        newFolderPath = ""
        showAddField = false
    }
}

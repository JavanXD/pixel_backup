import SwiftUI

struct UpdateBannerView: View {
    let banner: UpdateChecker.BannerState
    let onDismiss: () -> Void
    let onOpenRelease: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 18, weight: .semibold))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Update available: \(banner.latestVersion)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("You're on \(banner.currentVersion).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            Button {
                onOpenRelease()
            } label: {
                Label("Release notes", systemImage: "arrowshape.turn.up.right")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss update banner")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.blue.opacity(0.28), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}


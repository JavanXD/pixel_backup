import SwiftUI

/// Sheet for the Wireless Debugging pairing flow.
///
/// The flow requires two steps:
///  1. `adb pair <pairingAddress> <code>` — one-time pairing using the code shown
///     in the "Pair device with pairing code" dialog on the phone.
///  2. `adb connect <connectAddress>` — ongoing connection using the IP:port shown
///     in the main Wireless debugging screen (different port from the pairing dialog).
struct WirelessPairingSheet: View {

    @Binding var isPresented: Bool
    let onPair:    (String, String) async -> Bool
    let onConnect: (String) async -> String?

    @State private var pairingAddress = ""
    @State private var pairingCode    = ""
    @State private var connectAddress = ""

    @State private var phase: Phase = .idle
    @State private var errorMessage: String? = nil

    private enum Phase { case idle, pairing, connecting }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ────────────────────────────────────────────────────────
            HStack {
                Image(systemName: "wifi").font(.title3).foregroundStyle(.blue)
                Text("Pair Wireless Device").font(.title3.bold())
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary).font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 16)

            // ── Step 1 ────────────────────────────────────────────────────────
            stepLabel(number: "1", title: "On your Pixel, open Wireless debugging")
            Text("Settings → Developer options → Wireless debugging → Pair device with pairing code")
                .font(.caption.monospaced())
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                .padding(.top, 4).padding(.bottom, 10)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pairing address").font(.caption.bold()).foregroundStyle(.secondary)
                    TextField("192.168.1.10:37159", text: $pairingAddress)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("6-digit code").font(.caption.bold()).foregroundStyle(.secondary)
                    TextField("123 456", text: $pairingCode)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 90)
                }
            }
            .padding(.bottom, 16)

            Divider().padding(.bottom, 16)

            // ── Step 2 ────────────────────────────────────────────────────────
            stepLabel(number: "2", title: "Enter the connection address")
            Text("Use the IP:port shown on the main Wireless debugging screen (not the pairing dialog).")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 2).padding(.bottom, 8)

            TextField("192.168.1.10:39513", text: $connectAddress)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .padding(.bottom, 16)

            // ── Error ─────────────────────────────────────────────────────────
            if let err = errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
            }

            // ── Actions ───────────────────────────────────────────────────────
            HStack {
                Button("Cancel") { isPresented = false }.buttonStyle(.bordered)
                Spacer()
                Button {
                    Task { await pairAndConnect() }
                } label: {
                    if phase == .pairing || phase == .connecting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(phase == .pairing ? "Pairing…" : "Connecting…")
                        }
                    } else {
                        Label("Pair & Connect", systemImage: "wifi")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    pairingAddress.trimmingCharacters(in: .whitespaces).isEmpty ||
                    pairingCode.trimmingCharacters(in: .whitespaces).isEmpty    ||
                    connectAddress.trimmingCharacters(in: .whitespaces).isEmpty  ||
                    phase != .idle
                )
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func stepLabel(number: String, title: String) -> some View {
        HStack(spacing: 8) {
            Text(number)
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(.blue, in: Circle())
            Text(title).font(.subheadline.bold())
        }
        .padding(.bottom, 4)
    }

    // MARK: - Logic

    private func pairAndConnect() async {
        errorMessage = nil
        phase = .pairing

        let paired = await onPair(
            pairingAddress.trimmingCharacters(in: .whitespaces),
            pairingCode.trimmingCharacters(in: .whitespaces)
        )
        guard paired else {
            errorMessage = "Pairing failed — check that the address and code are correct and try again."
            phase = .idle
            return
        }

        phase = .connecting
        let serial = await onConnect(connectAddress.trimmingCharacters(in: .whitespaces))
        guard serial != nil else {
            errorMessage = "Paired successfully but could not connect — check the connection address."
            phase = .idle
            return
        }

        isPresented = false
    }

}

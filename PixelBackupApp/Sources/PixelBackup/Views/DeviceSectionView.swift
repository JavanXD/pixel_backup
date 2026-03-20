import SwiftUI

struct DeviceSectionView: View {
    let devices: [AndroidDevice]
    @Binding var selectedSerial: String?
    let isRefreshing: Bool
    let savedWirelessAddresses: [String]
    let onConnect:    (String) async -> String?
    let onPair:       (String, String) async -> Bool
    let onDisconnect: (String) async -> Void

    @State private var showGuide          = false
    @State private var showWireless       = false
    @State private var wirelessInput      = ""
    @State private var isConnecting       = false
    @State private var connectError:  String? = nil
    @State private var showPairingSheet   = false

    // Saved addresses that are not currently in the online device list.
    private var offlineAddresses: [String] {
        let online = Set(devices.map(\.serial))
        return savedWirelessAddresses.filter { !online.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            Label("Device", systemImage: "iphone")
                .font(.headline)

            // ── Main device list ──────────────────────────────────────────────
            if isRefreshing && devices.isEmpty && savedWirelessAddresses.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Looking for devices…").foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            } else if devices.isEmpty && offlineAddresses.isEmpty {
                noDeviceView

            } else {
                VStack(spacing: 4) {
                    ForEach(devices) { device in
                        deviceRow(device)
                    }
                    ForEach(offlineAddresses, id: \.self) { addr in
                        offlineRow(addr)
                    }
                }
            }

            // USB mode reminder — only relevant when a USB device is present
            if devices.contains(where: { !$0.isWireless }) {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Phone USB mode should be set to **File Transfer**, not Charging.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // ── Connect wirelessly ────────────────────────────────────────────
            wirelessConnectSection
        }
        .onAppear {
            if selectedSerial == nil, let first = devices.first {
                selectedSerial = first.serial
            }
        }
        .onChange(of: devices) { newDevices in
            if let serial = selectedSerial, !newDevices.map(\.serial).contains(serial) {
                selectedSerial = newDevices.first?.serial
            }
            if selectedSerial == nil {
                selectedSerial = newDevices.first?.serial
            }
        }
        .sheet(isPresented: $showPairingSheet) {
            WirelessPairingSheet(
                isPresented: $showPairingSheet,
                onPair:    onPair,
                onConnect: onConnect
            )
        }
    }

    // MARK: - "No device detected" view

    private var noDeviceView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Banner row
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No device detected")
                        .font(.subheadline.bold())
                    Text("Connect via USB or wirelessly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showGuide.toggle() }
                } label: {
                    Label(showGuide ? "Hide USB guide" : "Show USB guide",
                          systemImage: showGuide ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
            }
            .padding(12)

            // Expandable USB guide
            if showGuide {
                Divider().padding(.horizontal, 12)
                VStack(alignment: .leading, spacing: 10) {
                    usbStep(1, sf: "gear",
                            title: "Open Settings on your Pixel",
                            detail: "Go to Settings → About phone.")
                    usbStep(2, sf: "hand.tap",
                            title: "Tap \"Build number\" 7 times",
                            detail: "A toast will say \"You are now a developer!\" This unlocks Developer options.")
                    usbStep(3, sf: "hammer",
                            title: "Enable USB debugging",
                            detail: "Settings → System → Developer options → turn on USB debugging.")
                    usbStep(4, sf: "cable.connector",
                            title: "Plug in the USB cable",
                            detail: "Use the cable that came with your phone or a quality data cable (not charge-only).")
                    usbStep(5, sf: "arrow.up.arrow.down",
                            title: "Select \"File Transfer\" mode",
                            detail: "When the notification appears on the phone, tap it and choose File Transfer (MTP), not Charging or PTP.")
                    usbStep(6, sf: "checkmark.shield",
                            title: "Allow USB debugging prompt",
                            detail: "A dialog will appear on the phone asking to trust this Mac. Tap Allow (tick \"Always allow\" to skip next time).")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.orange.opacity(0.3)))
    }

    // MARK: - Device row

    private func deviceRow(_ device: AndroidDevice) -> some View {
        let selected = selectedSerial == device.serial
        return HStack {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? .blue : .secondary)

            Image(systemName: device.isWireless ? "wifi" : "cable.connector")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(device.modelName.isEmpty ? "Android Device" : device.modelName)
                    .font(.subheadline.bold())
                Text(device.serial)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if device.isWireless {
                Button {
                    Task { await onDisconnect(device.serial) }
                } label: {
                    Text("Disconnect")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(selected ? .blue.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.blue.opacity(0.4) : Color(nsColor: .separatorColor).opacity(0.5))
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedSerial = device.serial }
    }

    // MARK: - Offline wireless row

    private func offlineRow(_ address: String) -> some View {
        HStack {
            Image(systemName: "wifi.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(address)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("Offline — reconnecting…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                Task { await onDisconnect(address) }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove saved address")
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.4))
        )
    }

    // MARK: - Connect wirelessly section

    private var wirelessConnectSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toggle header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showWireless.toggle()
                    if !showWireless { connectError = nil }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wifi").font(.caption2).foregroundStyle(.blue)
                    Text("Connect wirelessly")
                        .font(.caption.bold()).foregroundStyle(.blue)
                    Spacer()
                    Image(systemName: showWireless ? "chevron.up" : "chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if showWireless {
                Divider().padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 6) {
                    // IP field + Connect inline
                    HStack(spacing: 8) {
                        TextField("192.168.1.10", text: $wirelessInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onSubmit { attemptConnect() }

                        Button {
                            attemptConnect()
                        } label: {
                            if isConnecting {
                                ProgressView().controlSize(.small)
                                    .frame(width: 52)
                            } else {
                                Text("Connect").frame(width: 52)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(wirelessInput.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
                    }

                    // Error (only when present)
                    if let err = connectError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red)
                    }

                    // Pairing link — secondary, tucked below
                    Button("First time? Pair a new device…") {
                        showPairingSheet = true
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
        .background(.blue.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.blue.opacity(0.2)))
    }

    // MARK: - Actions

    private func attemptConnect() {
        let input = wirelessInput.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }
        isConnecting = true
        connectError = nil
        Task {
            let result = await onConnect(input)
            isConnecting = false
            if result != nil {
                wirelessInput = ""
                connectError  = nil
                withAnimation { showWireless = false }
            } else {
                connectError = "Could not connect — check the IP address and ensure Wireless Debugging (or USB debugging with adb tcpip 5555) is enabled on the phone."
            }
        }
    }

    // MARK: - USB guide helper

    private func usbStep(_ n: Int, sf: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(.orange.opacity(0.15)).frame(width: 26, height: 26)
                Image(systemName: sf)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(n). \(title)").font(.caption.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

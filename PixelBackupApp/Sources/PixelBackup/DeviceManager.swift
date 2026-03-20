import Foundation
import Combine

@MainActor
final class DeviceManager: ObservableObject {
    @Published var devices: [AndroidDevice] = []
    @Published var isRefreshing = false
    @Published var adbAvailable = false
    @Published var adbPath: String = ""

    /// Saved IP:port addresses that are auto-reconnected on every poll cycle.
    @Published var savedWirelessAddresses: [String] = []

    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 4
    private static let wirelessAddressesKey = "wirelessAddresses"

    init() {
        savedWirelessAddresses = UserDefaults.standard
            .stringArray(forKey: Self.wirelessAddressesKey) ?? []
        Task { await resolveAdb() }
    }

    // MARK: - ADB resolution
    // Priority: bundled adb in app resources -> Homebrew (Apple Silicon) -> Homebrew (Intel) -> PATH

    func resolveAdb() async {
        let candidates: [String] = [
            bundledAdbPath(),
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/usr/bin/adb",
        ].compactMap { $0 }

        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                adbPath = candidate
                adbAvailable = true
                await ensureExecutable(candidate)
                await poll()
                startAutoRefresh()
                return
            }
        }
        adbAvailable = false
    }

    private func bundledAdbPath() -> String? {
        Bundle.module.url(forResource: "adb", withExtension: nil)?.path
    }

    private func ensureExecutable(_ path: String) async {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let perms = attrs?[.posixPermissions] as? Int ?? 0
        guard perms & 0o111 == 0 else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    // MARK: - Device refresh

    /// User-initiated refresh: shows the spinner and disables the toolbar button.
    func refresh() async {
        guard adbAvailable else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await poll()
    }

    /// Silent background poll: reconnects saved wireless addresses, then updates
    /// `devices` only when the list actually changes.
    private func poll() async {
        // Silently attempt to reconnect any saved addresses not currently online.
        if !savedWirelessAddresses.isEmpty {
            let online = Set(await runAdbDevices())
            for addr in savedWirelessAddresses where !online.contains(addr) {
                _ = await shell(adbPath, args: ["connect", addr])
            }
        }

        let serials = await runAdbDevices()
        var updated: [AndroidDevice] = []
        for serial in serials {
            let model = await fetchModelName(serial: serial)
            updated.append(AndroidDevice(serial: serial, modelName: model))
        }
        if updated != devices {
            devices = updated
        }
    }

    private func runAdbDevices() async -> [String] {
        guard let output = await shell(adbPath, args: ["devices"]) else { return [] }
        return output.split(separator: "\n")
            .dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasSuffix("\tdevice") }
            .map { String($0.split(separator: "\t").first ?? "") }
            .filter { !$0.isEmpty }
    }

    private func fetchModelName(serial: String) async -> String {
        let raw = await shell(adbPath, args: ["-s", serial, "shell", "getprop", "ro.product.model"])
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Wireless connect / pair / disconnect

    /// Appends `:5555` if the user typed a bare IP address without a port.
    func normaliseAddress(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        return s.contains(":") ? s : "\(s):5555"
    }

    /// Runs `adb connect <address>` and returns the normalised serial on success, nil on failure.
    /// On success the address is persisted and will be auto-reconnected on future poll cycles.
    func connect(address: String) async -> String? {
        let addr = normaliseAddress(address)
        guard let output = await shell(adbPath, args: ["connect", addr]) else { return nil }
        let success = output.contains("connected to") || output.contains("already connected")
        guard success else { return nil }
        if !savedWirelessAddresses.contains(addr) {
            savedWirelessAddresses.append(addr)
            persistAddresses()
        }
        await poll()
        return addr
    }

    /// Runs `adb pair <address> <code>` for Wireless Debugging pairing.
    func pair(address: String, code: String) async -> Bool {
        let addr = address.trimmingCharacters(in: .whitespaces)
        let c    = code.trimmingCharacters(in: .whitespaces)
        guard let output = await shell(adbPath, args: ["pair", addr, c]) else { return false }
        return output.contains("Successfully paired")
    }

    /// Disconnects a wireless device and removes it from the saved-addresses list.
    func disconnect(serial: String) async {
        _ = await shell(adbPath, args: ["disconnect", serial])
        savedWirelessAddresses.removeAll { $0 == serial }
        persistAddresses()
        await poll()
    }

    private func persistAddresses() {
        UserDefaults.standard.set(savedWirelessAddresses, forKey: Self.wirelessAddressesKey)
    }

    // MARK: - Auto-refresh timer

    func startAutoRefresh() {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.poll() }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Helpers

    private func shell(_ executable: String, args: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                process.standardInput = FileHandle.nullDevice
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

import Foundation
import SystemConfiguration

/// Watches the default network and decides whether BLEUnlock should be paused on the
/// current ("home") network. The network is identified permission-free by the default
/// gateway's MAC address (configd's ARP-verified router MAC, fallback route -> ping -> arp). No CoreWLAN, no Location permission.
final class NetworkMonitor {
    static let allowlistKey = "pausedGatewayMACs"

    /// Invoked on the MAIN queue whenever the computed pause state changes.
    var onPauseStateChange: ((Bool) -> Void)?

    private let prefs = UserDefaults.standard
    private let workQueue = DispatchQueue(label: "com.ts1.BLEUnlock.networkmonitor", qos: .utility)
    private var store: SCDynamicStore?

    /// Main-queue only.
    /// Seeded to `true` (paused) so that during the asynchronous first gateway resolution
    /// at launch — route/ping/arp can take a second or more — auto-lock/unlock stays
    /// suppressed. The first resolution relaxes it to `false` only once the gateway MAC is
    /// confirmed NOT in the allowlist; an unresolvable network keeps it paused (sticky).
    private(set) var paused = true

    var allowlist: Set<String> {
        get { Set(prefs.stringArray(forKey: NetworkMonitor.allowlistKey) ?? []) }
        set { prefs.set(Array(newValue).sorted(), forKey: NetworkMonitor.allowlistKey) }
    }

    /// Begin watching for default-route changes and evaluate the current network once.
    func start() {
        var context = SCDynamicStoreContext(version: 0,
                                            info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info = info else { return }
            Unmanaged<NetworkMonitor>.fromOpaque(info).takeUnretainedValue().networkChanged()
        }
        guard let store = SCDynamicStoreCreate(nil, "BLEUnlock.NetworkMonitor" as CFString, callback, &context) else {
            print("NetworkMonitor: failed to create SCDynamicStore")
            return
        }
        let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] as CFArray
        // configd publishes ARPResolvedHardwareAddress in the per-service IPv4 dict, often
        // shortly AFTER the global key changed — watch it too so a late ARP verify re-evaluates.
        let patterns = ["State:/Network/Service/[^/]+/IPv4"] as CFArray
        // Exact keys go in `keys`, regexes in `patterns`.
        SCDynamicStoreSetNotificationKeys(store, keys, patterns)
        if let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        self.store = store
        networkChanged() // initial evaluation
    }

    /// Re-evaluate pause state off the main queue, publish back on the main queue.
    /// Safe to call from the main queue (the SCDynamicStore callback and start() do).
    func networkChanged() {
        let allow = allowlist
        let previous = paused
        workQueue.async { [weak self] in
            guard let self = self else { return }
            let mac = self.resolveGatewayMAC()
            let newPaused = computePauseState(resolvedMAC: mac, allowlist: allow, previous: previous)
            DispatchQueue.main.async {
                guard newPaused != self.paused else { return }
                self.paused = newPaused
                self.onPauseStateChange?(newPaused)
            }
        }
    }

    /// Resolve the current default gateway's MAC. BLOCKING — never call on the main queue.
    func resolveGatewayMAC() -> String? {
        // macOS 27+ hides the ARP table from non-root processes (even with Local Network
        // permission), so ask configd first and keep route/ping/arp as the fallback.
        if let mac = gatewayMACFromDynamicStore() {
            return mac
        }
        guard let route = runProcess("/sbin/route", ["-n", "get", "default"]),
              let gatewayIP = parseDefaultGatewayIP(routeOutput: route) else {
            return nil
        }
        _ = runProcess("/sbin/ping", ["-c", "2", "-t", "1", gatewayIP]) // prime ARP cache
        for attempt in 0..<3 {
            if let out = runProcess("/usr/sbin/arp", ["-n", gatewayIP]),
               let mac = parseGatewayMAC(arpOutput: out) {
                return mac
            }
            if attempt < 2 { usleep(150_000) } // let ARP settle, then retry
        }
        return nil
    }

    /// Router MAC as ARP-verified by configd for the primary IPv4 service, or nil.
    private func gatewayMACFromDynamicStore() -> String? {
        guard let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let service = global["PrimaryService"] as? String,
              let ipv4 = SCDynamicStoreCopyValue(nil, "State:/Network/Service/\(service)/IPv4" as CFString) as? [String: Any] else {
            return nil
        }
        return parseGatewayMAC(ipv4State: ipv4)
    }

    @discardableResult
    private func runProcess(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            print("NetworkMonitor: failed to run \(path): \(error)")
            return nil
        }
    }
}

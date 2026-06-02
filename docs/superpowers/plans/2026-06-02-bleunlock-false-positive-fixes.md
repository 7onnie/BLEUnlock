# BLEUnlock False-Positive Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate false-positive unlocks (Part A, a smoothed + debounced unlock gate) and add permission-free Wi-Fi auto-pause keyed on the default-gateway MAC (Part B), shipped as two independent PRs against `ts1/BLEUnlock`.

**Architecture:** Pure decision/parsing logic is extracted into Foundation-only files (`RSSIDecision.swift`, `GatewayParsing.swift`) that are unit-tested standalone with `swiftc` (the project has no XCTest target). The stateful glue (`BLE.swift` changes, `NetworkMonitor.swift`, `AppDelegate.swift` guards) consumes those pure functions and is verified by a release-config compile (`xcodebuild`) plus a manual checklist. New source files are registered into the Xcode target with the `xcodeproj` Ruby gem.

**Tech Stack:** Swift, CoreBluetooth, SystemConfiguration (`SCDynamicStore`), `Process` (route/ping/arp), Xcode project format objectVersion 50, `xcodeproj` Ruby gem 1.25.1.

**Repo:** `/Users/user/GitHubRepos/BLEUnlock-src` — `origin = https://github.com/ts1/BLEUnlock.git`, upstream base commit `2eeb35d` (local `master` carries the design+plan docs ahead of it; PR branches are cut from `2eeb35d` so the docs never enter a PR).

**Spec:** `docs/superpowers/specs/2026-05-30-bleunlock-rssi-debounce-and-wifi-pause-design.md`

---

## File Structure

**Part A (PR #1 — branch `fix/smoothed-unlock-debounce`):**
- Create `BLEUnlock/RSSIDecision.swift` — pure: `meanRSSI`, `shouldUnlock`. Added to target.
- Modify `BLEUnlock/BLE.swift` — drop `import Accelerate`; add `unlockMinSamples`; reimplement `getEstimatedRSSI` via `meanRSSI`; gate the unlock transition with `shouldUnlock`; remove `latestRSSIs.removeAll()`.
- Create `Tests/RSSIDecisionTests/main.swift` — standalone (NOT in target).

**Part B (PR #2 — branch `feature/wifi-auto-pause-gateway-mac`):**
- Create `BLEUnlock/GatewayParsing.swift` — pure: `parseDefaultGatewayIP`, `normalizeMAC`, `parseGatewayMAC`, `computePauseState`. Added to target.
- Create `BLEUnlock/NetworkMonitor.swift` — glue: `SCDynamicStore` watcher, `Process` resolution, allowlist persistence, main-queue pause callback. Added to target.
- Modify `BLEUnlock/AppDelegate.swift` — `pausedByNetwork` flag, guards in `updatePresence`/`tryUnlockScreen`, `NetworkMonitor` wiring, "Disable on This Network" menu item + action.
- Modify `BLEUnlock/Base.lproj/Localizable.strings` and `BLEUnlock/de.lproj/Localizable.strings` — two new keys.
- Create `Tests/GatewayParsingTests/main.swift` — standalone (NOT in target).

**Shared helper (dev-only, NOT committed to PR branches):** `/tmp/add_file_to_project.rb`.

---

## Task 0: Local git identity & verify base

**Files:** none (git config on the clone).

- [ ] **Step 1: Set commit identity for this clone**

```bash
cd /Users/user/GitHubRepos/BLEUnlock-src
git config user.name "Jonas Haderer"
git config user.email "jonas.haderer@zollsoft.de"
```

- [ ] **Step 2: Confirm the upstream base commit exists**

Run: `git cat-file -t 2eeb35d`
Expected: `commit`

- [ ] **Step 3: Write the shared xcodeproj helper script**

Create `/tmp/add_file_to_project.rb`:

```ruby
# Usage: ruby add_file_to_project.rb <project.xcodeproj> <TargetName> <FileName.swift> [more.swift ...]
require 'xcodeproj'
proj_path, target_name, *files = ARGV
project = Xcodeproj::Project.open(proj_path)
target  = project.targets.find { |t| t.name == target_name } or abort "no target #{target_name}"
anchor  = project.files.find { |f| f.path&.end_with?('BLE.swift') } or abort "BLE.swift not found"
group   = anchor.parent
files.each do |name|
  if project.files.any? { |f| f.display_name == name }
    puts "skip (already present): #{name}"; next
  end
  # Pass an ABSOLUTE path so Xcodeproj resolves it relative to the group's real path
  # (BLEUnlock/) and stores path="<name>", sourceTree="<group>" — matching BLE.swift.
  abs = File.join(group.real_path.to_s, name)
  ref = group.new_reference(abs)
  target.source_build_phase.add_file_reference(ref)
  puts "added: #{name} (path=#{ref.path})"
end
project.save
puts "saved #{proj_path}"
```

(No commit — this file is a dev tool only.)

---

# PART A — Unlock debounce (PR #1)

## Task 1: Pure RSSI decision logic (TDD)

**Files:**
- Create: `BLEUnlock/RSSIDecision.swift`
- Test: `Tests/RSSIDecisionTests/main.swift`

- [ ] **Step 1: Create the Part A branch from the upstream base**

```bash
cd /Users/user/GitHubRepos/BLEUnlock-src
git checkout -b fix/smoothed-unlock-debounce 2eeb35d
```

- [ ] **Step 2: Write the failing test**

Create `Tests/RSSIDecisionTests/main.swift`:

```swift
import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("ok   - \(msg)") } else { print("FAIL - \(msg)"); failures += 1 }
}

// meanRSSI — arithmetic mean, truncated toward zero (matches prior Int(mean)).
check(meanRSSI([]) == 0, "mean of empty window is 0")
check(meanRSSI([-50, -50, -50]) == -50, "mean of equal samples")
check(meanRSSI([-85, -85, -85, -85, -40]) == -76, "a lone -40 spike only pulls the mean to -76")

// shouldUnlock — a lone spike must NOT unlock; sustained signal must.
check(shouldUnlock(estimatedRSSI: -76, sampleCount: 5, unlockThreshold: -60, minSamples: 3, isPresent: false) == false,
      "smoothed -76 < threshold -60 -> no unlock (spike rejected)")
check(shouldUnlock(estimatedRSSI: -55, sampleCount: 3, unlockThreshold: -60, minSamples: 3, isPresent: false) == true,
      "smoothed -55 with 3 samples -> unlock")
check(shouldUnlock(estimatedRSSI: -55, sampleCount: 2, unlockThreshold: -60, minSamples: 3, isPresent: false) == false,
      "strong signal but only 2 samples -> no unlock (warm-up)")
check(shouldUnlock(estimatedRSSI: -55, sampleCount: 5, unlockThreshold: -60, minSamples: 3, isPresent: true) == false,
      "already present -> never re-unlock")
check(shouldUnlock(estimatedRSSI: -60, sampleCount: 3, unlockThreshold: -60, minSamples: 3, isPresent: false) == true,
      "exactly at threshold -> unlock")

if failures == 0 { print("\nALL PASS") } else { print("\n\(failures) FAILURE(S)"); exit(1) }
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swiftc -o /tmp/rssi-tests Tests/RSSIDecisionTests/main.swift 2>&1 | head`
Expected: FAIL — compile errors `cannot find 'meanRSSI' in scope` / `cannot find 'shouldUnlock' in scope`.

- [ ] **Step 4: Write the implementation**

Create `BLEUnlock/RSSIDecision.swift`:

```swift
import Foundation

/// Arithmetic mean of the RSSI window, truncated toward zero.
/// Matches the prior `Int(mean)` behaviour of the vDSP implementation while removing
/// the Accelerate dependency, and is the basis of the unlock-debounce decision.
func meanRSSI(_ samples: [Double]) -> Int {
    guard !samples.isEmpty else { return 0 }
    return Int(samples.reduce(0, +) / Double(samples.count))
}

/// Pure gate for the unlock / presence transition.
///
/// A lone RSSI spike cannot flip presence: the *smoothed* value must cross the threshold,
/// the window must already hold at least `minSamples` readings, and we only unlock when
/// not already present.
func shouldUnlock(estimatedRSSI: Int,
                  sampleCount: Int,
                  unlockThreshold: Int,
                  minSamples: Int,
                  isPresent: Bool) -> Bool {
    return !isPresent && sampleCount >= minSamples && estimatedRSSI >= unlockThreshold
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swiftc -o /tmp/rssi-tests BLEUnlock/RSSIDecision.swift Tests/RSSIDecisionTests/main.swift && /tmp/rssi-tests`
Expected: all `ok - …` lines, final line `ALL PASS`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add BLEUnlock/RSSIDecision.swift Tests/RSSIDecisionTests/main.swift
git commit -m "Add pure RSSI smoothing + unlock-gate helpers with standalone tests"
```

## Task 2: Register RSSIDecision.swift in the Xcode target

**Files:**
- Modify: `BLEUnlock.xcodeproj/project.pbxproj` (via the gem helper)

- [ ] **Step 1: Add the file to the BLEUnlock target**

```bash
cd /Users/user/GitHubRepos/BLEUnlock-src
ruby /tmp/add_file_to_project.rb BLEUnlock.xcodeproj BLEUnlock RSSIDecision.swift
```
Expected: `added: RSSIDecision.swift` then `saved BLEUnlock.xcodeproj`.

- [ ] **Step 2: Verify the project still parses and the file is wired in**

Run: `xcodebuild -list -project BLEUnlock.xcodeproj >/dev/null && grep -c "RSSIDecision.swift" BLEUnlock.xcodeproj/project.pbxproj`
Expected: command succeeds (exit 0) and prints `4` (PBXBuildFile line, PBXFileReference line, group-child line, Sources-phase line — same pattern as `BLE.swift`).

- [ ] **Step 3: Commit**

```bash
git add BLEUnlock.xcodeproj/project.pbxproj
git commit -m "Add RSSIDecision.swift to BLEUnlock target"
```

## Task 3: Use the smoothed, debounced gate in BLE.swift

**Files:**
- Modify: `BLEUnlock/BLE.swift` (line 3 import; ~138 properties; `getEstimatedRSSI` ~224-233; `updateMonitoredPeripheral` ~235-264)

- [ ] **Step 1: Remove the Accelerate import**

In `BLEUnlock/BLE.swift`, delete line 3:

```swift
import Accelerate
```

- [ ] **Step 2: Add the `unlockMinSamples` property**

In `BLEUnlock/BLE.swift`, immediately after `var latestN: Int = 5` add:

```swift
    var unlockMinSamples = 3   // window must hold >= this many readings before an unlock
```

- [ ] **Step 3: Reimplement `getEstimatedRSSI` to use the pure mean**

Replace the whole `getEstimatedRSSI(rssi:)` function body with:

```swift
    func getEstimatedRSSI(rssi: Int) -> Int {
        if latestRSSIs.count >= latestN {
            latestRSSIs.removeFirst()
        }
        latestRSSIs.append(Double(rssi))
        return meanRSSI(latestRSSIs)
    }
```

- [ ] **Step 4: Rewrite the unlock gate in `updateMonitoredPeripheral`**

Replace the entire `updateMonitoredPeripheral(_:)` function with:

```swift
    func updateMonitoredPeripheral(_ rssi: Int) {
        // Smooth first, so every decision below uses the moving average.
        let estimatedRSSI = getEstimatedRSSI(rssi: rssi)
        delegate?.updateRSSI(rssi: estimatedRSSI, active: activeModeTimer != nil)

        let unlockThreshold = (unlockRSSI == UNLOCK_DISABLED ? lockRSSI : unlockRSSI)
        if shouldUnlock(estimatedRSSI: estimatedRSSI,
                        sampleCount: latestRSSIs.count,
                        unlockThreshold: unlockThreshold,
                        minSamples: unlockMinSamples,
                        isPresent: presence) {
            print("Device is close")
            presence = true
            delegate?.updatePresence(presence: presence, reason: "close")
            // NOTE: the previous `latestRSSIs.removeAll()` is intentionally gone — clearing
            // the window made the very next sample drive the LOCK decision off a single raw
            // value. Keeping the window smoothed protects both lock and unlock decisions.
        }

        if estimatedRSSI >= (lockRSSI == LOCK_DISABLED ? unlockRSSI : lockRSSI) {
            if let timer = proximityTimer {
                timer.invalidate()
                print("Proximity timer canceled")
                proximityTimer = nil
            }
        } else if presence && proximityTimer == nil {
            proximityTimer = Timer.scheduledTimer(withTimeInterval: proximityTimeout, repeats: false, block: { _ in
                print("Device is away")
                self.presence = false
                self.delegate?.updatePresence(presence: self.presence, reason: "away")
                self.proximityTimer = nil
            })
            RunLoop.main.add(proximityTimer!, forMode: .common)
            print("Proximity timer started")
        }
        resetSignalTimer()
    }
```

- [ ] **Step 5: Verify Accelerate is no longer referenced**

Run: `grep -n "Accelerate\|vDSP" BLEUnlock/BLE.swift`
Expected: no output (exit 1, nothing printed).

- [ ] **Step 6: Build the app (compile check, no signing)**

Run:
```bash
xcodebuild build -scheme BLEUnlock -configuration Debug \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  -derivedDataPath /tmp/bleunlock-dd 2>&1 | tail -5
```
Expected: ends with `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Re-run the pure tests against the shipped file (regression guard)**

Run: `swiftc -o /tmp/rssi-tests BLEUnlock/RSSIDecision.swift Tests/RSSIDecisionTests/main.swift && /tmp/rssi-tests | tail -1`
Expected: `ALL PASS`.

- [ ] **Step 8: Commit**

```bash
git add BLEUnlock/BLE.swift
git commit -m "Gate unlock on smoothed RSSI + minimum sample count to kill single-spike false positives

The presence/unlock transition previously used a single raw RSSI reading, so one
spurious strong sample (multipath reflection, advertising burst) could unlock the Mac
from far away. Compute the moving average first and gate the transition on it plus a
minimum sample count; drop the buffer-clearing that destabilised the lock decision.
Refs #153."
```

**End of Part A.** The branch `fix/smoothed-unlock-debounce` is ready to become PR #1 (push handled in Task 10, after user confirmation).

---

# PART B — Wi-Fi auto-pause (PR #2)

## Task 4: Pure gateway parsing & pause logic (TDD)

**Files:**
- Create: `BLEUnlock/GatewayParsing.swift`
- Test: `Tests/GatewayParsingTests/main.swift`

- [ ] **Step 1: Create the Part B branch from the upstream base**

```bash
cd /Users/user/GitHubRepos/BLEUnlock-src
git checkout -b feature/wifi-auto-pause-gateway-mac 2eeb35d
```

- [ ] **Step 2: Write the failing test**

Create `Tests/GatewayParsingTests/main.swift`:

```swift
import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("ok   - \(msg)") } else { print("FAIL - \(msg)"); failures += 1 }
}

let routeOut = """
   route to: default
destination: default
       mask: default
    gateway: 10.0.0.1
  interface: en0
      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING>
"""
check(parseDefaultGatewayIP(routeOutput: routeOut) == "10.0.0.1", "parse gateway IP from route output")
check(parseDefaultGatewayIP(routeOutput: "no default route\n") == nil, "no gateway line -> nil")

// macOS `arp` prints octets WITHOUT leading zeros; normalise so allowlist matches.
check(normalizeMAC("a4:2b:8c:1:2:3") == "a4:2b:8c:01:02:03", "pad single-digit octets")
check(normalizeMAC("A4:2B:8C:01:02:03") == "a4:2b:8c:01:02:03", "lower-case octets")
check(normalizeMAC("a4:2b:8c:1:2") == nil, "five octets -> nil")
check(normalizeMAC("zz:2b:8c:1:2:3") == nil, "non-hex octet -> nil")

let arpOut = "? (10.0.0.1) at a4:2b:8c:1:2:3 on en0 ifscope [ethernet]"
check(parseGatewayMAC(arpOutput: arpOut) == "a4:2b:8c:01:02:03", "parse + normalise MAC from arp output")
check(parseGatewayMAC(arpOutput: "? (10.0.0.1) at (incomplete) on en0 ifscope [ethernet]") == nil, "incomplete arp entry -> nil")

let allow: Set<String> = ["a4:2b:8c:01:02:03"]
check(computePauseState(resolvedMAC: "a4:2b:8c:01:02:03", allowlist: allow, previous: false) == true, "MAC in allowlist -> paused")
check(computePauseState(resolvedMAC: "ff:ff:ff:ff:ff:ff", allowlist: allow, previous: true) == false, "MAC not in allowlist -> active")
check(computePauseState(resolvedMAC: nil, allowlist: allow, previous: true) == true, "nil keeps previous state (sticky true)")
check(computePauseState(resolvedMAC: nil, allowlist: allow, previous: false) == false, "nil keeps previous state (sticky false)")

if failures == 0 { print("\nALL PASS") } else { print("\n\(failures) FAILURE(S)"); exit(1) }
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swiftc -o /tmp/gw-tests Tests/GatewayParsingTests/main.swift 2>&1 | head`
Expected: FAIL — `cannot find 'parseDefaultGatewayIP' in scope`, etc.

- [ ] **Step 4: Write the implementation**

Create `BLEUnlock/GatewayParsing.swift`:

```swift
import Foundation

/// Extracts the IPv4 default-gateway address from `route -n get default` output.
func parseDefaultGatewayIP(routeOutput: String) -> String? {
    for line in routeOutput.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("gateway:") {
            let value = trimmed.dropFirst("gateway:".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
    }
    return nil
}

/// Normalises a MAC to lower-case, colon-separated, zero-padded octets.
/// macOS `arp` prints octets without leading zeros (e.g. "a4:2b:8c:1:2:3"), so padding
/// keeps allowlist comparisons stable. Returns nil for anything that is not 6 hex octets.
func normalizeMAC(_ raw: String) -> String? {
    let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 6 else { return nil }
    var octets: [String] = []
    for part in parts {
        guard (1...2).contains(part.count), let value = Int(part, radix: 16) else { return nil }
        octets.append(String(format: "%02x", value))
    }
    return octets.joined(separator: ":")
}

/// Extracts and normalises the gateway MAC from `arp -n <ip>` output, e.g.
/// "? (10.0.0.1) at a4:2b:8c:1:2:3 on en0 ifscope [ethernet]".
func parseGatewayMAC(arpOutput: String) -> String? {
    let tokens = arpOutput.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
    guard let atIndex = tokens.firstIndex(of: "at"), atIndex + 1 < tokens.count else { return nil }
    let macToken = String(tokens[atIndex + 1])
    if macToken == "(incomplete)" { return nil }
    return normalizeMAC(macToken)
}

/// Pause state with sticky behaviour: an unresolved MAC keeps the previous state, so a
/// transient ARP/route hiccup does not flip the pause off (or on) spuriously.
func computePauseState(resolvedMAC: String?, allowlist: Set<String>, previous: Bool) -> Bool {
    guard let mac = resolvedMAC else { return previous }
    return allowlist.contains(mac)
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swiftc -o /tmp/gw-tests BLEUnlock/GatewayParsing.swift Tests/GatewayParsingTests/main.swift && /tmp/gw-tests`
Expected: all `ok - …`, final line `ALL PASS`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add BLEUnlock/GatewayParsing.swift Tests/GatewayParsingTests/main.swift
git commit -m "Add pure gateway parsing + sticky pause-state helpers with standalone tests"
```

## Task 5: NetworkMonitor glue (SCDynamicStore + Process)

**Files:**
- Create: `BLEUnlock/NetworkMonitor.swift`

- [ ] **Step 1: Write the implementation**

Create `BLEUnlock/NetworkMonitor.swift`:

```swift
import Foundation
import SystemConfiguration

/// Watches the default network and decides whether BLEUnlock should be paused on the
/// current ("home") network. The network is identified permission-free by the default
/// gateway's MAC address (route -> ping -> arp). No CoreWLAN, no Location permission.
final class NetworkMonitor {
    static let allowlistKey = "pausedGatewayMACs"

    /// Invoked on the MAIN queue whenever the computed pause state changes.
    var onPauseStateChange: ((Bool) -> Void)?

    private let prefs = UserDefaults.standard
    private let workQueue = DispatchQueue(label: "com.ts1.BLEUnlock.networkmonitor", qos: .utility)
    private var store: SCDynamicStore?

    /// Main-queue only.
    private(set) var paused = false

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
        SCDynamicStoreSetNotificationKeys(store, nil, keys)
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
```

- [ ] **Step 2: Commit**

```bash
git add BLEUnlock/NetworkMonitor.swift
git commit -m "Add NetworkMonitor: SCDynamicStore watcher + permission-free gateway-MAC resolver"
```

## Task 6: Register GatewayParsing.swift & NetworkMonitor.swift in the target

**Files:**
- Modify: `BLEUnlock.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add both files to the BLEUnlock target**

```bash
cd /Users/user/GitHubRepos/BLEUnlock-src
ruby /tmp/add_file_to_project.rb BLEUnlock.xcodeproj BLEUnlock GatewayParsing.swift NetworkMonitor.swift
```
Expected: `added: GatewayParsing.swift`, `added: NetworkMonitor.swift`, `saved BLEUnlock.xcodeproj`.

- [ ] **Step 2: Verify both are wired in and the project parses**

Run: `xcodebuild -list -project BLEUnlock.xcodeproj >/dev/null && grep -c "GatewayParsing.swift" BLEUnlock.xcodeproj/project.pbxproj && grep -c "NetworkMonitor.swift" BLEUnlock.xcodeproj/project.pbxproj`
Expected: exit 0, then `4` and `4`.

- [ ] **Step 3: Commit**

```bash
git add BLEUnlock.xcodeproj/project.pbxproj
git commit -m "Add GatewayParsing.swift and NetworkMonitor.swift to BLEUnlock target"
```

## Task 7: AppDelegate integration (flag, guards, wiring, menu)

**Files:**
- Modify: `BLEUnlock/AppDelegate.swift` (property block ~21-32; `updatePresence` ~219; `tryUnlockScreen` ~280; `constructMenu` ~648 near `passive_mode`; `applicationDidFinishLaunching` ~699; plus a new action method)

- [ ] **Step 1: Add the monitor and pause flag**

In `BLEUnlock/AppDelegate.swift`, just after `let ble = BLE()` add:

```swift
    let networkMonitor = NetworkMonitor()
```

And in the `var` block (e.g. after `var lastRSSI: Int? = nil`) add:

```swift
    var pausedByNetwork = false
    var disableOnNetworkMenuItem: NSMenuItem?
```

- [ ] **Step 2: Guard `updatePresence` so a paused network suppresses lock AND unlock**

In `func updatePresence(presence: Bool, reason: String) {`, make the first line:

```swift
        guard !pausedByNetwork else { return }
```

- [ ] **Step 3: Guard `tryUnlockScreen` (covers display/system-wake unlock paths)**

In `func tryUnlockScreen() {`, add as the first guard, before `guard !manualLock else { return }`:

```swift
        guard !pausedByNetwork else { return }
```

- [ ] **Step 4: Add the menu-toggle action method**

Add this method to `AppDelegate` (e.g. next to `togglePassiveMode`):

```swift
    @objc func toggleDisableOnThisNetwork(_ menuItem: NSMenuItem) {
        // Gateway resolution blocks (route/ping/arp); do it off the main queue.
        DispatchQueue.global(qos: .userInitiated).async {
            guard let mac = self.networkMonitor.resolveGatewayMAC() else {
                DispatchQueue.main.async { self.errorModal(t("network_not_identified")) }
                return
            }
            DispatchQueue.main.async {
                var list = self.networkMonitor.allowlist
                if list.contains(mac) {
                    list.remove(mac)
                } else {
                    list.insert(mac)
                }
                self.networkMonitor.allowlist = list
                self.networkMonitor.networkChanged() // recompute pause state now
            }
        }
    }
```

- [ ] **Step 5: Add the menu item**

In `constructMenu()`, immediately after the two `passive_mode` lines (`item = mainMenu.addItem(withTitle: t("passive_mode") …` and its `item.state = …`), add:

```swift
        disableOnNetworkMenuItem = mainMenu.addItem(withTitle: t("disable_on_this_network"),
                                                    action: #selector(toggleDisableOnThisNetwork),
                                                    keyEquivalent: "")
        disableOnNetworkMenuItem?.state = networkMonitor.paused ? .on : .off
```

- [ ] **Step 6: Wire and start the monitor**

In `applicationDidFinishLaunching`, just before the final `NSApp.setActivationPolicy(.accessory)`, add:

```swift
        networkMonitor.onPauseStateChange = { [weak self] paused in
            guard let self = self else { return }
            self.pausedByNetwork = paused
            self.disableOnNetworkMenuItem?.state = paused ? .on : .off
            print("Network pause state: \(paused)")
        }
        networkMonitor.start()
```

- [ ] **Step 7: Build the app (compile check, no signing)**

Run:
```bash
xcodebuild build -scheme BLEUnlock -configuration Debug \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  -derivedDataPath /tmp/bleunlock-dd 2>&1 | tail -5
```
Expected: ends with `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add BLEUnlock/AppDelegate.swift
git commit -m "Wire NetworkMonitor into AppDelegate: pause guards + 'Disable on This Network' menu"
```

## Task 8: Localizable strings

**Files:**
- Modify: `BLEUnlock/Base.lproj/Localizable.strings`
- Modify: `BLEUnlock/de.lproj/Localizable.strings`

- [ ] **Step 1: Add English (Base) keys**

Append to `BLEUnlock/Base.lproj/Localizable.strings`:

```
"disable_on_this_network" = "Disable on This Network";
"network_not_identified" = "Could not identify the current network (no IPv4 gateway found).";
```

- [ ] **Step 2: Add German keys**

Append to `BLEUnlock/de.lproj/Localizable.strings`:

```
"disable_on_this_network" = "In diesem Netzwerk deaktivieren";
"network_not_identified" = "Aktuelles Netzwerk konnte nicht identifiziert werden (kein IPv4-Gateway gefunden).";
```

- [ ] **Step 3: Verify both keys load (UTF-8 plist parse)**

Run: `plutil -lint BLEUnlock/Base.lproj/Localizable.strings BLEUnlock/de.lproj/Localizable.strings`
Expected: both lines end with `OK`.

- [ ] **Step 4: Commit**

```bash
git add BLEUnlock/Base.lproj/Localizable.strings BLEUnlock/de.lproj/Localizable.strings
git commit -m "Localize 'Disable on This Network' menu item (en, de)"
```

## Task 9: Manual verification checklist (Part B)

**Files:** none (requires a signed local run on a Mac with Bluetooth + Wi-Fi).

> Unit tests cover the pure logic; the SCDynamicStore/Process/AppDelegate glue is verified
> by hand. Run a signed Debug build from Xcode (the menu-bar app needs Accessibility +
> a stored password to actually unlock; for these checks the lock/unlock side effects can
> be observed without a password).

- [ ] **Step 1: Resolver sanity against the live network (no app needed)**

Write `/tmp/gw-probe-src/main.swift` (the file MUST be named `main.swift` — `swiftc` only allows top-level statements there):

```swift
import Foundation
print(NetworkMonitor().resolveGatewayMAC() ?? "nil")
```
Run:
```bash
mkdir -p /tmp/gw-probe-src   # then create main.swift above
swiftc -o /tmp/gw-probe \
  BLEUnlock/GatewayParsing.swift BLEUnlock/NetworkMonitor.swift /tmp/gw-probe-src/main.swift \
  && /tmp/gw-probe
```
Expected: prints a normalized MAC like `a4:2b:8c:01:02:03` for the current network (or `nil` when off any IPv4 network). This also confirms `NetworkMonitor.swift` compiles standalone against `GatewayParsing.swift`.

- [ ] **Step 2: Add current network** — Run the app, open the menu, click "Disable on This Network". Expect the item to gain a checkmark and the log to print `Network pause state: true`.

- [ ] **Step 3: Pause suppresses lock** — With the device out of range (or BT off), confirm the Mac does NOT auto-lock while the item is checked.

- [ ] **Step 4: Pause suppresses unlock** — Lock the Mac manually, bring the device close; confirm it does NOT auto-unlock while paused.

- [ ] **Step 5: Resume off-network** — Switch to a different Wi-Fi / tether. Confirm the log prints `Network pause state: false`, the checkmark clears, and normal lock/unlock resumes.

- [ ] **Step 6: No beachball** — Toggle the item and switch networks repeatedly; the menu and UI stay responsive (resolution runs off the main queue).

- [ ] **Step 7: Re-run both pure test suites (final regression guard)**

```bash
swiftc -o /tmp/rssi-tests BLEUnlock/RSSIDecision.swift Tests/RSSIDecisionTests/main.swift && /tmp/rssi-tests | tail -1
swiftc -o /tmp/gw-tests BLEUnlock/GatewayParsing.swift Tests/GatewayParsingTests/main.swift && /tmp/gw-tests | tail -1
```
Expected: `ALL PASS` twice.

**End of Part B.** The branch `feature/wifi-auto-pause-gateway-mac` is ready to become PR #2.

---

## Task 10: Fork & push (OUTWARD-FACING — confirm with user first)

**Files:** none (GitHub).

> STOP: do not run this task without explicit user go-ahead. It creates a public fork and
> pushes branches under the user's GitHub account.

- [ ] **Step 1: Confirm `gh` auth**

Run: `gh auth status`
Expected: logged in. If not, the user runs `! gh auth login` in-session.

- [ ] **Step 2: Fork upstream**

```bash
cd /Users/user/GitHubRepos/BLEUnlock-src
gh repo fork ts1/BLEUnlock --remote=false
```
Expected: a fork at `<user>/BLEUnlock`. Add it as a remote:
```bash
git remote add fork "https://github.com/$(gh api user -q .login)/BLEUnlock.git"
```

- [ ] **Step 3: Push Part A and open PR #1**

```bash
git push fork fix/smoothed-unlock-debounce
gh pr create --repo ts1/BLEUnlock --head "$(gh api user -q .login):fix/smoothed-unlock-debounce" \
  --title "Fix false-positive unlocks: gate unlock on smoothed RSSI + minimum sample count" \
  --body "The presence/unlock transition used a single raw RSSI sample, so one spurious strong reading (multipath reflection, advertising burst) could unlock the Mac from across the home. This computes the moving average first and gates the unlock on it plus a minimum sample count, and removes the buffer-clearing that destabilised the lock decision. Pure logic is covered by standalone tests in Tests/. Refs #153."
```

- [ ] **Step 4: Push Part B and open PR #2**

```bash
git push fork feature/wifi-auto-pause-gateway-mac
gh pr create --repo ts1/BLEUnlock --head "$(gh api user -q .login):feature/wifi-auto-pause-gateway-mac" \
  --title "Add Wi-Fi auto-pause keyed on default-gateway MAC (permission-free)" \
  --body "Implements #142: completely pause auto-lock/unlock on user-designated home networks, identified permission-free by the default gateway's MAC (route/ping/arp) — no SSID, no Location permission. Network changes are detected via SCDynamicStore; resolution runs off the main queue; pause state is sticky across transient failures. Pure parsing/state logic is covered by standalone tests in Tests/."
```

---

## Self-Review notes (author)
- **Spec coverage:** Part A debounce (Tasks 1-3) ✓; `removeAll()` removal (Task 3 Step 4) ✓; `unlockMinSamples=3` (Task 3 Step 2) ✓. Part B identity route/ping(-c2)/arp+retry (Task 5) ✓; SCDynamicStore + background-queue threading (Task 5) ✓; sticky pause (Task 4 `computePauseState`) ✓; guards in updatePresence+tryUnlockScreen (Task 7) ✓; menu + allowlist UserDefaults (Tasks 7-8) ✓; edge cases handled in pure logic + manual checklist (Task 9) ✓. `intruded`/runScript left unguarded by design (no task needed — it is not reached via the two guarded methods).
- **Type consistency:** `meanRSSI([Double])->Int`, `shouldUnlock(...)->Bool`, `parseDefaultGatewayIP(routeOutput:)`, `normalizeMAC(_:)`, `parseGatewayMAC(arpOutput:)`, `computePauseState(resolvedMAC:allowlist:previous:)`, `NetworkMonitor.resolveGatewayMAC()/networkChanged()/start()/allowlist/paused/onPauseStateChange` — names used identically across BLE.swift, NetworkMonitor.swift, AppDelegate.swift, and both test files.
- **No placeholders:** every code step contains complete code; every run step has an expected result.

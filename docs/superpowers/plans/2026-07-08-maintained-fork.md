# Maintained Fork 7onnie/BLEUnlock — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `7onnie/BLEUnlock` wird ein eigenständig gepflegter Fork: Skyearn-Basis importiert, Parts A/B portiert, eigener Update-Kanal mit unsignierten (ad-hoc-signierten) Releases.

**Architecture:** Vendor-Branch `skyearn-upstream` spiegelt `Skyearn/BLEUnlock` und wird in `master` gemergt. Part A ersetzt den Raw-RSSI-Unlock in `updateMonitoredState()` durch das pure Gate `shouldUnlock()` (per-device `rssiWindow` existiert bei Skyearn schon, Median-of-5). Part B wird als globaler `pausedByNetwork`-Guard in Skyearns AppDelegate portiert. Neu (Spec-Korrektur): Skyearns Updater installiert NICHT selbst — er öffnet den DMG-Download im Browser (→ Quarantäne + Gatekeeper bei jedem Update). Deshalb bekommt der Fork ein Zip-Release-Asset und einen kleinen In-App-Installer (URLSession-Download setzt für diese App keine Quarantäne).

**Tech Stack:** Swift (AppKit, CoreBluetooth), Xcode-Projekt, `swiftc`-Testsuiten (kein XCTest), GitHub Actions (`macos-26`-Runner), `gh` CLI.

## Global Constraints

- Arbeitsverzeichnis: `/Users/user/GitHubRepos/BLEUnlock-src` (Remotes: `origin`=ts1, `fork`=7onnie, ab Task 1 `skyearn`).
- Nach jedem Task: `git push fork <branch>` (User-Regel: commit + push nach jeder Änderung).
- Nach JEDEM `xcodebuild`: `git status` prüfen; falls `BLEUnlock/Info.plist` durch die Version-Bump-Build-Phase geändert wurde → `git checkout -- BLEUnlock/Info.plist` VOR dem Commit.
- Swift-Code folgt dem Stil der umgebenden Datei (Repo-Idiom), NICHT dem `_PascalCase`-Script-Stil aus den globalen Prefs (der gilt nur für Shell-Scripts).
- Branches `fix/smoothed-unlock-debounce` und `feature/wifi-auto-pause-gateway-mac` NIEMALS verändern oder löschen (tragen die offenen ts1-PRs #183/#184).
- Testsuiten laufen mit `swiftc`, Binaries nach `/private/tmp/claude-503/-Users-user-GitHubRepos-BLEUnlock/8369d4f4-3922-4b5f-b708-df31bde3323a/scratchpad/` (im Folgenden `$SCRATCH`).
- Versionierung: Fork startet bei Tag `v1.15.0`; `MARKETING_VERSION` wird im Release-Workflow aus dem Tag gesetzt.

---

### Task 1: Vendor-Branch + Skyearn-Import in master

**Files:**
- Modify: nur Git-Zustand (Merge), keine Handedits.

**Interfaces:**
- Produces: `master` = ts1-master + Doku-Commits + kompletter Skyearn-Stand (Multi-Device, macOS-26, Updater, `.github/workflows/release.yml`). Branch `skyearn-upstream` auf dem Fork.

- [ ] **Step 1: Remote + Vendor-Branch anlegen**

```bash
cd /Users/user/GitHubRepos/BLEUnlock-src
git remote add skyearn https://github.com/Skyearn/BLEUnlock.git
git fetch skyearn
git checkout -b skyearn-upstream skyearn/master
git push fork skyearn-upstream
```

- [ ] **Step 2: In master mergen**

```bash
git checkout master
git merge skyearn-upstream -m "Merge Skyearn/BLEUnlock: macOS 26 compat, multi-device, update checker, release CI"
```

Expected: Merge ohne Konflikte (unser master hat gegenüber ts1 nur `docs/`-Commits). Bei Konflikten: STOPP, nicht raten — Konfliktliste dem Reviewer melden.

- [ ] **Step 3: Build-Smoke-Test**

```bash
xcodebuild -project BLEUnlock.xcodeproj -scheme BLEUnlock -configuration Release CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
git status --short   # Info.plist gebumpt? -> git checkout -- BLEUnlock/Info.plist
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Push**

```bash
git push fork master
```

---

### Task 2: Part A — RSSIDecision-Modul + Tests (TDD)

**Files:**
- Create: `BLEUnlock/RSSIDecision.swift`
- Create: `Tests/RSSIDecisionTests/main.swift`

**Interfaces:**
- Produces: `func shouldUnlock(estimatedRSSI: Int, sampleCount: Int, unlockThreshold: Int, minSamples: Int, isPresent: Bool) -> Bool` — pure, wird in Task 3 von `BLE.updateMonitoredState` konsumiert. (Das alte `meanRSSI` entfällt: Skyearn glättet bereits per Median-of-5 in `getEstimatedRSSI`, Accelerate ist schon weg.)

- [ ] **Step 1: Branch anlegen**

```bash
git checkout -b port/smoothed-unlock-gate master
```

- [ ] **Step 2: Failing Test schreiben** — `Tests/RSSIDecisionTests/main.swift`:

```swift
import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("ok   - \(msg)") } else { print("FAIL - \(msg)"); failures += 1 }
}

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

- [ ] **Step 3: Test läuft und schlägt fehl**

```bash
SCRATCH=/private/tmp/claude-503/-Users-user-GitHubRepos-BLEUnlock/8369d4f4-3922-4b5f-b708-df31bde3323a/scratchpad
swiftc -o $SCRATCH/rssidecision-tests Tests/RSSIDecisionTests/main.swift 2>&1 | head -3
```

Expected: FAIL mit `cannot find 'shouldUnlock' in scope`

- [ ] **Step 4: Implementation** — `BLEUnlock/RSSIDecision.swift`:

```swift
import Foundation

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

- [ ] **Step 5: Test läuft durch**

```bash
swiftc -o $SCRATCH/rssidecision-tests Tests/RSSIDecisionTests/main.swift BLEUnlock/RSSIDecision.swift && $SCRATCH/rssidecision-tests
```

Expected: 5× `ok`, `ALL PASS`

- [ ] **Step 6: Commit**

```bash
git add BLEUnlock/RSSIDecision.swift Tests/RSSIDecisionTests/main.swift
git commit -m "Add pure shouldUnlock gate with swiftc test suite"
git push fork port/smoothed-unlock-gate
```

---

### Task 3: Part A — BLE-Integration (per Device) + Merge

**Files:**
- Modify: `BLEUnlock/BLE.swift` (Funktion `updateMonitoredState`, Property-Block bei `var proximityTimeout`)
- Modify: `BLEUnlock.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `shouldUnlock(...)` aus Task 2; Skyearns `MonitoredDeviceState` (Felder `rssiWindow: [Int]`, `presence: Bool`, `lastRSSI: Int?`, `uuid`), `getEstimatedRSSI(state:rssi:)` (Median-of-5), `updateAggregatePresence(reason:)`, `updateAggregateRSSI()`.
- Produces: `BLE.unlockMinSamples: Int` (= 3) und `BLE.clearSmoothingWindows()` — letzteres konsumiert Task 5 beim Resume der Wi-Fi-Pause.

- [ ] **Step 1: Property ergänzen** — in `class BLE` direkt nach `var proximityTimeout = 5.0`:

```swift
    var unlockMinSamples = 3   // window must hold >= this many readings before an unlock
```

- [ ] **Step 2: `updateMonitoredState` umbauen.** Der bestehende Anfang der Funktion ist:

```swift
    func updateMonitoredState(_ state: MonitoredDeviceState, rssi: Int) {
        if rssi >= (unlockRSSI == UNLOCK_DISABLED ? lockRSSI : unlockRSSI) && !state.presence {
            print("Device \(state.uuid) is close")
            state.presence = true
            state.rssiWindow.removeAll()
            updateAggregatePresence(reason: "close")
        }

        let estimatedRSSI = getEstimatedRSSI(state: state, rssi: rssi)
        state.lastRSSI = estimatedRSSI
        updateAggregateRSSI()
```

Ersetzen durch (Rest der Funktion ab `if estimatedRSSI >= (lockRSSI ...` bleibt unverändert):

```swift
    func updateMonitoredState(_ state: MonitoredDeviceState, rssi: Int) {
        // Smooth first, so every decision below uses the median-filtered value.
        let estimatedRSSI = getEstimatedRSSI(state: state, rssi: rssi)
        state.lastRSSI = estimatedRSSI
        updateAggregateRSSI()

        let unlockThreshold = (unlockRSSI == UNLOCK_DISABLED ? lockRSSI : unlockRSSI)
        if shouldUnlock(estimatedRSSI: estimatedRSSI,
                        sampleCount: state.rssiWindow.count,
                        unlockThreshold: unlockThreshold,
                        minSamples: unlockMinSamples,
                        isPresent: state.presence) {
            print("Device \(state.uuid) is close")
            state.presence = true
            // NOTE: the window is intentionally NOT cleared here — clearing made the very
            // next sample drive the LOCK decision off a single raw value (see RSSIDecision.swift).
            updateAggregatePresence(reason: "close")
        }
```

- [ ] **Step 3: `clearSmoothingWindows()` ergänzen** — direkt nach der Funktion `updateMonitoredState`:

```swift
    /// Drop all per-device smoothing state so stale samples can't carry a decision
    /// across a monitoring pause (Wi-Fi auto-pause resume, device list changes).
    func clearSmoothingWindows() {
        for state in monitoredStates.values {
            state.rssiWindow.removeAll()
            state.lastRSSI = nil
        }
    }
```

- [ ] **Step 4: pbxproj — RSSIDecision.swift ins Target.** Vier Zeilen einfügen, jeweils in der passenden Section (Anker-Zeilen existieren im gemergten pbxproj):

In `PBXBuildFile` nach der Zeile mit `3DD4B669226C1E3700451B7B /* login.framework in Frameworks */`:
```
		680CDE71110749891F5AA1E4 /* RSSIDecision.swift in Sources */ = {isa = PBXBuildFile; fileRef = B5D0346CA6A4625F6C40E69D /* RSSIDecision.swift */; };
```
In `PBXFileReference` nach der Zeile mit `B1EFF91622E010F50010DB0A /* zh-Hans */`:
```
		B5D0346CA6A4625F6C40E69D /* RSSIDecision.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = RSSIDecision.swift; sourceTree = "<group>"; };
```
In der Group mit `3D2FCF07226C99CB007A06E7 /* Images.xcassets */,` danach:
```
				B5D0346CA6A4625F6C40E69D /* RSSIDecision.swift */,
```
In der Sources-Build-Phase nach `3D79FD7D226C335100A373C0 /* appleDeviceNames.swift in Sources */,`:
```
				680CDE71110749891F5AA1E4 /* RSSIDecision.swift in Sources */,
```

- [ ] **Step 5: Build + Tests**

```bash
xcodebuild -project BLEUnlock.xcodeproj -scheme BLEUnlock -configuration Release CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
git checkout -- BLEUnlock/Info.plist 2>/dev/null || true
swiftc -o $SCRATCH/rssidecision-tests Tests/RSSIDecisionTests/main.swift BLEUnlock/RSSIDecision.swift && $SCRATCH/rssidecision-tests
```

Expected: `** BUILD SUCCEEDED **` und `ALL PASS`

- [ ] **Step 6: Commit, Merge nach master, Push**

```bash
git add BLEUnlock/BLE.swift BLEUnlock.xcodeproj/project.pbxproj
git commit -m "Gate per-device unlock on smoothed RSSI + minimum sample count"
git checkout master
git merge --no-ff port/smoothed-unlock-gate -m "Merge port/smoothed-unlock-gate (Part A on multi-device base)"
git push fork master port/smoothed-unlock-gate
```

---

### Task 4: Part B — GatewayParsing/NetworkMonitor übernehmen

**Files:**
- Create: `BLEUnlock/GatewayParsing.swift`, `BLEUnlock/NetworkMonitor.swift`, `Tests/GatewayParsingTests/main.swift` (alle 1:1 aus dem alten Branch)

**Interfaces:**
- Produces: `class NetworkMonitor` mit `var allowlist: Set<String>`, `var paused: Bool`, `var onPauseStateChange: ((Bool) -> Void)?`, `func start()`, `func networkChanged()`, `func resolveGatewayMAC() -> String?` — konsumiert Task 5. Startup-Default ist **paused** (Harden-Entscheidung, nicht ändern).

- [ ] **Step 1: Branch + Dateien übernehmen**

```bash
git checkout -b port/wifi-auto-pause master
git checkout feature/wifi-auto-pause-gateway-mac -- BLEUnlock/GatewayParsing.swift BLEUnlock/NetworkMonitor.swift Tests/GatewayParsingTests
```

- [ ] **Step 2: Tests laufen**

```bash
swiftc -o $SCRATCH/gateway-tests Tests/GatewayParsingTests/main.swift BLEUnlock/GatewayParsing.swift && $SCRATCH/gateway-tests
```

Expected: `ALL PASS`

- [ ] **Step 3: Commit**

```bash
git add BLEUnlock/GatewayParsing.swift BLEUnlock/NetworkMonitor.swift Tests/GatewayParsingTests
git commit -m "Import GatewayParsing + NetworkMonitor from PR #184 branch unchanged"
git push fork port/wifi-auto-pause
```

---

### Task 5: Part B — AppDelegate-Integration auf Skyearn-Basis + Merge

**Files:**
- Modify: `BLEUnlock/AppDelegate.swift`, `BLEUnlock/Base.lproj/Localizable.strings`, `BLEUnlock/de.lproj/Localizable.strings`, `BLEUnlock.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `NetworkMonitor` (Task 4), `ble.clearSmoothingWindows()` (Task 3).
- Produces: `pausedByNetwork`-Guard vor Unlock/Lock-Wirkungen; Menüpunkt "Disable on This Network".

- [ ] **Step 1: Properties** — in `class AppDelegate` nach `let ble = BLE()`:

```swift
    let networkMonitor = NetworkMonitor()
```

und nach `var lastRSSI: Int? = nil` (bzw. dem letzten var im selben Block):

```swift
    var pausedByNetwork = true
    var disableOnNetworkMenuItem: NSMenuItem?
```

- [ ] **Step 2: Guards.** In `func updatePresence(shouldUnlock: Bool, shouldLock: Bool, reason: String)` als ERSTE Zeile:

```swift
        guard !pausedByNetwork else { return }
```

In `func tryUnlockScreen(retryCount: Int = 0)` als ERSTE Zeile (vor `guard !manualLock`):

```swift
        guard !pausedByNetwork else { return }
```

- [ ] **Step 3: Menü-Action** — nach `@objc func togglePassiveMode(_ menuItem: NSMenuItem) { ... }` einfügen:

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

- [ ] **Step 4: Menüpunkt** — in `constructMenu()` nach dem `passive_mode`-Block (`item.state = prefs.bool(forKey: "passiveMode") ? .on : .off`):

```swift
        disableOnNetworkMenuItem = mainMenu.addItem(withTitle: t("disable_on_this_network"),
                                                    action: #selector(toggleDisableOnThisNetwork),
                                                    keyEquivalent: "")
        disableOnNetworkMenuItem?.state = networkMonitor.paused ? .on : .off
```

- [ ] **Step 5: Start + Resume-Reset** — in `applicationDidFinishLaunching`, direkt VOR der Zeile `runAutomaticUpdateCheck()` (am Funktionsende):

```swift
        networkMonitor.onPauseStateChange = { [weak self] paused in
            guard let self = self else { return }
            self.pausedByNetwork = paused
            self.disableOnNetworkMenuItem?.state = paused ? .on : .off
            if !paused {
                // Spec: never let stale samples carry a decision across a pause.
                self.ble.clearSmoothingWindows()
            }
            print("Network pause state: \(paused)")
        }
        networkMonitor.start()
```

- [ ] **Step 6: Strings.** `BLEUnlock/Base.lproj/Localizable.strings` (ans Ende, alphabetisch einsortieren wo vorhanden):

```
"disable_on_this_network" = "Disable on This Network";
"network_not_identified" = "Could not identify the current network (no IPv4 gateway found).";
```

`BLEUnlock/de.lproj/Localizable.strings`:

```
"disable_on_this_network" = "In diesem Netzwerk deaktivieren";
"network_not_identified" = "Aktuelles Netzwerk nicht identifizierbar (kein IPv4-Gateway gefunden).";
```

- [ ] **Step 7: pbxproj** — analog Task 3, vier Sections, zwei Dateien:

`PBXBuildFile` (nach der RSSIDecision-BuildFile-Zeile):
```
		8E6BAB7636D41F51AE698213 /* GatewayParsing.swift in Sources */ = {isa = PBXBuildFile; fileRef = 74D89DC6A5677427FD9C5C11 /* GatewayParsing.swift */; };
		FCA22F473FD28EC39CD35151 /* NetworkMonitor.swift in Sources */ = {isa = PBXBuildFile; fileRef = 5FDCBAD056B2199119AD43EE /* NetworkMonitor.swift */; };
```
`PBXFileReference` (nach der RSSIDecision-FileRef-Zeile):
```
		5FDCBAD056B2199119AD43EE /* NetworkMonitor.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = NetworkMonitor.swift; sourceTree = "<group>"; };
		74D89DC6A5677427FD9C5C11 /* GatewayParsing.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = GatewayParsing.swift; sourceTree = "<group>"; };
```
Group (nach der `RSSIDecision.swift`-Group-Zeile):
```
				74D89DC6A5677427FD9C5C11 /* GatewayParsing.swift */,
				5FDCBAD056B2199119AD43EE /* NetworkMonitor.swift */,
```
Sources-Phase (nach der `RSSIDecision.swift in Sources`-Zeile):
```
				8E6BAB7636D41F51AE698213 /* GatewayParsing.swift in Sources */,
				FCA22F473FD28EC39CD35151 /* NetworkMonitor.swift in Sources */,
```

- [ ] **Step 8: Build + Tests + Commit + Merge**

```bash
xcodebuild -project BLEUnlock.xcodeproj -scheme BLEUnlock -configuration Release CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
git checkout -- BLEUnlock/Info.plist 2>/dev/null || true
swiftc -o $SCRATCH/gateway-tests Tests/GatewayParsingTests/main.swift BLEUnlock/GatewayParsing.swift && $SCRATCH/gateway-tests
git add -A
git commit -m "Wire Wi-Fi auto-pause into multi-device AppDelegate (global pause guard)"
git checkout master
git merge --no-ff port/wifi-auto-pause -m "Merge port/wifi-auto-pause (Part B on multi-device base)"
git push fork master port/wifi-auto-pause
```

Expected: BUILD SUCCEEDED, ALL PASS.

---

### Task 6: Update-Kanal auf 7onnie umbiegen + Version

**Files:**
- Modify: `BLEUnlock/checkUpdate.swift:7`, `BLEUnlock/AboutBox.swift:9,13`, `BLEUnlock.xcodeproj/project.pbxproj` (MARKETING_VERSION), ggf. weitere Treffer.

**Interfaces:**
- Produces: Update-Checker und alle Links zeigen auf `7onnie/BLEUnlock`; lokale Builds tragen `MARKETING_VERSION 1.15.0`.

- [ ] **Step 1: Alle Verweise finden** (arbeitet auf `master`):

```bash
grep -rn "github.com/Skyearn\|github.com/ts1\|api.github.com/repos" BLEUnlock/ Launcher/ | grep -v lproj
```

- [ ] **Step 2: Ersetzen.** In `checkUpdate.swift`:

```swift
private let releasesURL = URL(string: "https://api.github.com/repos/7onnie/BLEUnlock/releases/latest")!
```

In `AboutBox.swift` beide URLs: `https://github.com/7onnie/BLEUnlock#readme` und `https://github.com/7onnie/BLEUnlock/blob/master/CHANGELOG.md`. Alle weiteren Treffer aus Step 1 in Code-Dateien ebenfalls auf `7onnie/BLEUnlock` (README/CHANGELOG-Texte kommen in Task 8).

- [ ] **Step 3: Version.** In `BLEUnlock.xcodeproj/project.pbxproj` beide Vorkommen `MARKETING_VERSION = 1.13.6;` → `MARKETING_VERSION = 1.15.0;`

- [ ] **Step 4: Build, Commit, Push**

```bash
xcodebuild -project BLEUnlock.xcodeproj -scheme BLEUnlock -configuration Release CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
git checkout -- BLEUnlock/Info.plist 2>/dev/null || true
git add -A && git commit -m "Point update channel and links at 7onnie/BLEUnlock, version 1.15.0" && git push fork master
```

---

### Task 7: In-App-Update-Installer (Zip-Asset) — TDD für den puren Teil

**Files:**
- Create: `BLEUnlock/UpdateAssets.swift`, `BLEUnlock/UpdateInstaller.swift`, `Tests/UpdateAssetsTests/main.swift`
- Modify: `BLEUnlock/checkUpdate.swift` (Asset-Auswahl), `BLEUnlock/AppDelegate.swift` (`checkForUpdates`), beide `Localizable.strings`, `BLEUnlock.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `UpdateCheckResult.available(version:downloadURL:releaseURL:)` (Skyearn, unverändert), `errorModal(_:info:)`.
- Produces: `func preferredUpdateAssetName(_ names: [String]) -> String?` (zip vor dmg); `func installUpdate(fromZip: URL, completion: @escaping (String?) -> Void)` (nil = Erfolg, sonst Fehlertext; ersetzt Bundle + relauncht).

- [ ] **Step 1: Failing Test** — `Tests/UpdateAssetsTests/main.swift`:

```swift
import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("ok   - \(msg)") } else { print("FAIL - \(msg)"); failures += 1 }
}

check(preferredUpdateAssetName(["BLEUnlock-v1.15.0.dmg", "BLEUnlock-v1.15.0.zip"]) == "BLEUnlock-v1.15.0.zip",
      "zip preferred over dmg")
check(preferredUpdateAssetName(["BLEUnlock-v1.15.0.dmg"]) == "BLEUnlock-v1.15.0.dmg",
      "dmg fallback when no zip")
check(preferredUpdateAssetName(["Source.tar.gz"]) == nil,
      "unknown assets -> nil")
check(preferredUpdateAssetName([]) == nil, "empty -> nil")
check(preferredUpdateAssetName(["A.ZIP"]) == "A.ZIP", "case-insensitive match")

if failures == 0 { print("\nALL PASS") } else { print("\n\(failures) FAILURE(S)"); exit(1) }
```

Run: `swiftc -o $SCRATCH/updateassets-tests Tests/UpdateAssetsTests/main.swift 2>&1 | head -3` → Expected: FAIL `cannot find 'preferredUpdateAssetName'`

- [ ] **Step 2: `BLEUnlock/UpdateAssets.swift`:**

```swift
import Foundation

/// Pick the release asset the in-app installer can handle: a .zip lets us
/// download via URLSession (no quarantine) and swap the bundle in place;
/// a .dmg is only offered as a browser download.
func preferredUpdateAssetName(_ names: [String]) -> String? {
    if let zip = names.first(where: { $0.lowercased().hasSuffix(".zip") }) {
        return zip
    }
    return names.first(where: { $0.lowercased().hasSuffix(".dmg") })
}
```

Run: `swiftc -o $SCRATCH/updateassets-tests Tests/UpdateAssetsTests/main.swift BLEUnlock/UpdateAssets.swift && $SCRATCH/updateassets-tests` → Expected: ALL PASS

- [ ] **Step 3: `checkUpdate.swift` — Asset-Auswahl ersetzen.** Funktion `latestDMGDownloadURL` ersetzen durch:

```swift
private func preferredDownloadURL(from assets: [ReleaseAsset]) -> URL? {
    guard let name = preferredUpdateAssetName(assets.map({ $0.name })) else { return nil }
    return assets.first { $0.name == name }?.downloadURL
}
```

und in `compareVersions` den Aufruf `latestDMGDownloadURL(from: releaseInfo.assets)` → `preferredDownloadURL(from: releaseInfo.assets)`.

- [ ] **Step 4: `BLEUnlock/UpdateInstaller.swift`:**

```swift
import Cocoa

/// Downloads a release .zip, unpacks it, strips quarantine, replaces the running
/// app bundle and relaunches. Needed because fork releases are only ad-hoc signed:
/// a browser download would trip Gatekeeper on every single update, while a
/// URLSession download from the app itself is not quarantined.
func installUpdate(fromZip zipURL: URL, completion: @escaping (String?) -> Void) {
    let task = URLSession.shared.downloadTask(with: zipURL) { tempFile, _, error in
        if let error = error {
            completion(error.localizedDescription)
            return
        }
        guard let tempFile = tempFile else {
            completion("Download produced no file")
            return
        }
        do {
            let fm = FileManager.default
            let workDir = fm.temporaryDirectory
                .appendingPathComponent("BLEUnlockUpdate-\(UUID().uuidString)")
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
            try runTool("/usr/bin/ditto", ["-xk", tempFile.path, workDir.path])

            guard let appName = try fm.contentsOfDirectory(atPath: workDir.path)
                .first(where: { $0.hasSuffix(".app") }) else {
                completion("No .app found in update archive")
                return
            }
            let newApp = workDir.appendingPathComponent(appName)
            // Belt and braces: strip quarantine in case a future macOS quarantines
            // URLSession downloads after all.
            try? runTool("/usr/bin/xattr", ["-cr", newApp.path])

            let currentApp = Bundle.main.bundleURL
            _ = try fm.replaceItemAt(currentApp, withItemAt: newApp,
                                     backupItemName: nil, options: [])
            completion(nil)
            DispatchQueue.main.async { relaunch(appURL: currentApp) }
        } catch {
            completion(error.localizedDescription)
        }
    }
    task.resume()
}

private func runTool(_ path: String, _ args: [String]) throws {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    try proc.run()
    proc.waitUntilExit()
    if proc.terminationStatus != 0 {
        throw NSError(domain: "UpdateInstaller", code: Int(proc.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "\(path) exited with \(proc.terminationStatus)"])
    }
}

private func relaunch(appURL: URL) {
    // Give the terminating process a moment to exit before the new one starts.
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = ["-c", "sleep 1; /usr/bin/open -n \"\(appURL.path)\""]
    try? proc.run()
    NSApp.terminate(nil)
}
```

- [ ] **Step 5: `AppDelegate.checkForUpdates` verdrahten.** Im `.available`-Zweig den Block

```swift
                    if response == .alertFirstButtonReturn {
                        if let downloadURL {
                            NSWorkspace.shared.open(downloadURL)
                        } else {
                            NSWorkspace.shared.open(releaseURL)
                        }
                    } else if downloadURL != nil && response == .alertSecondButtonReturn {
```

ersetzen durch:

```swift
                    if response == .alertFirstButtonReturn {
                        if let downloadURL, downloadURL.pathExtension.lowercased() == "zip" {
                            installUpdate(fromZip: downloadURL) { errorMessage in
                                if let errorMessage {
                                    DispatchQueue.main.async {
                                        self.errorModal(t("update_install_failed"), info: errorMessage)
                                    }
                                }
                            }
                        } else if let downloadURL {
                            NSWorkspace.shared.open(downloadURL)
                        } else {
                            NSWorkspace.shared.open(releaseURL)
                        }
                    } else if downloadURL != nil && response == .alertSecondButtonReturn {
```

und den Button-Titel dynamisch machen — die Zeile `alert.addButton(withTitle: t("download_update"))` ersetzen durch:

```swift
                        let isZip = downloadURL?.pathExtension.lowercased() == "zip"
                        alert.addButton(withTitle: t(isZip ? "install_update" : "download_update"))
```

- [ ] **Step 6: Strings.** Base:

```
"install_update" = "Install Update";
"update_install_failed" = "Failed to Install Update";
```

de:

```
"install_update" = "Update installieren";
"update_install_failed" = "Update-Installation fehlgeschlagen";
```

- [ ] **Step 7: pbxproj** — analog Task 3, zwei Dateien mit diesen IDs:

`PBXBuildFile`:
```
		AA1001500000000000000002 /* UpdateAssets.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA1001500000000000000001 /* UpdateAssets.swift */; };
		AA1001500000000000000004 /* UpdateInstaller.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA1001500000000000000003 /* UpdateInstaller.swift */; };
```
`PBXFileReference`:
```
		AA1001500000000000000001 /* UpdateAssets.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = UpdateAssets.swift; sourceTree = "<group>"; };
		AA1001500000000000000003 /* UpdateInstaller.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = UpdateInstaller.swift; sourceTree = "<group>"; };
```
Group:
```
				AA1001500000000000000001 /* UpdateAssets.swift */,
				AA1001500000000000000003 /* UpdateInstaller.swift */,
```
Sources-Phase:
```
				AA1001500000000000000002 /* UpdateAssets.swift in Sources */,
				AA1001500000000000000004 /* UpdateInstaller.swift in Sources */,
```

- [ ] **Step 8: Quarantäne-Vorbedingung prüfen (Spec Abschnitt 4)**

```bash
grep -c LSFileQuarantineEnabled BLEUnlock/Info.plist || echo "OK: not set"
```

Expected: `OK: not set` — wäre der Key gesetzt, würden URLSession-Downloads quarantiniert und der Installer-Ansatz kippt. Dann STOPP und Reviewer informieren.

- [ ] **Step 9: Build + Commit + Push**

```bash
xcodebuild -project BLEUnlock.xcodeproj -scheme BLEUnlock -configuration Release CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
git checkout -- BLEUnlock/Info.plist 2>/dev/null || true
git add -A && git commit -m "Add in-app zip update installer (no-quarantine path for unsigned releases)" && git push fork master
```

---

### Task 8: Release-Pipeline, CHANGELOG, README

**Files:**
- Modify: `.github/workflows/release.yml`, `CHANGELOG.md`, `README.md`

**Interfaces:**
- Produces: Tag-Push `v*` baut ad-hoc-signierte App, lädt `.zip` + `.dmg` als Release-Assets hoch. Kein Homebrew-Step mehr.

- [ ] **Step 1: `release.yml` — Ad-hoc-Fallback.** Im Step "Code Sign App" den Block

```yaml
          if [ -z "${MACOS_SIGNING_IDENTITY}" ]; then
            echo "MACOS_SIGNING_IDENTITY is not set. Skipping code signing."
            exit 0
          fi
```

ersetzen durch:

```yaml
          APP_PATH="build/Build/Products/Release/BLEUnlock.app"
          if [ -z "${MACOS_SIGNING_IDENTITY}" ]; then
            echo "MACOS_SIGNING_IDENTITY is not set. Ad-hoc signing instead."
            /usr/bin/codesign --force --deep --sign - "${APP_PATH}"
            exit 0
          fi
```

(Die beiden nachfolgenden Zeilen `APP_PATH=...`/`ENTITLEMENTS_PATH=...` des Identity-Zweigs bleiben stehen.)

- [ ] **Step 2: Zip-Asset.** Im Step "Package DMG" nach der `mv ...dmg`-Zeile ergänzen:

```yaml
          /usr/bin/ditto -c -k --keepParent "${APP_PATH}" "${DEST_DIR}/BLEUnlock-${RELEASE_TAG}.zip"
```

(davor `APP_PATH`/`DEST_DIR` sind in dem Step schon definiert). Im Step "Create or Update GitHub Release" beide `gh release`-Aufrufe um das Zip erweitern: nach jeder `"${DMG_PATH}"`-Zeile zusätzlich

```yaml
              "build/Build/Products/Release/BLEUnlock-${RELEASE_TAG}.zip" \
```

bzw. beim `upload`: `gh release upload "${RELEASE_TAG}" "${DMG_PATH}" "build/Build/Products/Release/BLEUnlock-${RELEASE_TAG}.zip" --clobber`

- [ ] **Step 3: Homebrew-Step entfernen.** Den kompletten Step `- name: Update Homebrew Tap` (bis Dateiende) löschen — er würde in Skyearns Tap pushen.

- [ ] **Step 4: CHANGELOG.md** — oben nach der Titelzeile neuen Abschnitt:

```markdown
## 1.15.0

- Maintained fork continues at [7onnie/BLEUnlock](https://github.com/7onnie/BLEUnlock) (based on Skyearn/BLEUnlock 1.14.x)
- Unlock is now gated on the smoothed (median-filtered) RSSI plus a minimum sample count — a single spurious RSSI spike can no longer unlock the Mac
- New "Disable on This Network" menu item: BLEUnlock pauses automatically outside allow-listed networks, keyed on the default gateway's MAC address (permission-free)
- In-app update installer for fork releases (zip asset, no Gatekeeper friction)
- Update checker now follows 7onnie/BLEUnlock releases
```

- [ ] **Step 5: README.md** — direkt nach der Haupt-Titelzeile einfügen:

```markdown
> **Maintained fork.** Upstream [ts1/BLEUnlock](https://github.com/ts1/BLEUnlock) is inactive.
> This fork is based on [Skyearn/BLEUnlock](https://github.com/Skyearn/BLEUnlock) (macOS 26
> compatibility, multi-device support) and adds a smoothed-RSSI unlock gate and Wi-Fi
> auto-pause. Credits to Takeshi Sone and Skyearn.
>
> **Installing:** releases are ad-hoc signed (no Apple Developer ID). On first install,
> macOS will refuse to open the app. Either allow it under *System Settings → Privacy &
> Security → Open Anyway*, or run:
> `xattr -dr com.apple.quarantine /Applications/BLEUnlock.app`
> Subsequent updates installed via the in-app updater need no further approval.
```

- [ ] **Step 6: Commit + Push**

```bash
git add .github/workflows/release.yml CHANGELOG.md README.md
git commit -m "Release pipeline: ad-hoc signing fallback, zip asset, drop Homebrew tap; fork README + changelog"
git push fork master
```

---

### Task 9: Release v1.15.0 + Installation + Smoke-Test

**Files:** keine (Git-Tag, GitHub-Action, manuelle Verifikation).

- [ ] **Step 1: Taggen**

```bash
git tag v1.15.0
git push fork v1.15.0
```

- [ ] **Step 2: Action beobachten**

```bash
gh run watch --repo 7onnie/BLEUnlock --exit-status $(gh run list --repo 7onnie/BLEUnlock --workflow=Release --limit 1 --json databaseId --jq '.[0].databaseId')
gh release view v1.15.0 --repo 7onnie/BLEUnlock --json assets --jq '.assets[].name'
```

Expected: Run `completed success`; Assets `BLEUnlock-v1.15.0.dmg` und `BLEUnlock-v1.15.0.zip`.

- [ ] **Step 3: Signatur des Artefakts prüfen**

```bash
cd $SCRATCH && gh release download v1.15.0 --repo 7onnie/BLEUnlock --pattern '*.zip' --clobber
ditto -xk BLEUnlock-v1.15.0.zip extracted && codesign -dv extracted/BLEUnlock.app 2>&1 | head -3
```

Expected: `Signature=adhoc`

- [ ] **Step 4: Manueller Install + Smoke-Test (User-Mac, Checkliste):**
  1. App nach /Applications, Quarantäne freigeben (README-Weg), starten.
  2. Menü zeigt "Disable on This Network"; Toggle im Heimnetz → Monitoring läuft (Startup-Default ist paused, Toggle im erlaubten Netz aktiviert).
  3. Gerät verbinden, Unlock-Verhalten beobachten: kein Unlock in den ersten ~3 Samples nach Start (Warm-up-Gate).
  4. "Check for Updates…" → "BLEUnlock is up to date."

---

### Task 10: E2E-Update-Test (v1.15.1)

**Files:**
- Modify: `CHANGELOG.md` (Mini-Eintrag)

- [ ] **Step 1: Test-Release bauen**

```bash
printf '## 1.15.1\n\n- Update-pipeline end-to-end test release\n\n' > $SCRATCH/changelog-entry && sed -i '' "2r $SCRATCH/changelog-entry" CHANGELOG.md
git add CHANGELOG.md && git commit -m "Changelog for 1.15.1 (update-path e2e test)" && git push fork master
git tag v1.15.1 && git push fork v1.15.1
gh run watch --repo 7onnie/BLEUnlock --exit-status $(gh run list --repo 7onnie/BLEUnlock --workflow=Release --limit 1 --json databaseId --jq '.[0].databaseId')
```

- [ ] **Step 2: Auf dem Mac mit installierter v1.15.0:** "Check for Updates…" → Dialog "BLEUnlock v1.15.1 is available" mit Button **Install Update** → klicken.

Expected: App beendet sich, startet neu; About-Box zeigt 1.15.1; `xattr -l /Applications/BLEUnlock.app` zeigt KEIN `com.apple.quarantine`; App entsperrt weiterhin.

- [ ] **Step 3: Ergebnis dokumentieren** — bei Erfolg ist der Update-Kanal verifiziert; bei Fehlschlag: Fehlerbild notieren, NICHT weiter taggen, Installer-Task nacharbeiten.

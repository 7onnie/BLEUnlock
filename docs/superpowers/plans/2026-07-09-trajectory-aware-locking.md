# Trajectory-Aware Locking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sperr-Latenz senken, indem die RSSI-Trajektorie (Steigung + Tiefe unter Schwelle) die Sperr-Verzögerung bestimmt — adaptiver Proximity-Debounce und adaptives Signal-Loss-Intervall. Entsperren bleibt unangetastet.

**Architecture:** Neues pures, swiftc-testbares Modul `LockDecision.swift` (drei reine Funktionen + Konstanten). Integration an genau zwei Stellen in `BLE.swift`: die Proximity-Timer-Dauer (einmal beim Timer-Start berechnet) und das Signal-Timer-Intervall in `resetSignalTimer` (pro Read neu, „friert" beim Signalverlust ein). Ein neues Feld `estimatedHistory` in `MonitoredDeviceState` liefert die geglättete Historie für die Steigung.

**Tech Stack:** Swift (CoreBluetooth), `swiftc`-Testsuiten (kein XCTest), Xcode-Projekt.

## Global Constraints

- Arbeitsverzeichnis: `/Users/user/GitHubRepos/BLEUnlock-src`. Remote `fork` (SSH) = 7onnie/BLEUnlock.
- **Invariante:** Adaptive Logik sperrt NUR schneller als die konfigurierten `proximityTimeout`/`signalTimeout`, NIE langsamer. Diese bleiben Obergrenzen.
- **Entsperr-Pfad (`shouldUnlock`, RSSIDecision.swift) NICHT anfassen.**
- Nach jedem `xcodebuild`: falls `git status` `BLEUnlock/Info.plist` als geändert zeigt → `git checkout -- BLEUnlock/Info.plist` VOR dem Commit.
- SCRATCH für Test-Binaries: `/private/tmp/claude-503/-Users-user-GitHubRepos-BLEUnlock/8369d4f4-3922-4b5f-b708-df31bde3323a/scratchpad`
- Swift-Code folgt dem Stil der umgebenden Datei.
- Konstanten (verbatim aus Spec): `SLOPE_WINDOW = 5`, `FALLING_SLOPE = -1.5`, `MIN_PROXIMITY_DELAY = 2.0`, `TREND_LOSS_DELAY = 3.0`, `DROPOUT_GRACE_STRONG = 15.0`, `DROPOUT_GRACE_WEAK = 5.0`, `STRONG_RSSI = -70`.
- Nach jedem Task committen + `git push fork master` (bzw. den Feature-Branch). Vor Push `git fetch fork` + ggf. `git rebase fork/master` (ein anderer Agent pusht evtl. parallel auf master — nur-additive Commits rebasen konfliktfrei).

---

### Task 1: Pures Modul `LockDecision.swift` + swiftc-Tests + pbxproj

**Files:**
- Create: `BLEUnlock/LockDecision.swift`
- Create: `Tests/LockDecisionTests/main.swift`
- Modify: `BLEUnlock.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces (konsumiert Task 2):
  - `let SLOPE_WINDOW = 5`, `let MIN_PROXIMITY_DELAY = 2.0`, `let STRONG_RSSI = -70` (und die übrigen Konstanten) auf File-Ebene.
  - `func rssiSlope(_ history: [Int]) -> Double`
  - `func adaptiveLockDelay(estimatedRSSI: Int, lockThreshold: Int, slope: Double, baseDelay: TimeInterval) -> TimeInterval`
  - `func signalLossDelay(slope: Double, lastEstimatedRSSI: Int, cap: TimeInterval) -> TimeInterval`

- [ ] **Step 1: Branch anlegen**

```bash
cd /Users/user/GitHubRepos/BLEUnlock-src
git fetch fork && git checkout -b feature/trajectory-aware-locking fork/master
```

- [ ] **Step 2: Failing Test schreiben** — `Tests/LockDecisionTests/main.swift`:

```swift
import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("ok   - \(msg)") } else { print("FAIL - \(msg)"); failures += 1 }
}
func approx(_ a: Double, _ b: Double, _ eps: Double = 0.001) -> Bool { abs(a - b) <= eps }

// rssiSlope
check(rssiSlope([]) == 0, "empty history -> slope 0")
check(rssiSlope([-60]) == 0, "single sample -> slope 0")
check(rssiSlope([-50, -50, -50, -50, -50]) == 0, "constant -> slope 0")
check(rssiSlope([-50, -55, -60, -65, -70]) < 0, "monotonic falling -> negative")
check(rssiSlope([-70, -65, -60, -55, -50]) > 0, "monotonic rising -> positive")
check(approx(rssiSlope([-50, -55, -60, -65, -70]), -5.0), "perfect -5/sample line -> -5.0")
check(rssiSlope([-60, -58, -66, -64, -72]) < 0, "noisy but falling -> negative")

// adaptiveLockDelay — base 5s, min 2s, lockThreshold -80
// marginally below threshold, flat slope -> near baseDelay
check(approx(adaptiveLockDelay(estimatedRSSI: -81, lockThreshold: -80, slope: 0, baseDelay: 5.0), 5.0, 0.4),
      "just below threshold, flat -> ~baseDelay")
// deep below threshold (>=15dB) -> min delay
check(adaptiveLockDelay(estimatedRSSI: -96, lockThreshold: -80, slope: 0, baseDelay: 5.0) == 2.0,
      "15dB+ below threshold -> MIN_PROXIMITY_DELAY")
// steep falling slope -> min delay even if shallow depth
check(adaptiveLockDelay(estimatedRSSI: -81, lockThreshold: -80, slope: -3.0, baseDelay: 5.0) == 2.0,
      "steep slope (2*FALLING) -> MIN_PROXIMITY_DELAY")
// result always within [MIN, base]
let d = adaptiveLockDelay(estimatedRSSI: -85, lockThreshold: -80, slope: -0.5, baseDelay: 5.0)
check(d >= 2.0 && d <= 5.0, "result clamped to [MIN, base]")
// invariant: baseDelay below MIN -> never longer than base
check(adaptiveLockDelay(estimatedRSSI: -96, lockThreshold: -80, slope: -5, baseDelay: 1.0) == 1.0,
      "baseDelay < MIN -> returns baseDelay (never slower than configured)")

// signalLossDelay — cap 60s
check(signalLossDelay(slope: -2.0, lastEstimatedRSSI: -60, cap: 60) == 3.0,
      "falling trend -> TREND_LOSS_DELAY")
check(signalLossDelay(slope: 0, lastEstimatedRSSI: -60, cap: 60) == 15.0,
      "no trend + strong signal -> DROPOUT_GRACE_STRONG")
check(signalLossDelay(slope: 0, lastEstimatedRSSI: -75, cap: 60) == 5.0,
      "no trend + weak signal -> DROPOUT_GRACE_WEAK")
check(signalLossDelay(slope: 0, lastEstimatedRSSI: -60, cap: 10) == 10.0,
      "cap below result -> capped")

if failures == 0 { print("\nALL PASS") } else { print("\n\(failures) FAILURE(S)"); exit(1) }
```

- [ ] **Step 3: Test kompilieren, Fehlschlag sehen**

```bash
SCRATCH=/private/tmp/claude-503/-Users-user-GitHubRepos-BLEUnlock/8369d4f4-3922-4b5f-b708-df31bde3323a/scratchpad
swiftc -o $SCRATCH/lockdecision-tests Tests/LockDecisionTests/main.swift 2>&1 | head -3
```
Expected: FAIL mit `cannot find 'rssiSlope' in scope` (o.ä.).

- [ ] **Step 4: Implementation** — `BLEUnlock/LockDecision.swift`:

```swift
import Foundation

// Trajectory-aware locking tunables (internal, no UI). See design spec 2026-07-09.
let SLOPE_WINDOW = 5             // smoothed samples used for the slope (~5s @1Hz)
let FALLING_SLOPE = -1.5         // dB/sample; <= this counts as a falling trend
let MIN_PROXIMITY_DELAY = 2.0    // floor for the adaptive proximity debounce (s)
let TREND_LOSS_DELAY = 3.0       // signal lost after a falling trend (s)
let DROPOUT_GRACE_STRONG = 15.0  // signal lost from a strong, stable signal (s)
let DROPOUT_GRACE_WEAK = 5.0     // signal lost from an already-weak signal (s)
let STRONG_RSSI = -70            // >= this is "strong" for the dropout tiering

/// Least-squares slope (dB per sample) over the smoothed RSSI history.
/// Negative = falling. Fewer than 2 samples → 0 (no trend determinable).
func rssiSlope(_ history: [Int]) -> Double {
    let n = history.count
    guard n >= 2 else { return 0 }
    let xs = (0..<n).map(Double.init)
    let ys = history.map(Double.init)
    let meanX = xs.reduce(0, +) / Double(n)
    let meanY = ys.reduce(0, +) / Double(n)
    var num = 0.0, den = 0.0
    for i in 0..<n {
        num += (xs[i] - meanX) * (ys[i] - meanY)
        den += (xs[i] - meanX) * (xs[i] - meanX)
    }
    return den == 0 ? 0 : num / den
}

/// Adaptive proximity debounce for "level below lock threshold, signal still present".
/// Shortens baseDelay toward MIN_PROXIMITY_DELAY the more urgent the departure looks
/// (deeper below threshold and/or steeper downward slope). Never longer than baseDelay.
func adaptiveLockDelay(estimatedRSSI: Int, lockThreshold: Int, slope: Double, baseDelay: TimeInterval) -> TimeInterval {
    guard baseDelay > MIN_PROXIMITY_DELAY else { return baseDelay }
    let depth = Double(max(0, lockThreshold - estimatedRSSI))
    let depthUrgency = min(1.0, depth / 15.0)
    // slope at/above FALLING_SLOPE contributes nothing; at 2*FALLING_SLOPE (steeper) → full.
    let slopeUrgency: Double
    if slope >= FALLING_SLOPE {
        slopeUrgency = 0
    } else {
        slopeUrgency = min(1.0, (FALLING_SLOPE - slope) / (-FALLING_SLOPE))
    }
    let u = max(depthUrgency, slopeUrgency)
    let delay = baseDelay - u * (baseDelay - MIN_PROXIMITY_DELAY)
    return min(baseDelay, max(MIN_PROXIMITY_DELAY, delay))
}

/// Interval for the signal-loss timer, chosen from the trajectory at the last read.
/// Falling trend → short; trendless loss tiered by signal strength. Capped by `cap`
/// (= configured signalTimeout) so it is never slower than configured.
func signalLossDelay(slope: Double, lastEstimatedRSSI: Int, cap: TimeInterval) -> TimeInterval {
    let base: TimeInterval
    if slope <= FALLING_SLOPE {
        base = TREND_LOSS_DELAY
    } else if lastEstimatedRSSI < STRONG_RSSI {
        base = DROPOUT_GRACE_WEAK
    } else {
        base = DROPOUT_GRACE_STRONG
    }
    return min(base, cap)
}
```

- [ ] **Step 5: Test läuft grün**

```bash
swiftc -o $SCRATCH/lockdecision-tests Tests/LockDecisionTests/main.swift BLEUnlock/LockDecision.swift && $SCRATCH/lockdecision-tests
```
Expected: alle `ok`, `ALL PASS`.

- [ ] **Step 6: pbxproj — LockDecision.swift ins Target** (Muster von RSSIDecision.swift, IDs fileRef `CC3003500000000000000001`, buildFile `CC3003500000000000000002`).

In `PBXBuildFile` nach der Zeile `680CDE71110749891F5AA1E4 /* RSSIDecision.swift in Sources */ = ...`:
```
		CC3003500000000000000002 /* LockDecision.swift in Sources */ = {isa = PBXBuildFile; fileRef = CC3003500000000000000001 /* LockDecision.swift */; };
```
In `PBXFileReference` nach der Zeile `B5D0346CA6A4625F6C40E69D /* RSSIDecision.swift */ = ...`:
```
		CC3003500000000000000001 /* LockDecision.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = LockDecision.swift; sourceTree = "<group>"; };
```
In der Group nach `B5D0346CA6A4625F6C40E69D /* RSSIDecision.swift */,`:
```
				CC3003500000000000000001 /* LockDecision.swift */,
```
In der Sources-Build-Phase nach `680CDE71110749891F5AA1E4 /* RSSIDecision.swift in Sources */,`:
```
				CC3003500000000000000002 /* LockDecision.swift in Sources */,
```

- [ ] **Step 7: Build + Tests**

```bash
xcodebuild -project BLEUnlock.xcodeproj -scheme BLEUnlock -configuration Release CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
git checkout -- BLEUnlock/Info.plist 2>/dev/null || true
swiftc -o $SCRATCH/lockdecision-tests Tests/LockDecisionTests/main.swift BLEUnlock/LockDecision.swift && $SCRATCH/lockdecision-tests | tail -1
```
Expected: `** BUILD SUCCEEDED **` und `ALL PASS`.

- [ ] **Step 8: Commit + Push**

```bash
git add BLEUnlock/LockDecision.swift Tests/LockDecisionTests/main.swift BLEUnlock.xcodeproj/project.pbxproj
git commit -m "Add pure LockDecision module (slope + adaptive lock/signal-loss delays) with tests"
git push fork feature/trajectory-aware-locking
```

---

### Task 2: Integration in `BLE.swift` + Merge

**Files:**
- Modify: `BLEUnlock/BLE.swift` (`MonitoredDeviceState` ~Zeile 326–340; `suspendMonitoringForSystemSleep` ~515; `resetSignalTimer` ~652; `updateMonitoredState` ~718; `clearSmoothingWindows` ~761)

**Interfaces:**
- Consumes (aus Task 1): `SLOPE_WINDOW`, `rssiSlope(_:)`, `adaptiveLockDelay(...)`, `signalLossDelay(...)`.
- Produces: `MonitoredDeviceState.estimatedHistory: [Int]`.

Hinweis: Zeilennummern können durch parallele Commits leicht abweichen — Anker per Inhalt (Funktionsname / exakte Zeile) suchen, nicht per Nummer.

- [ ] **Step 1: Feld `estimatedHistory` in `MonitoredDeviceState`.** Direkt nach `var rssiWindow: [Int] = []`:

```swift
    var estimatedHistory: [Int] = []   // smoothed RSSI history for trajectory/slope
```

- [ ] **Step 2: Reset-Pfade ergänzen.** An jeder Stelle, die `state.rssiWindow.removeAll()` aufruft, unmittelbar danach `state.estimatedHistory.removeAll()` ergänzen. Betrifft vier Stellen:
  - in `suspendMonitoringForSystemSleep` (nach der `state.rssiWindow.removeAll()`-Zeile im `for`-Loop),
  - in `startMonitor(uuids:)` (die zweite Fundstelle, im Reseed-Loop),
  - im Signal-Loss-Block innerhalb `resetSignalTimer` (nach `state.rssiWindow.removeAll()`),
  - in `centralManagerDidUpdateState`/Power-off-Pfad (die Fundstelle nahe `state.presence = false`).

  Und in `clearSmoothingWindows()` den Loop erweitern:
```swift
    func clearSmoothingWindows() {
        for state in monitoredStates.values {
            state.rssiWindow.removeAll()
            state.estimatedHistory.removeAll()
            state.lastRSSI = nil
        }
    }
```
  (Verifiziere per `grep -n "rssiWindow.removeAll" BLEUnlock/BLE.swift`, dass jede Fundstelle ein `estimatedHistory.removeAll()` daneben hat.)

- [ ] **Step 3: `updateMonitoredState` — Historie füllen + adaptive Proximity-Dauer.** Der bestehende Kopf lautet:

```swift
    func updateMonitoredState(_ state: MonitoredDeviceState, rssi: Int) {
        // Smooth first, so every decision below uses the median-filtered value.
        let estimatedRSSI = getEstimatedRSSI(state: state, rssi: rssi)
        state.lastRSSI = estimatedRSSI
        updateAggregateRSSI()
```
Direkt nach `state.lastRSSI = estimatedRSSI` einfügen:
```swift
        state.estimatedHistory.append(estimatedRSSI)
        if state.estimatedHistory.count > SLOPE_WINDOW {
            state.estimatedHistory.removeFirst()
        }
        let slope = rssiSlope(state.estimatedHistory)
```
Dann den `proximityTimer`-Start-Block. Aktuell:
```swift
        } else if state.presence && state.proximityTimer == nil {
            state.proximityTimer = Timer.scheduledTimer(withTimeInterval: proximityTimeout, repeats: false, block: { [weak self, weak state] _ in
```
ersetzen durch (nur die `withTimeInterval`-Berechnung ändert sich; der Block-Inhalt bleibt identisch):
```swift
        } else if state.presence && state.proximityTimer == nil {
            let lockThresh = (lockRSSI == LOCK_DISABLED ? unlockRSSI : lockRSSI)
            let base = proximityTimeout
            let delay = state.estimatedHistory.count >= SLOPE_WINDOW
                ? adaptiveLockDelay(estimatedRSSI: estimatedRSSI, lockThreshold: lockThresh, slope: slope, baseDelay: base)
                : base
            print("Proximity timer for \(state.uuid): slope \(String(format: "%.2f", slope)), delay \(String(format: "%.1f", delay))s (base \(base)s)")
            state.proximityTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false, block: { [weak self, weak state] _ in
```
(Der Rest des Blocks — `guard`, `state.presence = false`, `updateAggregatePresence(reason: "away")`, `state.proximityTimer = nil`, `}` und das `RunLoop.main.add` — bleibt unverändert.)

- [ ] **Step 4: `resetSignalTimer` — adaptives Intervall.** Aktueller Kopf:
```swift
    func resetSignalTimer(for state: MonitoredDeviceState) {
        state.signalTimer?.invalidate()
        state.signalTimer = Timer.scheduledTimer(withTimeInterval: signalTimeout, repeats: false, block: { [weak self, weak state] _ in
```
ersetzen durch:
```swift
    func resetSignalTimer(for state: MonitoredDeviceState) {
        state.signalTimer?.invalidate()
        let slope = rssiSlope(state.estimatedHistory)
        let interval = state.estimatedHistory.count >= SLOPE_WINDOW
            ? signalLossDelay(slope: slope, lastEstimatedRSSI: state.lastRSSI ?? 0, cap: signalTimeout)
            : signalTimeout
        state.signalTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false, block: { [weak self, weak state] _ in
```
(Block-Inhalt unverändert. Hinweis: `state.lastRSSI ?? 0` — 0 ≥ STRONG_RSSI, fällt also auf die konservative STRONG-Karenz zurück, falls `lastRSSI` unerwartet nil ist.)

- [ ] **Step 5: Build + pure Tests weiterhin grün**

```bash
xcodebuild -project BLEUnlock.xcodeproj -scheme BLEUnlock -configuration Release CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
git checkout -- BLEUnlock/Info.plist 2>/dev/null || true
SCRATCH=/private/tmp/claude-503/-Users-user-GitHubRepos-BLEUnlock/8369d4f4-3922-4b5f-b708-df31bde3323a/scratchpad
swiftc -o $SCRATCH/lockdecision-tests Tests/LockDecisionTests/main.swift BLEUnlock/LockDecision.swift && $SCRATCH/lockdecision-tests | tail -1
grep -c "estimatedHistory.removeAll" BLEUnlock/BLE.swift   # erwartet: >= 4 (alle Reset-Pfade + clearSmoothingWindows)
```
Expected: `** BUILD SUCCEEDED **`, `ALL PASS`, und der grep-Count deckt alle `rssiWindow.removeAll`-Stellen ab.

- [ ] **Step 6: Commit, Merge nach master, Push**

```bash
git add BLEUnlock/BLE.swift
git commit -m "Integrate trajectory-aware locking into BLE (adaptive proximity + signal-loss delays)"
git fetch fork && git checkout master && git rebase fork/master
git merge --no-ff feature/trajectory-aware-locking -m "Merge trajectory-aware locking"
git push fork master feature/trajectory-aware-locking
```

---

### Task 3: Manuelle Verifikation + Changelog + Release

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Changelog-Eintrag.** Neuen Abschnitt nach der Titelzeile `# Release Notes`:
```markdown
## 1.15.5

- Faster, smarter auto-lock: BLEUnlock now reacts to the *trajectory* of the signal, not just its level. Walking away (a falling signal that then drops out) locks in a few seconds instead of waiting the full no-signal timeout, while a brief Bluetooth dropout while you're present still waits a short grace period. Unlocking is unchanged.
```
Committen + pushen (mit rebase wie oben).

- [ ] **Step 2: Manueller Test auf dem Mac (Checkliste, kann der User fahren):**
  1. Weggehen bei fallendem Signal → Mac sperrt spürbar schneller als bisher (~wenige Sekunden statt bis zu 60 s).
  2. iPhone kurz in die Tasche / kurzer BT-Aussetzer, während man da ist → Mac sperrt NICHT sofort (Karenz greift).
  3. Ankommen → Entsperren so schnell/konservativ wie bisher (Verhalten unverändert).
  4. Logs prüfen (`Console.app`/`print`): „Proximity timer … slope … delay …s" und die Signal-Loss-Intervalle plausibel.

- [ ] **Step 3: Release taggen** (erst nach erfolgreicher manueller Verifikation):
```bash
git tag v1.15.5 && git push fork v1.15.5
```
Release-Action beobachten (`gh run watch …`), Assets prüfen. Signatur bleibt stabil (self-signed), keine erneute Rechte-Abfrage.

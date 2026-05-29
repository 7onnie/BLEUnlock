# BLEUnlock — RSSI Unlock Debounce & Wi-Fi Auto-Pause

**Date:** 2026-05-30
**Status:** Approved design, ready for implementation planning
**Upstream:** `ts1/BLEUnlock` (master @ `2eeb35d`)

## Problem

When at home (on the home Wi-Fi), BLEUnlock produces many false-positive unlocks —
the Mac auto-unlocks while the paired device is far away, at distances where the
reported RSSI cannot plausibly be valid.

### Root cause

In `BLE.swift`, `updateMonitoredPeripheral(_:)`, the **unlock / presence transition
uses a single raw RSSI sample**:

```swift
if rssi >= (unlockRSSI == UNLOCK_DISABLED ? lockRSSI : unlockRSSI) && !presence {
    presence = true
    delegate?.updatePresence(presence: presence, reason: "close")
    latestRSSIs.removeAll()
}
```

The moving average (`getEstimatedRSSI`, merged in PR #4) is computed *afterwards* and
used **only for the lock decision** (proximity timer). A single spurious strong reading
— multipath reflection in a reflective home environment dense with 2.4 GHz devices, or
a Bluetooth advertising burst — is therefore sufficient to flip presence to `true` and
unlock the Mac. This is the false-positive bug.

### Related upstream issues
- #142 — Enable/Disable lock/unlock based on Wi-Fi SSID
- #155 — Different lock/unlock thresholds per Wi-Fi network
- #86 — Identify home vs office
- #153 — Enhance lock/sleep logic based on signal strength

No open PR addresses these. PR #4 (merged) introduced the moving average used below.

## Scope

Two independent, complementary changes, shipped as **two separate PRs**:

- **Part A** — root-cause fix (small, no new UI, maximally mergeable). Upstream PR #1.
- **Part B** — Wi-Fi auto-pause feature (larger). Upstream PR #2, doubles as a fork if
  not merged.

Part A is implemented and submitted first so it stays a clean, reviewable bugfix.

---

## Part A — Unlock debounce (root-cause fix)

**File:** `BLE.swift` — `updateMonitoredPeripheral(_:)`

Reorder so the smoothed RSSI is computed *first*, then gate the presence transition on
**both** the smoothed value crossing the threshold **and** a minimum number of samples
in the buffer.

```swift
func updateMonitoredPeripheral(_ rssi: Int) {
    let estimatedRSSI = getEstimatedRSSI(rssi: rssi)          // ① smooth first
    delegate?.updateRSSI(rssi: estimatedRSSI, active: activeModeTimer != nil)

    let unlockThreshold = (unlockRSSI == UNLOCK_DISABLED ? lockRSSI : unlockRSSI)
    if estimatedRSSI >= unlockThreshold
        && latestRSSIs.count >= unlockMinSamples             // ② minimum samples
        && !presence {
        print("Device is close")
        presence = true
        delegate?.updatePresence(presence: presence, reason: "close")
        latestRSSIs.removeAll()                              // ③ warm-up for next cycle
    }

    if estimatedRSSI >= (lockRSSI == LOCK_DISABLED ? unlockRSSI : lockRSSI) {
        // cancel proximity timer — unchanged
    } else if presence && proximityTimer == nil {
        // start proximity timer — unchanged
    }
    resetSignalTimer()
}
```

### Details
- New property: `var unlockMinSamples = 3`. Must satisfy `unlockMinSamples <= latestN`
  (currently 5). Default 3 ≈ 4–6 s latency in active mode (~2 s/sample); 2 is the
  acceptable lower bound if unlock feels sluggish.
- The unlock block's `latestRSSIs.removeAll()` now runs *after* `getEstimatedRSSI`
  (which appended the current sample). The local `estimatedRSSI` is already captured, so
  the subsequent lock check is unaffected.
- The `removeAll()` after a successful unlock provides a natural warm-up: the next
  unlock cycle must re-accumulate `unlockMinSamples` fresh samples, killing bounce.

### Edge cases / non-issues (design-review consensus)
- **Reordering is safe and beneficial** — `removeAll()` only fires on the unlock
  transition; the buffer always refills under normal advertising/active polling.
- **Sporadic packets** — active mode polls `readRSSI` every ~2 s, so the buffer reaches
  3 samples within seconds; if it genuinely cannot, the signal is unreliable and *not*
  unlocking is correct.
- **`startMonitor` sets `presence = true` initially** — the debounce therefore applies
  from the first lock cycle onward, i.e. exactly the real-world case (walk away → lock →
  return → false positive on return).
- **`unlockRSSI == UNLOCK_DISABLED`** — `AppDelegate.updatePresence` already guards the
  unlock branch on this; the sample gate is harmless here.

### Testing
- Unit-testable core: factor the unlock decision (`shouldUnlock(estimatedRSSI:, count:)`)
  if a test target exists; otherwise verify behaviorally.
- Behavioral check: feed a synthetic sequence (one strong spike surrounded by weak
  samples) and assert presence does **not** flip; feed a sustained strong sequence and
  assert it flips after `unlockMinSamples`.

### PR framing
Titled as a bugfix ("Use smoothed RSSI + minimum sample count for unlock decision to
prevent single-spike false positives"). References #153. No UI, no new settings surface.

---

## Part B — Wi-Fi auto-pause via gateway MAC

**New file:** `NetworkMonitor.swift`; integration in `AppDelegate.swift`.

When the Mac is on a user-designated "home" network, **completely pause** BLEUnlock:
neither auto-lock nor auto-unlock. The network is identified **permission-free** by the
**default gateway's MAC address** (no SSID, no CoreLocation).

### B1. Network identity (permission-free)
Via `Process` (the app is **not** sandboxed — `BLEUnlock.entitlements` has no
`app-sandbox` key):
1. `/sbin/route -n get default` → parse `gateway:` (IPv4 default gateway IP).
2. `/sbin/ping -c 1 -t 1 <gatewayIP>` → prime the ARP cache (gateway MAC may be absent
   right after a network switch). Fire-and-forget with short timeout.
3. `/usr/sbin/arp -n <gatewayIP>` → parse `at <MAC>` → normalized gateway MAC.

Return `nil` on any failure (unreachable gateway, captive portal, IPv6-only). `nil`
means "not a known home network" → **stay active** (safe default).

### B2. Change detection
`SCDynamicStore` (SystemConfiguration) watching `State:/Network/Global/IPv4`
(and `…/IPv6`). Fires on Wi-Fi join/leave, Ethernet plug/unplug, and VPN
connect/disconnect — i.e. every event that changes the default route. No polling, no
CoreWLAN. On each notification, re-resolve the gateway MAC and recompute pause state.

### B3. Pause mechanic
- Single flag `pausedByNetwork: Bool`, owned by `AppDelegate` (driven by
  `NetworkMonitor`).
- **Guards** at the top of `AppDelegate.updatePresence(presence:reason:)` **and**
  `tryUnlockScreen()`:
  `guard !pausedByNetwork else { return }`. This suppresses **both** auto-lock (the
  `presence == false` branch in `updatePresence`) and auto-unlock cleanly.
- **BLE scanning is NOT torn down** — `BLE` keeps tracking RSSI/presence internally, so
  resume is immediate.
- **Deliberate deviation from one review suggestion:** entering a paused network does
  **not** actively unlock the Mac. "Complete pause" means *no* auto-unlock — if the Mac
  is locked when you arrive home, it stays locked (manual unlock). Likewise it is not
  force-locked. Only the automation is suspended.
- **Resume:** on leaving the paused network, take no active lock/unlock action; the next
  RSSI sample drives normal behavior again (BLE state is current because scanning never
  stopped).

### B4. UI
- Menu item **"Disable on this network"** (toggle). Checked when the current gateway MAC
  is in the allowlist. Toggling adds/removes the current gateway MAC.
- Allowlist persisted in `UserDefaults` under `pausedGatewayMACs` (array of normalized
  MAC strings).
- Disabled (greyed) with an explanatory state when no gateway MAC can be resolved
  (e.g. IPv6-only / captive network).

### B5. Edge cases (design-review consensus)
- **VPN active** — default gateway becomes the VPN endpoint; its MAC won't match the
  allowlist → stays active (correct: you're likely not home). Split-tunnel that keeps
  the local default route would still pause; documented.
- **No gateway / captive portal** — resolution returns `nil` → stays active.
- **Multiple interfaces** — `route -n get default` returns the single active default
  gateway; no ambiguity.
- **IPv6-only** — `arp` does not resolve IPv6; v1 is IPv4-only. Documented; `ndp -an`
  support is a possible future enhancement.
- **Gateway MAC randomization / locally-administered MACs** — routers use stable MACs;
  non-issue. A changed router MAC simply means BLEUnlock resumes and the user re-adds it.

### Testing
- Parsing: unit-test `route`/`arp` output parsers against captured sample outputs
  (IPv4 present, no default route, malformed).
- Pause logic: unit-test `isPaused(currentMAC:allowlist:)`.
- Integration: manual — add current network, walk device out of range, confirm no lock;
  switch networks, confirm automation resumes.

### PR framing
Implements #142 ("disable on certain Wi-Fi networks") via a permission-free gateway-MAC
approach. Submitted as a separate PR after Part A; serves as a standalone fork if not
merged upstream.

---

## Delivery / PR mechanics
- Work happens in the local clone (`origin = ts1/BLEUnlock`, `master @ 2eeb35d`).
- Each part is a clean branch off upstream `master` (the design doc commit is **not**
  included in PR branches).
- Pushing requires forking `ts1/BLEUnlock` under the user's GitHub account
  (`gh auth`). This outward-facing step is confirmed with the user before the first push.

## Non-goals (YAGNI)
- Per-network RSSI thresholds (#155) — not in scope; complete pause covers the need.
- SSID-based detection / CoreLocation — explicitly rejected to stay zero-touch.
- IPv6 gateway resolution — deferred.
- "Work time" / schedule-based disabling (#139) — out of scope.

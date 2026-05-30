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
        // NOTE: the original `latestRSSIs.removeAll()` is intentionally removed — see below.
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
- **The original `latestRSSIs.removeAll()` (current `BLE.swift:241`) is removed**
  (design-review **required change**). In the current code it runs *before*
  `getEstimatedRSSI`, so the sample right after an unlock yields
  `estimatedRSSI` = a single raw value, which then drives the **lock** decision
  (proximity-timer start/cancel). A single noisy sample could thus prematurely start or
  erroneously cancel the lock timer. Keeping the rolling buffer intact means
  `estimatedRSSI` stays smoothed for *both* the lock and unlock decisions.
- **Spike resistance now comes from the moving average itself**, which is sufficient:
  with `latestN = 5`, a lone spike of −40 among four −85 samples yields a mean of −76,
  below the default unlock threshold of −60 → no false unlock. The `unlockMinSamples`
  count gate is belt-and-suspenders for the cold-start warm-up (buffer not yet filled).
- **Anti-bounce** is provided by the existing hysteresis dead-band (lockRSSI < unlockRSSI)
  plus the moving average — not by clearing the buffer. Removing `removeAll()` does not
  reintroduce oscillation.

### Edge cases / non-issues (design-review consensus)
- **Reordering is safe and beneficial** — `getEstimatedRSSI` now runs first, so the
  current call's lock decision uses the full smoothed buffer.
- **Without `removeAll()` the count gate is mostly a no-op in steady state** (buffer
  stays at `latestN`); it only bites at cold start / after the buffer is otherwise
  empty. That is acceptable — the moving average carries the spike resistance.
- **Sporadic packets** — active mode polls `readRSSI` every ~2 s, so the buffer reaches
  3 samples within seconds; if it genuinely cannot, the signal is unreliable and *not*
  unlocking is correct.
- **`startMonitor` sets `presence = true` initially** — the debounce therefore applies
  from the first lock cycle onward, i.e. exactly the real-world case (walk away → lock →
  return → false positive on return).
- **`unlockRSSI == UNLOCK_DISABLED`** — `AppDelegate.updatePresence` already guards the
  unlock branch on this; the sample gate is harmless here.
- **Concurrency** — `latestRSSIs` is only ever touched inside `updateMonitoredPeripheral`
  / `getEstimatedRSSI`, both on the CoreBluetooth delegate queue (the main queue, since
  `CBCentralManager(delegate:queue:nil)`). No locking needed.

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
2. `/sbin/ping -c 2 -t 1 <gatewayIP>` → prime the ARP cache (gateway MAC may be absent
   right after a network switch). Two probes for reliability; short per-probe timeout.
3. `/usr/sbin/arp -n <gatewayIP>` → parse `at <MAC>` → normalized gateway MAC. If the
   entry is missing, retry up to 2 more times spaced ~150 ms (ARP may settle just after
   `ping` returns).

`resolveGatewayMAC()` returns the normalized MAC, or `nil` if it cannot be determined
(unreachable gateway, captive portal, IPv6-only). The handling of `nil` is **not** an
unconditional fall-back to active — see B3a (sticky state).

### B2. Change detection & threading (required)
`SCDynamicStore` (SystemConfiguration) watching `State:/Network/Global/IPv4`
(and `…/IPv6`). Fires on Wi-Fi join/leave, Ethernet plug/unplug, and VPN
connect/disconnect — i.e. every event that changes the default route. No polling, no
CoreWLAN.

**Threading (design-review required change):** the `SCDynamicStore` callback runs on the
main run loop, and the `route`/`ping`/`arp` `Process` calls block for up to a few
seconds. They **must not** run on the main queue (UI beachball). On each notification:
1. The main-queue callback dispatches resolution onto a dedicated **serial background
   queue** (`DispatchQueue(label: "…networkmonitor", qos: .utility)`).
2. That queue runs `resolveGatewayMAC()` and computes the new pause state.
3. The result is dispatched **back to the main queue** to write `pausedByNetwork` and
   update the menu. `pausedByNetwork` is therefore only ever written/read on the main
   queue.

A new notification arriving while resolution is in flight simply enqueues another job on
the serial queue (latest result wins); no cancellation needed.

### B3a. Sticky pause state (required)
Do **not** flip to active on a transient resolution failure. Track the last
*successfully resolved* gateway MAC and the last pause state:
- **MAC resolved** → `pausedByNetwork = (MAC ∈ allowlist)`.
- **MAC unresolved (`nil`)** → **keep the previous `pausedByNetwork`** (sticky) and let
  the next notification / retry correct it. This prevents pause flicker on brief Wi-Fi
  hiccups while a real network change (which resolves to a different MAC, or removes the
  default route as you physically leave) still drives the state correctly.
- **First-ever run with `nil`** (no prior state) → default to active (safe default).

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
- **`runScript` coverage** — the `away` / `lost` / `unlocked` scripts are reached only
  via the two guarded methods, so they are suppressed while paused (consistent). The
  `intruded` script in `onUnlock` is **not** guarded: it fires on a real screen-unlock
  event (e.g. a manual unlock while paused), which is intrusion detection, not an
  automation action. Documented as intentional.

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

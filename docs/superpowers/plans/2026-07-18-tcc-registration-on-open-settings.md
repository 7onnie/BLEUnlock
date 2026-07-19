# TCC Registration on "Open Settings" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clicking "Open Settings" in the Check Permissions dialog registers BLEUnlock with TCC first (Accessibility + Bluetooth), so the entries actually exist in System Settings and the user can enable them.

**Architecture:** The Check Permissions report stays read-only. The second-button handler in `checkPermissions()` gains three pre-steps before opening the Privacy pane: activate the app, trigger the Accessibility prompt via the existing `checkAccessibility(showPrompt: true)`, and trigger the Bluetooth prompt via a new `BLE.triggerAuthorizationPrompt()` that re-creates the `CBCentralManager` without the monitoring guards.

**Tech Stack:** Swift, AppKit, CoreBluetooth, ApplicationServices (AX API). Spec: `docs/superpowers/specs/2026-07-18-tcc-registration-on-open-settings-design.md`.

## Global Constraints

- No new localized strings, no Info.plist changes, no `tccutil` calls (approach A per spec).
- No pure-logic unit is introduced: the decision inputs (`!ax`, `.notDetermined`) map 1:1 to API calls, so a swiftc test suite would test an identity function. Verification per task is a clean build; end-to-end verification is manual (Task 3).
- Build command (same as CI): `xcodebuild clean build -project BLEUnlock.xcodeproj -scheme BLEUnlock CODE_SIGNING_ALLOWED=NO`
- xcodebuild may bump `BLEUnlock/Info.plist` as a side effect — revert that file if it shows up modified in `git status` (do not commit the bump).
- Run all commands from the repo root: `/Users/user/GitHubRepos/BLEUnlock`
- Every commit message ends with the Co-Authored-By/Claude-Session trailer per session convention.

---

### Task 1: `BLE.triggerAuthorizationPrompt()`

**Files:**
- Modify: `BLEUnlock/BLE.swift` (insert after `recoverAfterPermissionChangeIfNeeded()`, i.e. after the closing brace at line 488)

**Interfaces:**
- Consumes: existing `BLE` members `centralMgr: CBCentralManager!`, `lastAuthorizationRefreshAt: Double`, `minimumAuthorizationRefreshInterval: Double` (all already defined in BLE.swift:401/460–461).
- Produces: `func triggerAuthorizationPrompt()` on `BLE` — no parameters, no return value. Task 2 calls it as `ble.triggerAuthorizationPrompt()`.

- [ ] **Step 1: Add the method**

Insert directly after the closing brace of `recoverAfterPermissionChangeIfNeeded()` (BLE.swift line 488):

```swift
    /// Re-creates the CBCentralManager so TCC registers the app in
    /// System Settings → Privacy & Security → Bluetooth and shows the system
    /// prompt while authorization is .notDetermined. Unlike
    /// recoverAfterPermissionChangeIfNeeded() this ignores scanMode,
    /// monitoredUUIDs and monitoringSuspended: it must work while monitoring
    /// is paused at startup. Shares the rate limit to avoid manager churn.
    func triggerAuthorizationPrompt() {
        let now = Date().timeIntervalSince1970
        guard now - lastAuthorizationRefreshAt >= minimumAuthorizationRefreshInterval else { return }
        lastAuthorizationRefreshAt = now
        print("Triggering Bluetooth authorization registration")
        centralMgr.stopScan()
        centralMgr.delegate = nil
        centralMgr = CBCentralManager(delegate: self, queue: nil)
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild clean build -project BLEUnlock.xcodeproj -scheme BLEUnlock CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Revert Info.plist bump if present**

Run: `git status --short`
If `BLEUnlock/Info.plist` is listed as modified: `git checkout BLEUnlock/Info.plist`

- [ ] **Step 4: Commit**

```bash
git add BLEUnlock/BLE.swift
git commit -m "Add BLE.triggerAuthorizationPrompt to force TCC Bluetooth registration"
```

---

### Task 2: Wire registration into the Check Permissions Settings button

**Files:**
- Modify: `BLEUnlock/AppDelegate.swift` — doc comment above `checkPermissions()` (lines 2560–2564) and the second-button handler at the end of `checkPermissions()` (lines 2662–2666)

**Interfaces:**
- Consumes: `ble.triggerAuthorizationPrompt()` from Task 1; existing `checkAccessibility(showPrompt:)` (AppDelegate.swift:2465, `@discardableResult`); existing locals `ax: Bool` and `settingsPane: String?` inside `checkPermissions()`.
- Produces: no new API; behavior change only.

- [ ] **Step 1: Update the doc comment**

Replace lines 2560–2564:

```swift
    /// Read-only diagnostic: reports the ACTUAL runtime permission state from the
    /// real APIs (Accessibility, Bluetooth, Automation, Notifications, event script),
    /// as opposed to what System Settings shows. Because this app is ad-hoc signed,
    /// its cdhash changes on every build, so a stale System Settings entry can look
    /// wrong even though the running process already holds the grant.
```

with:

```swift
    /// Diagnostic report of the ACTUAL runtime permission state from the real APIs
    /// (Accessibility, Bluetooth, Automation, Notifications, event script), as
    /// opposed to what System Settings shows — a stale System Settings entry can
    /// look wrong even though the running process already holds the grant. The
    /// report itself is read-only; only clicking "Open Settings" actively registers
    /// the app with TCC (triggers the Accessibility/Bluetooth prompts) so the
    /// entries exist in the Privacy panes and the user can enable them.
```

- [ ] **Step 2: Extend the button handler**

Replace lines 2662–2666:

```swift
        if let pane = settingsPane, response == .alertSecondButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                NSWorkspace.shared.open(url)
            }
        }
```

with:

```swift
        if let pane = settingsPane, response == .alertSecondButtonReturn {
            // Register the app with TCC before opening the pane, so the entries
            // actually exist there. Activate first: as an LSUIElement app the
            // system prompts otherwise appear hidden behind other windows.
            // Both registrations run regardless of which pane opens, so one
            // click creates every missing entry.
            NSApp.activate(ignoringOtherApps: true)
            if !ax {
                checkAccessibility(showPrompt: true)
            }
            if #available(macOS 10.15, *), ble.centralMgr.authorization == .notDetermined {
                ble.triggerAuthorizationPrompt()
            }
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                NSWorkspace.shared.open(url)
            }
        }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild clean build -project BLEUnlock.xcodeproj -scheme BLEUnlock CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Revert Info.plist bump if present**

Run: `git status --short`
If `BLEUnlock/Info.plist` is listed as modified: `git checkout BLEUnlock/Info.plist`

- [ ] **Step 5: Commit**

```bash
git add BLEUnlock/AppDelegate.swift
git commit -m "Check Permissions: register app with TCC when opening System Settings"
```

---

### Task 3: Changelog entry + manual end-to-end verification

**Files:**
- Modify: `CHANGELOG.md` (insert new section directly under the `# Release Notes` heading, above `## 1.15.9`)

**Interfaces:**
- Consumes: behavior from Tasks 1–2.
- Produces: release notes for the next tag (version comes from the git tag at release time; no version bump in the repo).

- [ ] **Step 1: Add changelog section**

Insert under `# Release Notes` (above `## 1.15.9`):

```markdown
## 1.15.10

- Check Permissions: clicking **Open Settings** now registers BLEUnlock with macOS first, so the app actually appears in System Settings → Privacy & Security → Accessibility and → Bluetooth and the checkbox can be enabled (previously both lists could be empty with no way to add the app — the Bluetooth pane has no "+" button). If the Bluetooth entry is still missing because an old build's stale permission record blocks it, run `tccutil reset BluetoothAlways com.github.7onnie.BLEUnlock` (no sudo needed) and click Open Settings again.
```

- [ ] **Step 2: Commit and push**

```bash
git add CHANGELOG.md
git commit -m "Changelog for 1.15.10 (TCC registration via Open Settings)"
git push
```

- [ ] **Step 3: Manual end-to-end verification (developer Mac)**

1. Reset TCC so both entries are missing (simulates the reported state):
   `tccutil reset Accessibility com.github.7onnie.BLEUnlock && tccutil reset BluetoothAlways com.github.7onnie.BLEUnlock`
2. Build and launch the app from the built product (quit any running instance first).
3. Menu → Check Permissions → both Accessibility and Bluetooth report as failing.
4. Click "Open Settings". Expected: app comes to front, Accessibility system prompt appears (entry appears in the Bedienungshilfen list even if dismissed), Bluetooth system prompt appears, then the Privacy pane opens.
5. In System Settings, verify a BLEUnlock entry now exists in BOTH Privacy & Security → Accessibility and → Bluetooth, and the checkbox can be enabled.
6. Click "Open Settings" twice in quick succession → no crash, no duplicate prompts (rate limit).

Expected: all six observations hold. If step 5 fails for Bluetooth with authorization `.denied`, that is the documented stale-TCC case (out of scope for approach A) — verify the `tccutil reset` hint from the changelog resolves it.

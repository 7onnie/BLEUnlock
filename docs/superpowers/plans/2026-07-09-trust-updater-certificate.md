# Trust Updater Certificate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the user an in-app, explained way to trust the fork's self-signed updater certificate so TCC/Keychain grants persist across updates — via a menu item, a hint in the update dialog, and a status line in Check Permissions.

**Architecture:** A pure, swiftc-testable `CertTrust.swift` builds the `security`/`codesign` argument arrays and interprets exit codes; a thin process layer in AppDelegate runs them (`isUpdaterCertTrusted()`, `trustUpdaterCertificate()`). The public certificate ships as a bundle resource. Three UI touch points consume the layer: a "Trust Updater Certificate…" menu item, a conditional hint+button in the update-available dialog, and an informational line in Check Permissions.

**Tech Stack:** Swift (AppKit), `/usr/bin/security` + `/usr/bin/codesign` via `Process`, swiftc test suites, Xcode project.

## Global Constraints

- Working dir `/Users/user/GitHubRepos/BLEUnlock-src`; remote `fork` (SSH) = 7onnie/BLEUnlock.
- Verified mechanism (do not deviate): trust = `security add-trusted-cert -r trustRoot -p codeSign -k <login.keychain-db> <cert>` (user domain, Touch-ID prompt, no sudo). Trusted-state proxy = `codesign -v -R="anchor trusted" <bundle>` exit 0.
- Trusting is **opt-in only**, never automatic; the confirm dialog must state the security implication (all builds signed by this cert become locally trusted) and the undo path (`security delete-certificate -c "BLEUnlock Fork Signing"`).
- The bundled cert is the **public** cert only. `SIGNING_CERT_SHA1 = "B81E475C8112BA5EE767A9FBD8DFCB2262A7030F"`.
- After every `xcodebuild`: if `git status` shows `BLEUnlock/Info.plist` changed → `git checkout -- BLEUnlock/Info.plist` BEFORE committing.
- SCRATCH: `/private/tmp/claude-503/-Users-user-GitHubRepos-BLEUnlock/8369d4f4-3922-4b5f-b708-df31bde3323a/scratchpad`
- Do NOT touch the unlock path, LockDecision, RSSIDecision.
- Before pushing to master: `git fetch fork && git rebase fork/master` (another agent pushes in parallel; additive commits rebase cleanly).
- Release version is **v1.15.7** (v1.15.6 exists). Ships together with the already-committed About-box fix.

---

### Task 1: Pure `CertTrust.swift` + swiftc tests + pbxproj (Sources) + CI

**Files:**
- Create: `BLEUnlock/CertTrust.swift`, `Tests/CertTrustTests/main.swift`
- Modify: `BLEUnlock.xcodeproj/project.pbxproj`, `.github/workflows/test.yml`

**Interfaces:**
- Produces (consumed by Task 2/3): `SIGNING_CERT_SHA1: String`; `addTrustedCertArguments(certPath: String, loginKeychainPath: String) -> [String]`; `anchorTrustedArguments(bundlePath: String) -> [String]`; `isBundleTrusted(codesignExitCode: Int32) -> Bool`.

- [ ] **Step 1: Branch**

```bash
cd /Users/user/GitHubRepos/BLEUnlock-src
git fetch fork && git checkout -b feature/trust-updater-cert fork/master
```

- [ ] **Step 2: Failing test** — `Tests/CertTrustTests/main.swift`:

```swift
import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("ok   - \(msg)") } else { print("FAIL - \(msg)"); failures += 1 }
}

let a = addTrustedCertArguments(certPath: "/tmp/c.cer", loginKeychainPath: "/Users/x/Library/Keychains/login.keychain-db")
check(a == ["add-trusted-cert", "-r", "trustRoot", "-p", "codeSign", "-k", "/Users/x/Library/Keychains/login.keychain-db", "/tmp/c.cer"],
      "add-trusted-cert args in exact order with codeSign + trustRoot")

let c = anchorTrustedArguments(bundlePath: "/Applications/BLEUnlock.app")
check(c == ["-v", "-R=anchor trusted", "/Applications/BLEUnlock.app"], "codesign anchor-trusted args")

check(isBundleTrusted(codesignExitCode: 0) == true, "exit 0 -> trusted")
check(isBundleTrusted(codesignExitCode: 1) == false, "exit 1 -> not trusted")
check(SIGNING_CERT_SHA1 == "B81E475C8112BA5EE767A9FBD8DFCB2262A7030F", "cert sha1 constant")

if failures == 0 { print("\nALL PASS") } else { print("\n\(failures) FAILURE(S)"); exit(1) }
```

- [ ] **Step 3: Compile test, see it fail**

```bash
SCRATCH=/private/tmp/claude-503/-Users-user-GitHubRepos-BLEUnlock/8369d4f4-3922-4b5f-b708-df31bde3323a/scratchpad
swiftc -o $SCRATCH/certtrust-tests Tests/CertTrustTests/main.swift 2>&1 | head -3
```
Expected: FAIL, `cannot find 'addTrustedCertArguments' in scope`.

- [ ] **Step 4: Implementation** — `BLEUnlock/CertTrust.swift`:

```swift
import Foundation

/// SHA-1 fingerprint of the fork's self-signed code-signing certificate.
/// Matches the certificate-leaf hash in the app's Designated Requirement.
let SIGNING_CERT_SHA1 = "B81E475C8112BA5EE767A9FBD8DFCB2262A7030F"

/// Arguments for `/usr/bin/security` to trust the signing cert for code signing
/// in the user-domain login keychain. Verified working without sudo (Touch-ID
/// prompt only); this is what makes macOS TCC key on the stable Designated
/// Requirement instead of the per-build cdhash.
func addTrustedCertArguments(certPath: String, loginKeychainPath: String) -> [String] {
    return ["add-trusted-cert", "-r", "trustRoot", "-p", "codeSign",
            "-k", loginKeychainPath, certPath]
}

/// Arguments for `/usr/bin/codesign` to test whether a bundle chains to a TRUSTED
/// anchor — the proxy for "TCC will persist grants for this app across updates".
func anchorTrustedArguments(bundlePath: String) -> [String] {
    return ["-v", "-R=anchor trusted", bundlePath]
}

/// codesign exit 0 from the anchor-trusted check means the cert is trusted.
func isBundleTrusted(codesignExitCode: Int32) -> Bool {
    return codesignExitCode == 0
}
```

- [ ] **Step 5: Test green**

```bash
swiftc -o $SCRATCH/certtrust-tests Tests/CertTrustTests/main.swift BLEUnlock/CertTrust.swift && $SCRATCH/certtrust-tests
```
Expected: `ALL PASS`.

- [ ] **Step 6: pbxproj — CertTrust.swift into the app target** (mirror RSSIDecision.swift; IDs fileRef `DD4004500000000000000001`, buildFile `DD4004500000000000000002`).

`PBXBuildFile` after the `680CDE71110749891F5AA1E4 /* RSSIDecision.swift in Sources */` line:
```
		DD4004500000000000000002 /* CertTrust.swift in Sources */ = {isa = PBXBuildFile; fileRef = DD4004500000000000000001 /* CertTrust.swift */; };
```
`PBXFileReference` after the `B5D0346CA6A4625F6C40E69D /* RSSIDecision.swift */` line:
```
		DD4004500000000000000001 /* CertTrust.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = CertTrust.swift; sourceTree = "<group>"; };
```
Group after `B5D0346CA6A4625F6C40E69D /* RSSIDecision.swift */,`:
```
				DD4004500000000000000001 /* CertTrust.swift */,
```
Sources build phase after `680CDE71110749891F5AA1E4 /* RSSIDecision.swift in Sources */,`:
```
				DD4004500000000000000002 /* CertTrust.swift in Sources */,
```

- [ ] **Step 7: CI** — in `.github/workflows/test.yml`, next to the other swiftc suite lines, add:
```
          swiftc -o /tmp/certtrust-tests Tests/CertTrustTests/main.swift BLEUnlock/CertTrust.swift && /tmp/certtrust-tests
```

- [ ] **Step 8: Build + test + commit + push**

```bash
xcodebuild -project BLEUnlock.xcodeproj -scheme BLEUnlock -configuration Release CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
git checkout -- BLEUnlock/Info.plist 2>/dev/null || true
swiftc -o $SCRATCH/certtrust-tests Tests/CertTrustTests/main.swift BLEUnlock/CertTrust.swift && $SCRATCH/certtrust-tests | tail -1
git add BLEUnlock/CertTrust.swift Tests/CertTrustTests/main.swift BLEUnlock.xcodeproj/project.pbxproj .github/workflows/test.yml
git commit -m "Add pure CertTrust module (security/codesign arg builders) with tests + CI"
git push fork feature/trust-updater-cert
```

---

### Task 2: Bundle the cert + trust layer + "Trust Updater Certificate…" menu item

**Files:**
- Create: `BLEUnlock/SigningCertificate.cer`
- Modify: `BLEUnlock/AppDelegate.swift`, `BLEUnlock/Base.lproj/Localizable.strings`, `BLEUnlock/de.lproj/Localizable.strings`, `BLEUnlock.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `addTrustedCertArguments`, `anchorTrustedArguments`, `isBundleTrusted` (Task 1); existing `infoModal(_:info:)`, `errorModal(_:info:)`, `t(_:)`.
- Produces: `AppDelegate.isUpdaterCertTrusted() -> Bool`, `AppDelegate.trustUpdaterCertificate() -> (ok: Bool, message: String?)` (consumed by Task 3).

- [ ] **Step 1: Bundle the public certificate**

```bash
cp ~/GitHubRepos/BLEUnlock-signing/cert.pem BLEUnlock/SigningCertificate.cer
```
(Public cert; PEM content, `.cer` name. `security add-trusted-cert` accepts it.)

- [ ] **Step 2: pbxproj — SigningCertificate.cer as a Resource** (fileRef `DD4004500000000000000003`, buildFile `DD4004500000000000000004`).

`PBXBuildFile` after the CertTrust build-file line:
```
		DD4004500000000000000004 /* SigningCertificate.cer in Resources */ = {isa = PBXBuildFile; fileRef = DD4004500000000000000003 /* SigningCertificate.cer */; };
```
`PBXFileReference` after the CertTrust file-reference line:
```
		DD4004500000000000000003 /* SigningCertificate.cer */ = {isa = PBXFileReference; lastKnownFileType = file; path = SigningCertificate.cer; sourceTree = "<group>"; };
```
Group after `DD4004500000000000000001 /* CertTrust.swift */,`:
```
				DD4004500000000000000003 /* SigningCertificate.cer */,
```
In the app target's `PBXResourcesBuildPhase` (the one containing `3D2FCF08226C99CB007A06E7 /* Images.xcassets in Resources */,`), after that line:
```
				DD4004500000000000000004 /* SigningCertificate.cer in Resources */,
```

- [ ] **Step 3: Trust layer** — add to `AppDelegate` (near `checkAccessibility`/`checkPermissions`, e.g. right before `@objc func checkPermissions()`):

```swift
    /// True if the running app already chains to a trusted anchor — i.e. the
    /// updater certificate is trusted and TCC will persist grants across updates.
    func isUpdaterCertTrusted() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = anchorTrustedArguments(bundlePath: Bundle.main.bundlePath)
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run(); proc.waitUntilExit() } catch { return false }
        return isBundleTrusted(codesignExitCode: proc.terminationStatus)
    }

    /// Trusts the bundled public certificate for code signing in the user-domain
    /// login keychain (triggers a Touch-ID/password prompt). Returns (true, nil)
    /// on success, (false, message) otherwise. Blocks until the user responds —
    /// call off the main queue.
    func trustUpdaterCertificate() -> (ok: Bool, message: String?) {
        guard let certURL = Bundle.main.url(forResource: "SigningCertificate", withExtension: "cer") else {
            return (false, t("cert_trust_no_resource"))
        }
        let login = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Keychains/login.keychain-db")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = addTrustedCertArguments(certPath: certURL.path, loginKeychainPath: login)
        let errPipe = Pipe()
        proc.standardError = errPipe
        do { try proc.run() } catch { return (false, error.localizedDescription) }
        proc.waitUntilExit()
        if proc.terminationStatus == 0 { return (true, nil) }
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        let msg = String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
            ?? "security exited \(proc.terminationStatus)"
        return (false, msg)
    }
```

- [ ] **Step 4: Menu action** — add to `AppDelegate`:

```swift
    @objc func trustUpdaterCertificateMenu() {
        if isUpdaterCertTrusted() {
            infoModal(t("cert_already_trusted"))
            return
        }
        let alert = NSAlert()
        alert.messageText = t("cert_trust_title")
        alert.informativeText = t("cert_trust_explain")
        alert.window.title = "BLEUnlock"
        alert.addButton(withTitle: t("cert_trust_confirm"))
        alert.addButton(withTitle: t("cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.trustUpdaterCertificate()
            DispatchQueue.main.async {
                if result.ok { self.infoModal(t("cert_trust_done")) }
                else { self.errorModal(t("cert_trust_failed"), info: result.message) }
            }
        }
    }
```

- [ ] **Step 5: Menu item** — in `constructMenu()`, immediately after the `check_permissions` line (`AppDelegate.swift:2400`):

```swift
        mainMenu.addItem(withTitle: t("trust_updater_certificate"), action: #selector(trustUpdaterCertificateMenu), keyEquivalent: "")
```

- [ ] **Step 6: Strings.** Base (`BLEUnlock/Base.lproj/Localizable.strings`):
```
"trust_updater_certificate" = "Trust Updater Certificate…";
"cert_trust_title" = "Trust the Updater Certificate?";
"cert_trust_explain" = "BLEUnlock's releases are signed with its own certificate. Trusting it for code signing (one Touch ID / password prompt) lets macOS keep your Bluetooth, Accessibility, and saved-password permissions across updates instead of re-asking every time.\n\nSecurity: after this, any app signed with this certificate is trusted for code signing on this Mac. Only the maintainer holds the private key. To undo later, remove \"BLEUnlock Fork Signing\" in Keychain Access, or run: security delete-certificate -c \"BLEUnlock Fork Signing\"";
"cert_trust_confirm" = "Trust";
"cert_trust_done" = "Certificate trusted. Future updates will keep your permissions.";
"cert_trust_failed" = "Could not trust the certificate.";
"cert_trust_no_resource" = "The bundled certificate could not be found.";
"cert_already_trusted" = "The updater certificate is already trusted. Updates keep your permissions.";
```
de (`BLEUnlock/de.lproj/Localizable.strings`):
```
"trust_updater_certificate" = "Updater-Zertifikat vertrauen…";
"cert_trust_title" = "Dem Updater-Zertifikat vertrauen?";
"cert_trust_explain" = "BLEUnlocks Releases sind mit einem eigenen Zertifikat signiert. Wenn du ihm fürs Code-Signing vertraust (eine Touch-ID-/Passwort-Abfrage), behält macOS deine Bluetooth-, Bedienungshilfen- und Passwort-Freigaben über Updates hinweg, statt jedes Mal neu zu fragen.\n\nSicherheit: Danach gilt jede mit diesem Zertifikat signierte App auf diesem Mac als vertrauenswürdig fürs Code-Signing. Nur der Maintainer besitzt den privaten Schlüssel. Rückgängig: „BLEUnlock Fork Signing\" in der Schlüsselbundverwaltung entfernen oder ausführen: security delete-certificate -c \"BLEUnlock Fork Signing\"";
"cert_trust_confirm" = "Vertrauen";
"cert_trust_done" = "Zertifikat vertraut. Künftige Updates behalten deine Freigaben.";
"cert_trust_failed" = "Zertifikat konnte nicht vertraut werden.";
"cert_trust_no_resource" = "Das mitgelieferte Zertifikat wurde nicht gefunden.";
"cert_already_trusted" = "Das Updater-Zertifikat ist bereits vertrauenswürdig. Updates behalten deine Freigaben.";
```

- [ ] **Step 7: Build + lint + commit + push**

```bash
xcodebuild -project BLEUnlock.xcodeproj -scheme BLEUnlock -configuration Release CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
git checkout -- BLEUnlock/Info.plist 2>/dev/null || true
plutil -lint BLEUnlock/Base.lproj/Localizable.strings BLEUnlock/de.lproj/Localizable.strings
git add -A
git commit -m "Bundle signing cert + trust layer + Trust Updater Certificate menu item"
git push fork feature/trust-updater-cert
```
Expected: BUILD SUCCEEDED; both strings files `OK`.

- [ ] **Step 8: Manual sanity (optional, user-driven):** menu shows "Trust Updater Certificate…"; on an untrusted Mac it opens the explanation dialog. (Full Touch-ID flow tested at release.)

---

### Task 3: Update-dialog hint + button, and Check-Permissions line + merge

**Files:**
- Modify: `BLEUnlock/AppDelegate.swift` (`checkForUpdates` ~2153, `checkPermissions` ~2540), both `Localizable.strings`

**Interfaces:**
- Consumes: `isUpdaterCertTrusted()`, `trustUpdaterCertificate()` (Task 2), existing `installUpdate(fromZip:completion:)`, `PermissionItem`, `permissionReportText`.

- [ ] **Step 1a: Declare the action enum at file scope** (Swift forbids type declarations inside a closure). Add near the top of `AppDelegate.swift`, at file scope (e.g. just above `class AppDelegate`):

```swift
private enum UpdateDialogAction { case trustFirst, install, browserDownload, openReleases, cancel }
```

- [ ] **Step 1b: Rework the update-available dialog** (`checkForUpdates`, the `.available` case). Replace the whole block from `let alert = NSAlert()` through the `} else if downloadURL != nil && response == .alertSecondButtonReturn { NSWorkspace.shared.open(releaseURL) }` with a tag-free, action-ordered version:

```swift
                    let trusted = self.isUpdaterCertTrusted()
                    let alert = NSAlert()
                    alert.messageText = t("update_available_title")
                    var body = String(format: t("update_available_message"), version)
                    if !trusted { body += "\n\n" + t("update_untrusted_hint") }
                    alert.informativeText = body
                    alert.window.title = "BLEUnlock"

                    // Build buttons and a parallel action list so response handling
                    // never depends on hard-coded first/second/third indices.
                    var actions: [UpdateDialogAction] = []
                    if !trusted {
                        alert.addButton(withTitle: t("trust_certificate_first")); actions.append(.trustFirst)
                    }
                    if let downloadURL {
                        let isZip = downloadURL.pathExtension.lowercased() == "zip"
                        alert.addButton(withTitle: t(isZip ? "install_update" : "download_update"))
                        actions.append(isZip ? .install : .browserDownload)
                    }
                    alert.addButton(withTitle: t("open_releases")); actions.append(.openReleases)
                    alert.addButton(withTitle: t("cancel")); actions.append(.cancel)

                    NSApp.activate(ignoringOtherApps: true)
                    let response = alert.runModal()
                    let idx = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                    guard idx >= 0 && idx < actions.count else { return }
                    switch actions[idx] {
                    case .trustFirst:
                        DispatchQueue.global(qos: .userInitiated).async {
                            let r = self.trustUpdaterCertificate()
                            DispatchQueue.main.async {
                                if r.ok { self.infoModal(t("cert_trust_done_reopen")) }
                                else { self.errorModal(t("cert_trust_failed"), info: r.message) }
                            }
                        }
                    case .install:
                        if let downloadURL {
                            installUpdate(fromZip: downloadURL) { errorMessage in
                                if let errorMessage {
                                    DispatchQueue.main.async {
                                        self.errorModal(t("update_install_failed"), info: errorMessage)
                                    }
                                }
                            }
                        }
                    case .browserDownload:
                        if let downloadURL { NSWorkspace.shared.open(downloadURL) }
                    case .openReleases:
                        NSWorkspace.shared.open(releaseURL)
                    case .cancel:
                        break
                    }
```
(The `savePendingUpdate(...)` and `self.refreshUpdateMenuItems()` calls that precede this block, and the `.upToDate`/`.failure`/`.intelUnsupported` cases, stay unchanged.)

- [ ] **Step 2: Check-Permissions line.** In `checkPermissions()`, after the event-script `if let path = resolveEventScriptPath() { … } else { … }` block and before `let alert = NSAlert()`:

```swift
        if isUpdaterCertTrusted() {
            items.append(PermissionItem(name: t("perm_updater_cert"), state: .ok, detail: ""))
        } else {
            items.append(PermissionItem(name: t("perm_updater_cert"), state: .info, detail: t("perm_updater_cert_untrusted")))
        }
```

- [ ] **Step 3: Strings.** Base:
```
"update_untrusted_hint" = "This build's certificate isn't trusted yet, so this update will re-ask for permissions. Choose \"Trust Certificate First\" to keep them across this and future updates.";
"trust_certificate_first" = "Trust Certificate First…";
"cert_trust_done_reopen" = "Certificate trusted. Choose \"Check for Updates…\" again to install — it will keep your permissions.";
"perm_updater_cert" = "Updater certificate";
"perm_updater_cert_untrusted" = "Not trusted — permissions re-prompt on each update. Use \"Trust Updater Certificate…\".";
```
de:
```
"update_untrusted_hint" = "Das Zertifikat dieses Builds ist noch nicht vertrauenswürdig, dieses Update fragt daher Rechte neu ab. Wähle „Zertifikat zuerst vertrauen", um sie über dieses und künftige Updates zu behalten.";
"trust_certificate_first" = "Zertifikat zuerst vertrauen…";
"cert_trust_done_reopen" = "Zertifikat vertraut. Wähle erneut „Nach Updates suchen…", um zu installieren — deine Freigaben bleiben erhalten.";
"perm_updater_cert" = "Updater-Zertifikat";
"perm_updater_cert_untrusted" = "Nicht vertraut — Rechte werden bei jedem Update neu abgefragt. Nutze „Updater-Zertifikat vertrauen…".";
```

- [ ] **Step 4: Build + lint + commit + merge + push**

```bash
xcodebuild -project BLEUnlock.xcodeproj -scheme BLEUnlock -configuration Release CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
git checkout -- BLEUnlock/Info.plist 2>/dev/null || true
plutil -lint BLEUnlock/Base.lproj/Localizable.strings BLEUnlock/de.lproj/Localizable.strings
git add -A
git commit -m "Surface cert trust in update dialog + Check Permissions"
git fetch fork && git checkout master && git rebase fork/master
git merge --no-ff feature/trust-updater-cert -m "Merge trust-updater-certificate"
git push fork master feature/trust-updater-cert
```
Expected: BUILD SUCCEEDED; strings `OK`; clean merge.

---

### Task 4: README + release v1.15.7

**Files:**
- Modify: `README.md`, `CHANGELOG.md`

- [ ] **Step 1: README** — under the install/permissions note, add a short paragraph:
```markdown
### Keeping permissions across updates

Because releases are signed with a self-signed certificate, macOS re-asks for
Bluetooth/Accessibility/Keychain access on every update unless that certificate is
trusted for code signing on your Mac. Use **Trust Updater Certificate…** from the
menu (one Touch ID / password prompt) to make your permissions persist across
updates. The update dialog also offers this the next time an update is available.
```

- [ ] **Step 2: CHANGELOG** — after `# Release Notes`:
```markdown
## 1.15.7

- New **Trust Updater Certificate…** menu item: trust the fork's signing certificate for code signing (one Touch ID prompt) so Bluetooth/Accessibility/Keychain permissions persist across updates instead of being re-requested each time. The update dialog now offers this before updating, and Check Permissions shows the trust status.
- About box now credits this as 7onnie's fork (based on Skyearn, originally by Takeshi Sone).
```
Commit both (`git fetch fork && git rebase fork/master && git push fork master`).

- [ ] **Step 3: Manual verification (user-driven; tag GATED on this):**
  1. Update to the build once; run **Trust Updater Certificate…** → Touch ID → "Certificate trusted".
  2. In Check Permissions, "Updater certificate" shows ✅.
  3. Then a subsequent update must NOT re-prompt for permissions (the real proof).
  4. On an untrusted state, the update dialog shows the hint + "Trust Certificate First…".

- [ ] **Step 4: Tag (only after Step 3 passes):**
```bash
git tag v1.15.7 && git push fork v1.15.7
```
Watch the Release action; confirm assets + stable Designated Requirement in the log.

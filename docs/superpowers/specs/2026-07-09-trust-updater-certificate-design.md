# Trust Updater Certificate — Design

**Datum:** 2026-07-09
**Status:** Approved (User + gemini_search Recherche + On-Device-Verifikation)

## Kontext & Problem

Fork-Releases sind mit einem stabilen self-signed Zertifikat signiert (CN „BLEUnlock
Fork Signing", SHA-1 `B81E475C8112BA5EE767A9FBD8DFCB2262A7030F`, = Leaf-Hash der
Designated Requirement). Ziel war, dass TCC-/Keychain-Freigaben (Bluetooth,
Accessibility, gespeichertes Passwort) In-App-Updates überleben.

**Bestätigtes Root-Cause-Verhalten:** Solange das Zertifikat auf dem Mac **nicht
als vertrauenswürdig** hinterlegt ist, keyt macOS-TCC die Freigaben an den **cdhash**
(ändert sich jeder Build) statt an die stabile Designated Requirement → **jedes
Update fragt Rechte + Keychain neu ab** (`spctl` weist die App als `rejected` ab).

**On-Device verifiziert (2026-07-09):** Nach
`security add-trusted-cert -r trustRoot -p codeSign -k login.keychain cert.pem`
(User-Domain, **kein sudo** — nur ein Touch-ID-/Passwort-Prompt) gilt:
`codesign -v -R="anchor trusted" /Applications/BLEUnlock.app` → **rc 0** (App
kettet zu einem vertrauenswürdigen Anker). Das ist die dokumentierte Bedingung,
unter der TCC auf die stabile DR keyt → Freigaben überleben Updates.
`spctl` bleibt `rejected` (Gatekeeper will Notarisierung) — für TCC irrelevant,
der einmalige Quarantäne-`xattr`-Schritt beim Erst-Download bleibt bestehen.

## Ziel

Dem User (und optional anderen Nutzern) einen **einfachen, erklärten Weg** geben,
das Updater-Zertifikat lokal zu vertrauen, damit künftige Updates keine erneute
Rechte-/Keychain-Abfrage auslösen. Opt-in, nie automatisch/still.

## Nicht im Scope (YAGNI / bewusst)

- Automatisches Vertrauen beim ersten Start (zu invasiv ohne explizite Zustimmung).
- Admin/System-Domain-Trust (User-Domain reicht erwiesenermaßen).
- Programmatische `SecTrustSettingsSetTrustSettings`-API (der verifizierte
  `security`-CLI-Weg ist erprobt und transparent).
- Zertifikats-Rotation / Ablauf-Handling.

## Komponenten

### 1. Öffentliches Zertifikat im Bundle

Die öffentliche `cert.pem` (aus `~/GitHubRepos/BLEUnlock-signing/`) wird als
`BLEUnlock/SigningCertificate.cer` ins Repo gelegt und als Bundle-Resource
registriert (pbxproj: PBXFileReference + PBXResourcesBuildPhase; **nicht** Sources).
Öffentlich → unbedenklich. Zur Laufzeit via
`Bundle.main.url(forResource: "SigningCertificate", withExtension: "cer")`.
(`security add-trusted-cert` akzeptiert PEM-Inhalt; die `.cer`-Endung ist nur der
Bundle-Name.)

### 2. Pures Modul `BLEUnlock/CertTrust.swift` (swiftc-testbar)

Dünne, reine Helfer; die `Process`-Ausführung selbst ist eine separate, dünne
Schicht (nicht rein, nicht Unit-getestet).

```swift
import Foundation

let SIGNING_CERT_SHA1 = "B81E475C8112BA5EE767A9FBD8DFCB2262A7030F"

/// Arguments for `security add-trusted-cert` to trust the signing cert for code
/// signing in the user-domain login keychain (verified working without sudo).
func addTrustedCertArguments(certPath: String, loginKeychainPath: String) -> [String] {
    return ["add-trusted-cert", "-r", "trustRoot", "-p", "codeSign",
            "-k", loginKeychainPath, certPath]
}

/// Arguments for `codesign` to test whether a bundle chains to a TRUSTED anchor
/// (the proxy for "TCC will key on the stable Designated Requirement").
func anchorTrustedArguments(bundlePath: String) -> [String] {
    return ["-v", "-R=anchor trusted", bundlePath]
}

/// rc 0 from the anchor-trusted codesign check means trusted.
func isBundleTrusted(codesignExitCode: Int32) -> Bool {
    return codesignExitCode == 0
}
```

### 3. Trust-Ausführung (dünne Schicht in AppDelegate)

- `func isUpdaterCertTrusted() -> Bool` — führt `/usr/bin/codesign` mit
  `anchorTrustedArguments(bundlePath: Bundle.main.bundlePath)` aus, gibt
  `isBundleTrusted(exitCode)` zurück. (Direkt „bin ICH gerade vertrauenswürdig?",
  braucht keine Cert-Datei.)
- `func trustUpdaterCertificate() -> (ok: Bool, message: String?)` — lokalisiert
  die Bundle-Resource, führt `/usr/bin/security` mit
  `addTrustedCertArguments(...)` und `~/Library/Keychains/login.keychain-db` aus
  (löst den Touch-ID-Prompt aus), gibt Erfolg/Fehlertext zurück. Fehlt die
  Resource → `(false, <lokalisierter Fehler>)`.

Beide nutzen das bestehende `Process`-Muster aus `UpdateInstaller.swift`
(`runTool`-artig, `waitUntilExit`, Exit-Code prüfen). Aufrufe erfolgen auf einem
Background-Queue (die `security`-Aktion blockiert bis der User Touch ID bestätigt),
UI-Feedback zurück auf den Main-Thread.

### 4. Menüpunkt „Trust Updater Certificate…"

Im Hauptmenü nahe „Check Permissions…". `@objc func trustUpdaterCertificateMenu()`:
- Wenn `isUpdaterCertTrusted()` → `infoModal(t("cert_already_trusted"))`, Ende.
- Sonst: Erklärungs-`NSAlert` (Titel `cert_trust_title`, Text
  `cert_trust_explain` — was passiert / warum / Sicherheitshinweis / rückgängig),
  Buttons „Trust" + „Cancel". Bei „Trust": `trustUpdaterCertificate()` auf
  Background-Queue; Ergebnis → `infoModal(t("cert_trust_done"))` bzw.
  `errorModal(t("cert_trust_failed"), info: message)`.

### 5. Hinweis im „Update Available"-Dialog (User-Wunsch)

In `checkForUpdates()` (`AppDelegate.swift:2153`), im `.available`-Zweig, VOR dem
Aufbau der Buttons: `let trusted = isUpdaterCertTrusted()`.
- Wenn **nicht** vertraut: an `alert.informativeText` einen Absatz
  `t("update_untrusted_hint")` anhängen (erklärt: „Zertifikat noch nicht
  vertraut → dieses Update fragt Rechte/Keychain neu ab; du kannst es jetzt
  vertrauen, dann bleibt es künftig still") und **vor** dem Install-Button einen
  Button `t("trust_certificate_first")` einfügen.
- Button-Handling wird index-basiert neu geordnet. Um die brüchige
  `.alertFirstButtonReturn`-Indexlogik zu vermeiden: die hinzugefügten
  `NSButton`-Referenzen (Rückgabe von `addButton`) merken und die `response`
  gegen `button.tag`/Identität vergleichen statt gegen feste First/Second/Third.
  Konkret: jedem Button ein eindeutiges `tag` setzen (z. B. 1000=trust,
  1001=install/download, 1002=releases, 1003=cancel) und im Handler
  `switch alert.buttons.first(where: { $0.tag == response.rawValue - ... })` —
  bzw. einfacher: die Buttons in bekannter Reihenfolge hinzufügen und die
  Response über den Offset in der `alert.buttons`-Liste auflösen. Der Plan legt
  die exakte, getestete Reihenfolge fest.
- Klick auf „Trust Certificate First": `trustUpdaterCertificate()` ausführen,
  Ergebnis melden, Dialog schließen; der User ruft „Check for Updates…" erneut
  auf (dann ist der Zustand vertraut und der Hinweis verschwindet). Kein
  automatisches Weiterlaufen ins Update — bewusst, damit der User die Kontrolle
  behält.

### 6. Zeile in „Check Permissions…"

In `checkPermissions()` (`AppDelegate.swift:2482`) eine informative
`PermissionItem`-Zeile ergänzen:
`t("perm_updater_cert")` mit Zustand `.ok` (trusted) bzw. `.info` (nicht trusted,
Detail `t("perm_updater_cert_untrusted")` → verweist auf „Trust Updater
Certificate…"). Kein `.fail`, da es kein hartes Rechte-Problem ist, nur
Update-Komfort.

## Lokalisierte Strings (Base + de)

Neue Keys (Base englisch, de deutsch), u. a.:
`cert_trust_title`, `cert_trust_explain`, `cert_trust_done`, `cert_trust_failed`,
`cert_already_trusted`, `trust_certificate_first`, `update_untrusted_hint`,
`perm_updater_cert`, `perm_updater_cert_untrusted`, sowie der Menütitel
`trust_updater_certificate`. Die exakten Texte liefert der Plan; der
Erklär-Text nennt Zweck, Sicherheitshinweis (alle mit diesem Zertifikat
signierten Builds gelten danach als vertrauenswürdig) und Rückgängig-Weg
(Schlüsselbundverwaltung / `security delete-certificate -c "BLEUnlock Fork Signing"`).

## Tests

`Tests/CertTrustTests/main.swift` (swiftc): `addTrustedCertArguments` (exakte
Flag-Reihenfolge inkl. `-p codeSign`, `-r trustRoot`, Pfade), `anchorTrustedArguments`,
`isBundleTrusted` (0 → true, ≠0 → false), `SIGNING_CERT_SHA1`-Konstante.
CI: Suite in `.github/workflows/test.yml` ergänzen (wie die anderen).
Manuell: Menüpunkt auf frischem Mac (nicht vertraut → Dialog → Touch ID → trusted);
Update-Dialog zeigt Hinweis nur wenn untrusted; nach Trust bleibt das nächste
Update still (der eigentliche Beweis).

## Dateien

- **Create** `BLEUnlock/CertTrust.swift`, `Tests/CertTrustTests/main.swift`,
  `BLEUnlock/SigningCertificate.cer` (öffentliche cert.pem)
- **Modify** `BLEUnlock/AppDelegate.swift` (Trust-Schicht, Menüpunkt, Update-Dialog-Hinweis,
  Check-Permissions-Zeile), beide `Localizable.strings`,
  `BLEUnlock.xcodeproj/project.pbxproj` (CertTrust.swift → Sources; SigningCertificate.cer → Resources),
  `.github/workflows/test.yml`, `README.md` (kurzer Abschnitt „Keep permissions across updates").

## Risiken & Mitigation

1. **Sicherheit:** Trusten macht ALLE mit dem Zertifikat signierten Builds lokal
   vertrauenswürdig — muss im Dialog klar erklärt + opt-in sein. Nur der Maintainer
   hält den privaten Key. Rückgängig-Weg dokumentiert.
2. **Bundle-Resource fehlt/zerstört:** `trustUpdaterCertificate` gibt sauberen
   Fehler, kein Crash.
3. **Update-Dialog-Button-Indizes:** brüchig bei Umordnung → Plan legt exakte
   Reihenfolge fest und löst die Response über die `alert.buttons`-Liste auf, nicht
   über hartkodierte First/Second/Third.
4. **Cert ≠ erwartetes:** die `SIGNING_CERT_SHA1`-Konstante erlaubt (optional) eine
   Sanity-Prüfung, dass die gebündelte Resource das erwartete Zertifikat ist.

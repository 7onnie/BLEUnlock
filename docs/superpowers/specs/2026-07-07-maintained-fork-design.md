# Maintained Fork: 7onnie/BLEUnlock — Design

**Datum:** 2026-07-07
**Status:** Approved (User + gemini_consensus Design-Review)

## Kontext & Ziel

Upstream `ts1/BLEUnlock` ist tot (letzter Code-Commit März 2024, letzter gemergter
PR Juni 2022, 15 offene PRs ohne Reaktion — darunter unsere #183/#184).
`7onnie/BLEUnlock` wird zum eigenständig gepflegten Fork mit eigenen GitHub-Releases.

Der Dritt-Fork `Skyearn/BLEUnlock` ist aktiv (98 Commits vor ts1, Releases im
Wochentakt, zuletzt v1.14.3) und bringt macOS-26-Kompatibilität, Multi-Device-Support,
einen neuen Update-Checker mit Auto-Download sowie eine Release-GitHub-Action mit.
Er wird als einmaliger Import übernommen und danach periodisch nachgemergt.

**Entscheidungen (User):**
- Voll-Fork ab ts1, `7onnie/BLEUnlock` ist kanonisch (nicht Downstream von Skyearn).
- Skyearn-Stand (= Upstream-PR #179 inkl. #185) komplett übernehmen.
- Upstream-PR #181 (Rename Device) **später** portieren, nicht im ersten Wurf.
- Kein Apple-Developer-Account → unsignierte Releases mit Ad-hoc-Signierung.

## 1. Repo- & Branch-Struktur

- Kanonisches Repo: `7onnie/BLEUnlock` (`master`).
- Neuer Remote `skyearn` → `https://github.com/Skyearn/BLEUnlock.git`.
- **Vendor-Branch-Pattern:** Branch `skyearn-upstream` spiegelt exakt
  `skyearn/master` (per `git reset --hard skyearn/master`, dann push zum Fork).
  Integration immer per `git merge skyearn-upstream` in `master` —
  initial (der große Import) und danach periodisch.
- Die bestehenden Branches `fix/smoothed-unlock-debounce` und
  `feature/wifi-auto-pause-gateway-mac` bleiben unverändert, damit die
  ts1-PRs #183/#184 intakt bleiben. Sie bleiben offen (kostet nichts).
- Die Ports von Part A/B entstehen als neue Branches auf der Skyearn-Basis
  und werden nach `master` gemergt.
- Merge-Konflikt-Regel: `Info.plist`-Versionsfelder gewinnen immer unsere.

## 2. Port Part A — Smoothed-Unlock-Gate auf Multi-Device

- `RSSIDecision.swift` bleibt pures, testbares Modul (keine BLE-Abhängigkeiten).
- Neu: Glättungs-State **pro Gerät** (`[DeviceID: State]` — gleitender Mittelwert,
  Sample-Count), da Skyearns Multi-Device-Umbau mehrere Devices parallel überwacht.
- Unlock-Gate greift **pro auslösendem Gerät**: entsperrt wird, wenn EIN Gerät
  das Gate (geglätteter RSSI + Mindest-Samples) besteht.
- Lock-Aggregation ("alle Geräte fern") bleibt Skyearns bestehende Logik —
  Part A gated nur den Unlock-Pfad.
- State-Reset: bei Pause/Resume (auch Wi-Fi-Pause aus Part B) und wenn sich die
  Geräteliste ändert, wird der Glättungs-State des betroffenen Geräts geleert,
  damit keine veralteten Samples eine Entscheidung tragen.

## 3. Port Part B — Wi-Fi-Auto-Pause auf Multi-Device

- `GatewayParsing.swift` und `NetworkMonitor.swift` unverändert übernehmen,
  inkl. der dokumentierten Harden-Abweichungen (**Startup default paused** —
  bewusste Design-Entscheidung, nicht "zurückfixen").
- Wi-Fi-Pause ist ein **globaler Schalter** oberhalb der Multi-Device-Logik:
  pausiert/resumed das gesamte BLE-Monitoring, nie einzelne Geräte.
- AppDelegate-Integration wird auf Skyearns umgebauten AppDelegate portiert;
  Menü zeigt den Pause-Grund an (wie im bisherigen Part B).
- Beim Resume: Glättungs-State aller Geräte zurücksetzen (siehe Part A).

## 4. Update-Kanal & Releases

- `checkUpdate.swift`: Release-API-URL von `Skyearn/BLEUnlock` auf
  `7onnie/BLEUnlock` umbiegen. Alle weiteren GitHub-Links (AboutBox,
  AppDelegate "releases"-Link) ebenfalls auf `7onnie`.
- **Korrektur (2026-07-08, nach Code-Lektüre):** Skyearns Updater installiert
  NICHT selbst — er notifiziert und öffnet den DMG-Download im Browser. Ein
  Browser-Download wird immer quarantiniert → Gatekeeper-Reibung bei jedem
  Update. Der Fork ergänzt daher (Intent des Konsens-Reviews, 3/3):
  - **Zip-Asset** zusätzlich zum DMG im Release.
  - **In-App-Installer**: lädt das Zip per URLSession (setzt für diese App
    keine Quarantäne), entpackt, `xattr -cr` (Gürtel-und-Hosenträger),
    ersetzt das Bundle, relauncht. Auslösung per Klick im Update-Dialog.
  - **CI ad-hoc-signiert** jedes Release: `codesign --force --deep --sign -`
    (braucht keinen Developer-Account; auf Apple Silicon Startvoraussetzung —
    Skyearns CI baut mit `CODE_SIGNING_ALLOWED=NO` komplett unsigniert).
  - Prüfen, dass `LSFileQuarantineEnabled` nicht im Info.plist gesetzt ist
    (verifiziert: ist nicht gesetzt).
- Release-Pipeline: Skyearns `release.yml` übernehmen (läuft ohne
  Signing-Secrets, überspringt den Cert-Import sauber), um den
  Ad-hoc-Signing-Step ergänzen. Trigger: Tag-Push.
- **Versionierung:** Start bei `1.15.0` (über Skyearns 1.14.3 und ts1s 1.12.2).
  Regel: nach jedem Skyearn-Merge liegt unsere Version über dessen letzter
  Release-Version. Kein Fork-Suffix nötig — unser Update-Checker zeigt nur
  auf unser eigenes Repo, Skyearns Nummern kommen nie in den Vergleich.
- **Pflicht vor dem ersten echten Release:** E2E-Test des Update-Pfads
  (Dummy-Release 1.15.0 → 1.15.1 auf einem Test-Mac: Auto-Download, Ersetzen,
  Neustart, App läuft).

## 5. README & Doku

- Fork-Notice: maintained fork of `ts1/BLEUnlock`, based on `Skyearn/BLEUnlock`,
  mit Credits an beide.
- Erstinstallations-Hinweis für unsignierte Builds (Rechtsklick-Öffnen bzw.
  `xattr -dr com.apple.quarantine`).
- Kurzdoku der Fork-Features (Smoothed-Unlock-Gate, Wi-Fi-Auto-Pause).

## 6. Tests & Verifikation

- Bestehende `swiftc`-Testsuiten (`Tests/RSSIDecisionTests`,
  `Tests/GatewayParsingTests`) auf die neue Basis portieren; RSSIDecision-Tests
  um Per-Device-State-Fälle erweitern.
- Skyearns Test-Workflows (`test.yml`, `test-build.yml`) weiterlaufen lassen.
- Manueller Multi-Device-Test (Gerät kommt/geht, Pause/Resume, Mac-Schlaf).
- E2E-Update-Test (siehe Abschnitt 4).
- Bekannte Falle: `xcodebuild` bumpt `BLEUnlock/Info.plist` (CFBundleVersion)
  per Run-Script-Phase — nach Builds `git checkout -- BLEUnlock/Info.plist`.

## Risiken (aus dem Consensus-Review)

1. **Update-Self-Brick** bei unsignierten Auto-Updates → mitigiert durch
   Ad-hoc-Signing + Quarantäne-Strip + E2E-Test (Abschnitt 4).
2. **Merge-/Portierungsaufwand in BLE.swift/AppDelegate.swift** — Skyearn hat
   genau die Dateien umgebaut, die A/B anfassen. Mitigation: A/B so modular
   wie möglich halten (pure Module + dünne Integrationspunkte), Skyearn
   regelmäßig statt selten nachmergen.
3. **Multi-Device-Lock/Unlock-Fehlverhalten** (Gerät verschwindet, Timeouts,
   Race beim Pause/Resume). Mitigation: Per-Device-State-Reset-Regeln
   (Abschnitt 2/3), erweiterte Tests, manuelles Testszenario.

## Später / explizit nicht im Scope

- Upstream-PR #181 (Rename Device) — eigener Port nach Stabilisierung.
- Notarisierung / Developer-ID-Signing — nur falls Distribution über die
  eigenen Macs hinaus gewünscht wird.
- Rückführung von Patches an Skyearn (PRs) — optional, jederzeit möglich.

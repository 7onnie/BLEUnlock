# TCC-Registrierung beim Klick auf „Einstellungen öffnen"

**Datum:** 2026-07-18
**Status:** Approved (Design-Review via gemini_consensus durchgeführt, Ansatz A gewählt)

## Problem

Der „Berechtigungen prüfen"-Dialog (`checkPermissions()`, AppDelegate.swift) meldet
fehlende Accessibility-/Bluetooth-Berechtigungen und öffnet auf Klick die passende
Privacy-Pane in den System-Einstellungen. Auf betroffenen Systemen fehlt der
BLEUnlock-Eintrag dort aber komplett — der User kann keinen Haken setzen. Die
Bluetooth-Pane hat keinen „+"-Button; der Eintrag muss von macOS selbst angelegt
werden, was nur passiert, wenn die App den jeweiligen TCC-Prompt-Pfad auslöst.

Erschwerend: Der bestehende Recovery-Pfad (`recoverAfterPermissionChangeIfNeeded`,
BLE.swift) greift nur, wenn `scanMode` aktiv ist oder Geräte überwacht werden und
Monitoring nicht suspendiert ist. Beim bewusst pausierten Start (Part-B-Verhalten)
läuft er nie — die Registrierung passiert also nicht von allein.

## Lösung (Ansatz A: nur Registrieren, kein tccutil)

Der Report bleibt vollständig read-only. Erst der Klick auf **„Einstellungen
öffnen"** registriert die App aktiv bei TCC, in dieser Reihenfolge:

1. `NSApp.activate(ignoringOtherApps: true)` — Pflicht bei LSUIElement-Apps,
   sonst erscheint der System-Prompt unsichtbar im Hintergrund.
2. Wenn Accessibility nicht trusted: `checkAccessibility(showPrompt: true)`.
   `AXIsProcessTrustedWithOptions([prompt: true])` legt den Eintrag in der
   Bedienungshilfen-Liste an, auch wenn der User den System-Prompt wegklickt
   (der Eintrag erscheint dann ohne Haken). Der bestehende Fn-Key-Fallback in
   `checkAccessibility` bleibt unverändert.
3. Wenn Bluetooth-Authorization `.notDetermined`: `ble.triggerAuthorizationPrompt()`
   (neu, siehe unten) → System-Prompt + Eintrag in der Bluetooth-Liste.
4. Danach wie bisher die passende Privacy-Pane per URL öffnen. Die
   Pane-Priorität bleibt unverändert (Accessibility vor Bluetooth vor Automation).

Schritte 2 und 3 laufen **beide** (sofern jeweils fällig), unabhängig davon,
welche Pane anschließend geöffnet wird — ein Klick registriert alles Fehlende.

## Code-Änderungen

### BLE.swift — neue Methode `triggerAuthorizationPrompt()`

Erzeugt den `CBCentralManager` neu (Muster wie in
`recoverAfterPermissionChangeIfNeeded`: `stopScan()`, `delegate = nil`, neue
Instanz), aber **ohne** die Guards `scanMode`/`monitoredUUIDs`/
`monitoringSuspended`. Wiederverwendet wird nur das bestehende
2-Sekunden-Rate-Limit über `lastAuthorizationRefreshAt` /
`minimumAuthorizationRefreshInterval`, damit kein Manager-Churn entsteht.

### AppDelegate.swift — `checkPermissions()`

Im Handler des zweiten Buttons („Einstellungen öffnen"), vor dem Öffnen der
URL: Schritte 1–3 von oben. Der Doc-Kommentar über `checkPermissions()` wird
angepasst: Report read-only, Registrierung erst auf Button-Klick.

### Keine weiteren Änderungen

- Keine neuen Localized Strings.
- Keine Info.plist-Änderung (`NSBluetoothAlwaysUsageDescription` existiert).
- Kein `tccutil`-Aufruf (bewusst gegen Ansatz B entschieden).

## Edge Cases

- **Bluetooth `.denied` mit fehlendem Listeneintrag** (stale TCC-Eintrag durch
  cdhash-Wechsel alter Builds): wird bewusst nicht repariert — bei `.denied`
  feuert kein neuer Prompt. Manueller Ausweg für Betroffene:
  `tccutil reset Bluetooth com.github.7onnie.BLEUnlock` (läuft ohne sudo),
  danach erneut „Einstellungen öffnen". Wird im Changelog dokumentiert.
- **Doppelklicks / wiederholte Checks:** Das 2-Sekunden-Rate-Limit in
  `triggerAuthorizationPrompt()` verhindert schnelles Neu-Erzeugen des Managers.
- **Seiteneffekte des neuen Managers:** `centralManagerDidUpdateState` feuert
  nach der Neu-Instanziierung; Scan-Wiederaufnahme bleibt durch die bestehenden
  `monitoringSuspended`-Guards geschützt.
- **Accessibility bereits trusted, nur Bluetooth fehlt:** Schritt 2 entfällt,
  Schritt 3 läuft, geöffnet wird die Bluetooth-Pane (bestehende Priorität).

## Verifikation (manuell)

1. Testvorbereitung auf dem Entwickler-Mac:
   `tccutil reset Accessibility com.github.7onnie.BLEUnlock` und
   `tccutil reset Bluetooth com.github.7onnie.BLEUnlock`.
2. Build starten, „Berechtigungen prüfen" → beide als fehlend gemeldet.
3. „Einstellungen öffnen" klicken → AX-Prompt und Bluetooth-Prompt erscheinen;
   in beiden Privacy-Panes existiert jetzt ein BLEUnlock-Eintrag, Haken setzbar.
4. Nach `xcodebuild` den automatischen Info.plist-Version-Bump revertieren.

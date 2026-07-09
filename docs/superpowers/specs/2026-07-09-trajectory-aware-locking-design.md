# Trajectory-Aware Locking — Design

**Datum:** 2026-07-09
**Status:** Approved (User + gemini_consensus Design-Review)

## Kontext & Ziel

BLEUnlock sperrt heute mit fixen Verzögerungen: `proximityTimeout` (Default 5 s,
Menü „Delay to Lock") nach Unterschreiten der Lock-Schwelle, und `signalTimeout`
(Default 60 s, Menü „No-Signal Timeout") bei totalem Signalverlust. Das führt zu
träger Sperr-Reaktion — insbesondere wenn man schnell weggeht und das Signal
abreißt, wartet der Mac bis zu 60 s.

Ziel: **Sperr-Latenz senken, indem die Flugbahn (Trajektorie) des RSSI die
Sperr-Dringlichkeit bestimmt** — nicht nur der Momentanpegel. Der **Entsperr-Pfad
bleibt unangetastet** (konservativ, sicherheitskritisch). Active Mode (~1 Messwert/s
über `readRSSI` auf verbundener Peripheral) ist der Regelfall.

**Invariante (sicherheitskritisch):** Die adaptive Logik sperrt **nur schneller**
als die konfigurierten Timeouts, **nie langsamer**. Früher sperren ist die
fail-safe-Richtung; die vom User gesetzten `proximityTimeout`/`signalTimeout`
bleiben Obergrenzen.

## Bestehende Mechanik (Ausgangspunkt)

- `getEstimatedRSSI(state:rssi:)` — Median-of-5 der Rohwerte (`BLE.swift:707`).
  Bleibt unverändert.
- `updateMonitoredState` (`BLE.swift:718`): glättet, prüft `shouldUnlock`, und
  verwaltet den `proximityTimer` (startet EINMAL beim ersten Unterschreiten der
  Lock-Schwelle, fix `proximityTimeout`; wird gecancelt, sobald ein Wert wieder
  ≥ Schwelle ist — `BLE.swift:737-755`).
- `resetSignalTimer(for:)` (`BLE.swift:652`): wird am Ende jedes
  `updateMonitoredState` aufgerufen und zieht einen Einmal-Timer über fix
  `signalTimeout` neu auf. Er feuert nur, wenn Messwerte **ausbleiben** → sperrt
  bei Signalverlust.
- Hysterese: unlock −60, lock −80 (Defaults) verhindert Flattern.
- Multi-Device: pro-Gerät `MonitoredDeviceState`, Aggregation „lock wenn alle weg"
  (`updateAggregatePresence`). Bleibt unverändert.

## Neues pures Modul: `BLEUnlock/LockDecision.swift`

Analog zu `RSSIDecision.swift`: keine BLE-/AppKit-Abhängigkeiten, per `swiftc`
testbar. Drei reine Funktionen plus die internen Konstanten.

### Konstanten (interne Defaults, keine Menüpunkte)

```
SLOPE_WINDOW        = 5       // geglättete Samples für die Regression (~5 s @1Hz)
FALLING_SLOPE       = -1.5    // dB/Sample; steiler (negativer) = fallender Trend
MIN_PROXIMITY_DELAY = 2.0 s   // Untergrenze adaptiver proximity-Debounce
TREND_LOSS_DELAY    = 3.0 s   // Signalverlust NACH fallendem Trend
DROPOUT_GRACE_STRONG= 15.0 s  // Verlust aus starkem, stabilem Signal (transient)
DROPOUT_GRACE_WEAK  = 5.0 s   // Verlust aus schon schwachem Signal
STRONG_RSSI         = -70     // ≥ dieser Wert gilt als "stark" für die Staffelung
```

### `rssiSlope(_ history: [Int]) -> Double`

Least-Squares-Steigung (dB pro Sample) über die zuletzt bis zu `SLOPE_WINDOW`
geglätteten Werte. Negativ = fallend. Bei < 2 Werten → 0 (kein Trend feststellbar).

```swift
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
```

### `adaptiveLockDelay(estimatedRSSI:lockThreshold:slope:baseDelay:) -> TimeInterval`

Für den Fall „Pegel unter Lock-Schwelle, Signal noch da". Verkürzt `baseDelay`
(= `proximityTimeout`) proportional zur Dringlichkeit; Ergebnis in
`[MIN_PROXIMITY_DELAY, baseDelay]`.

Dringlichkeit `u ∈ [0,1]` = Maximum aus:
- **Tiefe:** wie weit unter der Schwelle — `depth = lockThreshold - estimatedRSSI`,
  linear skaliert: `min(1, max(0, depth) / 15)` (≥15 dB drunter → volle
  Dringlichkeit).
- **Steilheit:** `slope <= FALLING_SLOPE` → linear bis zu einer Kappung bei
  `slope <= 2*FALLING_SLOPE` → volle Dringlichkeit.

`delay = baseDelay - u * (baseDelay - MIN_PROXIMITY_DELAY)`, geklemmt.
Ist `baseDelay <= MIN_PROXIMITY_DELAY` (User hat sehr kurz konfiguriert), gib
`baseDelay` zurück (Invariante: nie langsamer als konfiguriert).

### `signalLossDelay(slope:lastEstimatedRSSI:cap:) -> TimeInterval`

Für den Fall „Messwerte bleiben aus" — bestimmt das Intervall des Signal-Timers.
- **Fallender Trend** (`slope <= FALLING_SLOPE`) → `TREND_LOSS_DELAY`.
- **Kein Trend, letztes Signal schwach** (`lastEstimatedRSSI < STRONG_RSSI`) →
  `DROPOUT_GRACE_WEAK`.
- **Kein Trend, letztes Signal stark** (`>= STRONG_RSSI`) → `DROPOUT_GRACE_STRONG`.

Ergebnis immer `min(result, cap)` mit `cap = signalTimeout` (Invariante).

## Integration in `BLE.swift`

### `MonitoredDeviceState`

Neues Feld `estimatedHistory: [Int]` (Cap `SLOPE_WINDOW`). In allen bestehenden
Reset-Pfaden mitleeren, wo `rssiWindow` geleert wird (`suspendMonitoringForSystemSleep`,
`resetSignalTimer`-Verlust-Block, `clearSmoothingWindows`).

### `updateMonitoredState`

1. Nach `let estimatedRSSI = getEstimatedRSSI(...)`: `estimatedHistory` anhängen,
   auf `SLOPE_WINDOW` kappen.
2. Steigung berechnen: `let slope = rssiSlope(state.estimatedHistory)`.
3. **Proximity-Timer-Block** (`BLE.swift:737-755`): unverändert in der Struktur
   (Timer wird weiterhin EINMAL beim ersten Unterschreiten gestartet, gecancelt
   sobald wieder ≥ Schwelle — keine Neuberechnung pro Read, kein Race). Nur die
   Dauer wird adaptiv:
   ```swift
   let base = proximityTimeout
   let delay = state.estimatedHistory.count >= SLOPE_WINDOW
       ? adaptiveLockDelay(estimatedRSSI: estimatedRSSI, lockThreshold: lockThresh,
                           slope: slope, baseDelay: base)
       : base   // Warm-up: konservativ, bis Historie voll
   ```
   `delay` als `withTimeInterval` des `proximityTimer`.

### `resetSignalTimer`

Statt fix `signalTimeout`:
```swift
let slope = rssiSlope(state.estimatedHistory)
let interval = state.estimatedHistory.count >= SLOPE_WINDOW
    ? signalLossDelay(slope: slope, lastEstimatedRSSI: state.lastRSSI ?? 0,
                      cap: signalTimeout)
    : signalTimeout   // Warm-up: konservativ
```
`interval` als Timer-Dauer. Weil `resetSignalTimer` bei jedem Read läuft, „friert"
der zuletzt berechnete Wert ein, sobald die Reads ausbleiben — genau das gewünschte
Verhalten. Kein neuer Disconnect-Hook nötig.

## Logging

Beim Start des Proximity-Timers und beim Setzen des Signal-Timer-Intervalls je eine
`print`-Zeile mit `slope`, gewählter Dauer und Grund (Debugbarkeit; die App loggt
ohnehin über `print`).

## Tests

`Tests/LockDecisionTests/main.swift` (swiftc, kein XCTest), deckt ab:
- `rssiSlope`: leere/1-Element-Historie → 0; monoton fallend → negativ; monoton
  steigend → positiv; verrauscht-aber-fallend → negativ; konstant → 0.
- `adaptiveLockDelay`: knapp unter Schwelle + flach → ≈ baseDelay; tief drunter →
  ≈ MIN_PROXIMITY_DELAY; steiler Trend → verkürzt; `baseDelay < MIN` → baseDelay
  (nie länger); Ergebnis immer in `[MIN_PROXIMITY_DELAY, baseDelay]`.
- `signalLossDelay`: fallender Trend → TREND_LOSS_DELAY; kein Trend + schwach →
  WEAK; kein Trend + stark → STRONG; `cap` kleiner als Ergebnis → `cap`.

Manuell (Integration): Weggeh- und Ankomm-Timing vorher/nachher messen; transienter
Dropout (iPhone kurz in die Tasche) darf NICHT sofort sperren.

## Dateien

- **Create** `BLEUnlock/LockDecision.swift` (pures Modul)
- **Create** `Tests/LockDecisionTests/main.swift`
- **Modify** `BLEUnlock/BLE.swift` (`MonitoredDeviceState` + `updateMonitoredState`
  + `resetSignalTimer` + Reset-Pfade)
- **Modify** `BLEUnlock.xcodeproj/project.pbxproj` (LockDecision.swift ins Target,
  4 Sections wie bei RSSIDecision.swift)

## Risiken & Mitigation (aus dem Consensus-Review)

1. **Fehl-Sperren während der User anwesend ist** (Top-Risiko): konservative
   Untergrenzen (2 s/3 s), Regression statt Endpunkt-Differenz, Mindest-Steilheit,
   Warm-up-Fallback. Manuelle Tests in verschiedenen Umgebungen vor Release.
2. **Kompound-Latenz** (Median-Lag + Slope-Fenster): akzeptiert; Ziel ist
   „schneller als fix", nicht instant. Steigung bleibt auf geglätteten Werten
   (Rohwerte wären unbrauchbar).
3. **Timer-Race**: Proximity-Delay wird EINMAL beim Timer-Start berechnet (nicht
   pro Read neu → kein „feuert nie"); alle Timer auf dem Main-RunLoop wie bisher.
4. **Multi-Device**: pro-Gerät-Trajektorie, Aggregation „lock wenn alle weg"
   unverändert — ein Gerät mit fallendem Trend sperrt nicht, solange ein anderes
   präsent ist (gewollt).

## Bewusst nicht im Scope (YAGNI / User-Entscheidung)

- Konfigurierbarkeit / neue Menüpunkte (User: „smarte Defaults, keine Knöpfe").
- R²-Konfidenz der Regression, „Locking in Xs"-Statusanzeige, Dual-Filter
  roh+geglättet, Änderung des Median-Filters. Können später folgen, falls Tests
  es nahelegen.

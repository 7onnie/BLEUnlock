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

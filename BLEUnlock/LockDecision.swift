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

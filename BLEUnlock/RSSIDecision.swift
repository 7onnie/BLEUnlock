import Foundation

/// Pure gate for the unlock / presence transition.
///
/// A lone RSSI spike cannot flip presence: the *smoothed* value must cross the threshold,
/// the window must already hold at least `minSamples` readings, and we only unlock when
/// not already present.
func shouldUnlock(estimatedRSSI: Int,
                  sampleCount: Int,
                  unlockThreshold: Int,
                  minSamples: Int,
                  isPresent: Bool) -> Bool {
    return !isPresent && sampleCount >= minSamples && estimatedRSSI >= unlockThreshold
}

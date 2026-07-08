import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("ok   - \(msg)") } else { print("FAIL - \(msg)"); failures += 1 }
}

check(preferredUpdateAssetName(["BLEUnlock-v1.15.0.dmg", "BLEUnlock-v1.15.0.zip"]) == "BLEUnlock-v1.15.0.zip",
      "zip preferred over dmg")
check(preferredUpdateAssetName(["BLEUnlock-v1.15.0.dmg"]) == "BLEUnlock-v1.15.0.dmg",
      "dmg fallback when no zip")
check(preferredUpdateAssetName(["Source.tar.gz"]) == nil,
      "unknown assets -> nil")
check(preferredUpdateAssetName([]) == nil, "empty -> nil")
check(preferredUpdateAssetName(["A.ZIP"]) == "A.ZIP", "case-insensitive match")

if failures == 0 { print("\nALL PASS") } else { print("\n\(failures) FAILURE(S)"); exit(1) }

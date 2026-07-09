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

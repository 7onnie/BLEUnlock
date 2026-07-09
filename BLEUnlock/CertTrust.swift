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

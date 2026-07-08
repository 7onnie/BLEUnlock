import Foundation

/// Pick the release asset the in-app installer can handle: a .zip lets us
/// download via URLSession (no quarantine) and swap the bundle in place;
/// a .dmg is only offered as a browser download.
func preferredUpdateAssetName(_ names: [String]) -> String? {
    if let zip = names.first(where: { $0.lowercased().hasSuffix(".zip") }) {
        return zip
    }
    return names.first(where: { $0.lowercased().hasSuffix(".dmg") })
}

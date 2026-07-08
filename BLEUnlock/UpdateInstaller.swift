import Cocoa

/// Downloads a release .zip, unpacks it, strips quarantine, replaces the running
/// app bundle and relaunches. Needed because fork releases are only ad-hoc signed:
/// a browser download would trip Gatekeeper on every single update, while a
/// URLSession download from the app itself is not quarantined.
func installUpdate(fromZip zipURL: URL, completion: @escaping (String?) -> Void) {
    let task = URLSession.shared.downloadTask(with: zipURL) { tempFile, _, error in
        if let error = error {
            completion(error.localizedDescription)
            return
        }
        guard let tempFile = tempFile else {
            completion("Download produced no file")
            return
        }
        do {
            let fm = FileManager.default
            let workDir = fm.temporaryDirectory
                .appendingPathComponent("BLEUnlockUpdate-\(UUID().uuidString)")
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
            try runTool("/usr/bin/ditto", ["-xk", tempFile.path, workDir.path])

            guard let appName = try fm.contentsOfDirectory(atPath: workDir.path)
                .first(where: { $0.hasSuffix(".app") }) else {
                completion("No .app found in update archive")
                return
            }
            let newApp = workDir.appendingPathComponent(appName)
            // Belt and braces: strip quarantine in case a future macOS quarantines
            // URLSession downloads after all.
            try? runTool("/usr/bin/xattr", ["-cr", newApp.path])

            let currentApp = Bundle.main.bundleURL
            _ = try fm.replaceItemAt(currentApp, withItemAt: newApp,
                                     backupItemName: nil, options: [])
            completion(nil)
            DispatchQueue.main.async { relaunch(appURL: currentApp) }
        } catch {
            completion(error.localizedDescription)
        }
    }
    task.resume()
}

private func runTool(_ path: String, _ args: [String]) throws {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    try proc.run()
    proc.waitUntilExit()
    if proc.terminationStatus != 0 {
        throw NSError(domain: "UpdateInstaller", code: Int(proc.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "\(path) exited with \(proc.terminationStatus)"])
    }
}

private func relaunch(appURL: URL) {
    // Give the terminating process a moment to exit before the new one starts.
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = ["-c", "sleep 1; /usr/bin/open -n \"\(appURL.path)\""]
    try? proc.run()
    NSApp.terminate(nil)
}

import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("ok   - \(msg)") } else { print("FAIL - \(msg)"); failures += 1 }
}

let items = [
    PermissionItem(name: "Accessibility", state: .ok, detail: ""),
    PermissionItem(name: "Bluetooth", state: .fail, detail: "Radio is off"),
    PermissionItem(name: "Event script", state: .info, detail: "Optional"),
]
let text = permissionReportText(items)
check(text.contains("✅ Accessibility"), "ok item rendered with check mark")
check(text.contains("❌ Bluetooth\n    Radio is off"), "fail item renders detail on indented line")
check(text.contains("ℹ️ Event script"), "info item uses info symbol")
check(!permissionReportText([PermissionItem(name: "A", state: .ok, detail: "")]).contains("\n    "), "no detail => no indented line")
check(hasPermissionFailure(items) == true, "failure detected when a fail item present")
check(hasPermissionFailure([PermissionItem(name: "A", state: .ok, detail: ""), PermissionItem(name: "B", state: .info, detail: "")]) == false, "no failure when only ok/info")

if failures == 0 { print("\nALL PASS") } else { print("\n\(failures) FAILURE(S)"); exit(1) }

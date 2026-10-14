// Requires a running app on macOS 27 and permission to post events; clicks only the status item.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let snapshotURL = root.appendingPathComponent("local/status-item-window.json")
precondition(CGPreflightPostEventAccess(), "Enable Accessibility access for the test process.")

func snapshot() throws -> [String: Double] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL)) as! [String: Double]
}

func clickStatusItem() throws {
    let value = try snapshot()
    let point = CGPoint(x: value["x"]! + value["width"]! / 2, y: value["y"]! + value["height"]! / 2)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
    }
    Thread.sleep(forTimeInterval: 0.5)
}

let initial = try snapshot()
precondition(initial["nativeSessionActive"] != nil, "Start the app on macOS 27 before running this check.")
if initial["nativeSessionActive"] == 1 { try clickStatusItem() }
try clickStatusItem()
let opened = try snapshot()
assert(opened["nativeSessionActive"] == 1, "Opening must activate native selection.")
try clickStatusItem()
let closed = try snapshot()
assert(closed["nativeSessionActive"] == 0, "The second click must clear native selection.")
try clickStatusItem()
let reopened = try snapshot()
assert(reopened["nativeSessionActive"] == 1, "Reopening must restore native selection.")
print("Native status selection checks passed.")

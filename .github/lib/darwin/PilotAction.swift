//
//  PilotAction.swift — the effector: one action per call, then the report.
//
//  The action names, parameter names, validation order, timing constants, message
//  wording and result keys are the Windows ones (see _dsh-action.ps1): a model that
//  learned to drive this plugin on one platform should not have to relearn it on the
//  other. What changes is underneath — CGEvent instead of mouse_event/keybd_event,
//  the Accessibility API instead of UI Automation, Command-V instead of Ctrl-V.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// True once the accessibility tree of some window has produced a real listing.
/// Browsers build their tree lazily: the first request in a session can come back
/// with three elements and the next one with eighty, so the first small listing is
/// retried once.
var uiWarmed = false

/// Absolute capture pixels to global display points, with the range check that makes
/// a stale coordinate fail loudly instead of clicking wherever the pointer happens
/// to be.
func targetPoint(x: Int, y: Int, what: String, space: ScreenSpace) throws -> CGPoint {
	let bounds = space.pixelBounds
	let inside = !(CGFloat(x) < bounds.minX || CGFloat(y) < bounds.minY || CGFloat(x) >= bounds.maxX || CGFloat(y) >= bounds.maxY)
	guard inside else {
		throw PilotError("\(what) point (\(x),\(y)) is outside the virtual desktop (\(Int(bounds.minX)),\(Int(bounds.minY)),\(Int(bounds.width)),\(Int(bounds.height))); screenshots are physical pixels, so re-read the image before acting")
	}
	return space.points(CGPoint(x: CGFloat(x), y: CGFloat(y)))
}

/// Resolve the point a pointer action should hit: explicit x/y, or a control index
/// standing in for them.
func anchoredPoint(_ params: Params, what: String, space: ScreenSpace) throws -> CGPoint {
	if let targetText = params.string("target"), !targetText.trimmingCharacters(in: .whitespaces).isEmpty {
		return try controlPoint(params, targetText: targetText, space: space)
	}
	guard let x = params.int("x"), let y = params.int("y") else {
		throw PilotError("\(what) requires both x and y")
	}
	return try targetPoint(x: x, y: y, what: what, space: space)
}

/// The centre of a control listed by `controls`, in points.
func controlPoint(_ params: Params, targetText: String, space: ScreenSpace) throws -> CGPoint {
	guard let index = Int(targetText.trimmingCharacters(in: .whitespaces)) else {
		throw PilotError("target must be the index of a control listed by 'controls', got '\(targetText)'")
	}
	let entry: WindowEntry
	if let title = params.string("title")?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
		guard let found = findWindow(title) else {
			throw PilotError("target \(index) needs a window: no visible top-level window matches '\(title)'")
		}
		entry = found
	} else if let hwnd = parseWindowId(params.string("hwnd")) {
		guard let found = windowList(all: true).first(where: { $0.id == hwnd }) else {
			throw PilotError("the target window (hwnd \(params.string("hwnd") ?? "")) no longer exists; re-read the screen and target a live window")
		}
		entry = found
	} else {
		throw PilotError("target \(index) needs a window: pass title or hwnd with it")
	}
	let pixel = try targetCentre(index: index, window: entry, scale: space.scale)
	return space.points(pixel)
}

/// `0x1094C` or a decimal window id, the way the Windows sensor accepted a handle.
func parseWindowId(_ text: String?) -> CGWindowID? {
	guard var raw = text?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
	if raw.lowercased().hasPrefix("0x") {
		raw = String(raw.dropFirst(2))
		guard let value = UInt32(raw, radix: 16) else { return nil }
		return value == 0 ? nil : CGWindowID(value)
	}
	guard let value = UInt32(raw) else { return nil }
	return value == 0 ? nil : CGWindowID(value)
}

/// Bring a window forward before an action lands in it, or say why not. `tolerant`
/// is the only thing that downgrades a refusal to a note, exactly as on Windows: a
/// click that may land in the wrong window is the caller's decision, not a default.
func assertFocus(_ params: Params, notes: inout [String]) throws {
	let tolerant = params.bool("tolerant") ?? false
	var label = ""
	var entry: WindowEntry?

	if let hwnd = parseWindowId(params.string("hwnd")) {
		guard let found = windowList(all: true).first(where: { $0.id == hwnd }) else {
			throw PilotError("the target window (hwnd \(params.string("hwnd") ?? "")) no longer exists")
		}
		label = "hwnd \(String(format: "0x%X", hwnd))"
		entry = found
	} else {
		guard let title = params.string("title")?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return }
		guard let found = findWindow(title) else {
			throw PilotError("no visible top-level window matches '\(title)'; pass an hwnd if the window is hidden")
		}
		label = "'\(found.title)'"
		entry = found
	}

	guard let target = entry else { return }
	if target.id == focusedId || frontmostPid() == target.pid { return }
	_ = activateWindow(target)
	sleepMS(220)
	guard frontmostPid() == target.pid else {
		let holder = foregroundTitle()
		if tolerant {
			notes.append("macOS would not hand focus to \(label); '\(holder)' kept it (tolerant: continuing).")
			return
		}
		throw PilotError("could not bring \(label) to the foreground; '\(holder)' still holds it, so the rest of this batch would land there. Pass tolerant: true on this step if the coordinates are right either way.")
	}
}

/// Poll briefly until the pointer actually arrived. Warping is asynchronous, so a
/// click posted immediately after it can be read at the old position.
func waitForCursor(_ point: CGPoint) {
	let deadline = Date().addingTimeInterval(0.2)
	while Date() < deadline {
		let now = mouseLocation()
		if abs(now.x - point.x) < 1, abs(now.y - point.y) < 1 { return }
		sleepMS(10)
	}
}

/// The settle window between an action and the frame taken after it, sliced so an
/// interruption is noticed within about a tenth of a second.
func settle(_ milliseconds: Int, cancelFile: String) throws {
	var remaining = max(0, milliseconds)
	while remaining > 0 {
		try assertAlive(cancelFile)
		let slice = min(120, remaining)
		sleepMS(slice)
		remaining -= slice
	}
}

/// The common result tail: where the pointer ended up, what is in front, the notes.
func actionReport(action: String, notes: [String], space: ScreenSpace) -> [String: Any] {
	let cursorPixel = space.pixels(mouseLocation())
	var report: [String: Any] = [
		"ok": true,
		"action": action,
		"cursor": ["x": Int(cursorPixel.x.rounded()), "y": Int(cursorPixel.y.rounded())],
		"foregroundTitle": foregroundTitle(),
		"foregroundClass": foregroundClass(),
		"notes": notes,
		"actedAt": timestamp()
	]
	// A null here would be rejected by the closed output schema; an absent key is
	// simply not rendered.
	if let process = foregroundProcess() { report["foregroundProcess"] = process }
	return report
}

/// Run one action request.
func runAction(_ params: Params) throws -> [String: Any] {
	let cancelFile = params.cancelFile

	// Validation order parity: `button` is checked for every action, not only the
	// pointer ones, because that is what the Windows helper does.
	var button = MouseButtonName.left
	if let raw = params.string("button") {
		let lowered = raw.trimmingCharacters(in: .whitespaces).lowercased()
		guard let parsed = MouseButtonName(rawValue: lowered) else {
			throw PilotError("button must be left, right, or middle (got '\(raw)')")
		}
		button = parsed
	}

	guard let rawAction = params.string("action")?.trimmingCharacters(in: .whitespaces), !rawAction.isEmpty else {
		throw PilotError("action is required")
	}
	let action = rawAction
	var notes: [String] = []
	let space = ScreenSpace()

	try assertAlive(cancelFile)

	switch action {
	case "click", "doubleClick", "rightClick", "middleClick", "move":
		let point = try anchoredPoint(params, what: action, space: space)
		warpMouse(to: point)
		if action != "move" {
			sleepMS(80)
			try assertAlive(cancelFile)
			try assertFocus(params, notes: &notes)
		}
		switch action {
		case "click":
			postMouse(button.downType, at: point, button: button, clickState: 1)
			sleepMS(45)
			postMouse(button.upType, at: point, button: button, clickState: 1)
		case "rightClick":
			postMouse(.rightMouseDown, at: point, button: .right, clickState: 1)
			sleepMS(45)
			postMouse(.rightMouseUp, at: point, button: .right, clickState: 1)
		case "middleClick":
			postMouse(.otherMouseDown, at: point, button: .middle, clickState: 1)
			sleepMS(45)
			postMouse(.otherMouseUp, at: point, button: .middle, clickState: 1)
		case "doubleClick":
			// Two click pairs with the click-state field set. On macOS the interval
			// alone does not make a double click: the field is what says so, which is
			// why the Windows sequence is not enough here.
			postMouse(button.downType, at: point, button: button, clickState: 1)
			sleepMS(40)
			postMouse(button.upType, at: point, button: button, clickState: 1)
			sleepMS(70)
			try assertAlive(cancelFile)
			postMouse(button.downType, at: point, button: button, clickState: 2)
			sleepMS(40)
			postMouse(button.upType, at: point, button: button, clickState: 2)
		default:
			waitForCursor(point)
		}

	case "drag":
		guard let x = params.int("x"), let y = params.int("y"),
		      let toX = params.int("toX"), let toY = params.int("toY") else {
			throw PilotError("drag requires x, y, toX and toY")
		}
		let from = try targetPoint(x: x, y: y, what: "drag", space: space)
		let to = try targetPoint(x: toX, y: toY, what: "drag", space: space)
		try assertFocus(params, notes: &notes)
		warpMouse(to: from)
		sleepMS(90)
		try assertAlive(cancelFile)
		postMouse(button.downType, at: from, button: button, clickState: 1)
		do {
			let steps = 24
			for step in 1...steps {
				let t = CGFloat(step) / CGFloat(steps)
				let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
				// A drag is its own event type here; plain moves with a button held down
				// are ignored by most applications.
				postMouse(button.dragType, at: point, button: button, clickState: 1)
				sleepMS(18)
				if step % 4 == 0 { try assertAlive(cancelFile) }
			}
		} catch {
			postMouse(button.upType, at: to, button: button, clickState: 1)
			throw error
		}
		postMouse(button.upType, at: to, button: button, clickState: 1)
		sleepMS(90)

	case "scroll":
		var amount = 3
		if params.value("amount") != nil {
			guard let parsed = params.int("amount") else {
				throw PilotError("amount must be an integer (got '\(params.string("amount") ?? "")')")
			}
			amount = parsed
		}
		guard amount != 0 else { throw PilotError("amount must not be zero") }
		if let x = params.int("x"), let y = params.int("y") {
			let point = try targetPoint(x: x, y: y, what: "scroll", space: space)
			warpMouse(to: point)
			sleepMS(60)
		}
		try assertAlive(cancelFile)
		try assertFocus(params, notes: &notes)
		// toX/toY select the axis and nothing else, exactly as on the other platform.
		let horizontal = params.value("toX") != nil || params.value("toY") != nil
		postScroll(amount: amount, horizontal: horizontal)

	case "type":
		guard let text = params.string("text"), !text.isEmpty else {
			throw PilotError("type requires non-empty text")
		}
		try assertFocus(params, notes: &notes)
		let saved = try pasteText(text, cancelFile: cancelFile)
		restorePasteboard(saved)
		notes.append("The text was delivered as one paste, so the target saw no individual keystrokes.")

	case "key":
		guard let spec = params.string("key")?.trimmingCharacters(in: .whitespaces), !spec.isEmpty else {
			throw PilotError("key requires a value such as enter, tab, esc, ctrl+s, alt+tab")
		}
		let stroke = try parseKey(spec)
		try assertFocus(params, notes: &notes)
		do {
			try sendKey(stroke)
		} catch {
			throw PilotError("the keystroke '\(spec)' could not be delivered")
		}

	case "focus":
		try focusAction(params, notes: &notes)

	case "windows":
		return try windowsReport(params: params, space: space)

	case "controls":
		return try controlsReport(params: params, space: space)

	default:
		throw PilotError("unknown action '\(action)' (use click, doubleClick, rightClick, middleClick, move, drag, scroll, type, key, focus, windows, or controls)")
	}

	let settleMs = params.int("settleMs") ?? 750
	try settle(settleMs, cancelFile: cancelFile)
	return actionReport(action: action, notes: notes, space: space)
}

/// `focus` with no title falls back to the hwnd branch; both then verify against
/// what the desktop actually did before reporting success.
func focusAction(_ params: Params, notes: inout [String]) throws {
	if let hwnd = parseWindowId(params.string("hwnd")) {
		guard let entry = windowList(all: true).first(where: { $0.id == hwnd }) else {
			throw PilotError("the target window (hwnd \(params.string("hwnd") ?? "")) no longer exists")
		}
		_ = activateWindow(entry)
		sleepMS(220)
		if frontmostPid() != entry.pid, params.bool("tolerant") != true {
			let holder = foregroundTitle()
			throw PilotError("could not bring hwnd \(String(format: "0x%X", hwnd)) to the foreground; '\(holder)' still holds it, so the rest of this batch would land there. Pass tolerant: true on this step if the coordinates are right either way.")
		}
		return
	}
	guard let title = params.string("title")?.trimmingCharacters(in: .whitespaces), !title.isEmpty else {
		throw PilotError("focus requires a title, or an hwnd")
	}
	_ = title
	try assertFocus(params, notes: &notes)
}

/// Is the window collapsed to the Dock? Accessibility answers that; the window
/// server only says whether it is on screen, which is also true of a hidden app.
func minimized(_ entry: WindowEntry) -> Bool {
	if let window = axWindow(for: entry), let flag = axBool(window, kAXMinimizedAttribute as String) { return flag }
	return !entry.onscreen
}

func cursorObject(_ space: ScreenSpace) -> [String: Any] {
	let pixel = space.pixels(mouseLocation())
	return ["x": Int(pixel.x.rounded()), "y": Int(pixel.y.rounded())]
}

/// The window inventory: front to back, titles non-empty, hidden windows included
/// with `visible: false` — the same shape and the same filter as the Windows action.
func windowsReport(params: Params, space: ScreenSpace) throws -> [String: Any] {
	let query = stripZeroWidth(params.string("title") ?? "").lowercased()
	var rows: [[String: Any]] = []
	var notes: [String] = []
	let entries = windowList(all: true)
	if entries.contains(where: { $0.title.isEmpty }) && !CGPreflightScreenCaptureAccess() {
		notes.append("window titles need Screen Recording permission; grant it to see them (System Settings > Privacy & Security > Screen & System Audio Recording).")
	}
	for entry in entries {
		if entry.title.isEmpty { continue }
		if !query.isEmpty {
			let title = stripZeroWidth(entry.title).lowercased()
			let process = stripZeroWidth(entry.process).lowercased()
			if !title.contains(query), !process.contains(query) { continue }
		}
		var row: [String: Any] = [
			"handle": String(format: "0x%X", entry.id),
			"title": entry.title,
			"pid": Int(entry.pid),
			"bounds": boundsString(entry.pointBounds, scale: space.scale),
			"minimized": minimized(entry),
			"visible": entry.onscreen,
			"foreground": entry.id == focusedId
		]
		if !entry.process.isEmpty { row["process"] = entry.process }
		rows.append(row)
	}
	var result: [String: Any] = [
		"ok": true,
		"action": "windows",
		"windows": rows,
		"windowCount": rows.count,
		"cursor": cursorObject(space),
		"notes": notes,
		"actedAt": timestamp(),
		"foregroundTitle": foregroundTitle()
	]
	if let focusedRow = rows.first(where: { ($0["foreground"] as? Bool) == true }) {
		result["foregroundWindow"] = focusedRow
	}
	return result
}

/// The control listing, in the format the Windows sensor prints.
func controlsReport(params: Params, space: ScreenSpace) throws -> [String: Any] {
	try requireAccessibility()
	var entry: WindowEntry
	if let hwnd = parseWindowId(params.string("hwnd")) {
		guard let found = windowList(all: true).first(where: { $0.id == hwnd }) else {
			throw PilotError("the target window (hwnd \(params.string("hwnd") ?? "")) no longer exists; re-read the screen and target a live window")
		}
		entry = found
	} else {
		guard let title = params.string("title")?.trimmingCharacters(in: .whitespaces), !title.isEmpty else {
			throw PilotError("controls requires a title, or an hwnd")
		}
		guard let found = findWindow(title) else {
			throw PilotError("no visible top-level window matches '\(title)'; pass an hwnd if the window is hidden")
		}
		entry = found
	}
	guard let axWindowElement = axWindow(for: entry) else {
		throw PilotError("the window exposes no automation element")
	}

	let includeValues = params.bool("includeValues") ?? false
	let meaningfulOnly = params.bool("meaningfulOnly") ?? true
	var walk = controlNodes(window: axWindowElement, includeValues: includeValues, meaningfulOnly: meaningfulOnly)
	if !uiWarmed, walk.total < 8 {
		// Browsers and Electron apps publish a stub tree until something asks twice.
		sleepMS(300)
		walk = controlNodes(window: axWindowElement, includeValues: includeValues, meaningfulOnly: meaningfulOnly)
	}
	if walk.total >= 8 { uiWarmed = true }

	var lines = formatControls(walk.nodes, scale: space.scale, truncated: walk.truncated, total: walk.total)
	if meaningfulOnly, walk.nodes.isEmpty {
		let full = controlNodes(window: axWindowElement, includeValues: false, meaningfulOnly: false)
		if !full.nodes.isEmpty {
			lines = ["(no operable controls here; the window has \(full.nodes.count) elements - pass meaningfulOnly:false to see them)"]
		}
	}

	var items: [Int: (role: String, name: String)] = [:]
	for node in walk.nodes { items[node.index] = (node.role, node.name) }
	lastListing = ControlListing(windowId: entry.id, items: items)

	var report: [String: Any] = [
		"ok": true,
		"action": "controls",
		"cursor": cursorObject(space),
		"foregroundTitle": foregroundTitle(),
		"foregroundClass": foregroundClass(),
		"controls": lines,
		"controlCount": walk.nodes.count,
		"controlTotal": walk.total,
		"filteredOut": walk.dropped,
		"controlsTruncated": walk.truncated,
		"controlsWindow": entry.title,
		"notes": [],
		"actedAt": timestamp()
	]
	if let process = foregroundProcess() { report["foregroundProcess"] = process }
	return report
}

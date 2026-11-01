//
//  PilotInput.swift — synthesised input for the macOS backend.
//
//  Windows posts mouse_event/keybd_event and lets the window manager figure out the
//  rest. macOS needs each event to carry its own position, a drag has to be posted
//  as a drag (not as moves with a button held), and a double click is only a double
//  click when the click-state field says so. This file holds those differences in
//  one place so the action layer above it reads the same on both platforms.
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Pointer

enum MouseButtonName: String {
	case left
	case right
	case middle

	var cgButton: CGMouseButton {
		switch self {
		case .left: return .left
		case .right: return .right
		case .middle: return .center
		}
	}

	var downType: CGEventType {
		switch self {
		case .left: return .leftMouseDown
		case .right: return .rightMouseDown
		case .middle: return .otherMouseDown
		}
	}

	var upType: CGEventType {
		switch self {
		case .left: return .leftMouseUp
		case .right: return .rightMouseUp
		case .middle: return .otherMouseUp
		}
	}

	var dragType: CGEventType {
		switch self {
		case .left: return .leftMouseDragged
		case .right: return .rightMouseDragged
		case .middle: return .otherMouseDragged
		}
	}
}

/// The pointer position, in global display points.
func mouseLocation() -> CGPoint {
	CGEvent(source: nil)?.location ?? .zero
}

/// Move the pointer without generating a click. `CGWarpMouseCursorPosition` moves
/// the cursor itself, which is the equivalent of SetCursorPos.
func warpMouse(to point: CGPoint) {
	CGWarpMouseCursorPosition(point)
	CGAssociateMouseAndMouseCursorPosition(1)
}

/// Post one mouse event at a fixed position.
///
/// macOS reads the position off the event, so the caller passes where it wants the
/// event to happen rather than relying on where the pointer already is — and the
/// click-state field is what distinguishes the second half of a double click from
/// an unrelated second click.
func postMouse(_ type: CGEventType, at point: CGPoint, button: MouseButtonName, clickState: Int64 = 1) {
	let source = CGEventSource(stateID: .hidSystemState)
	guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button.cgButton) else { return }
	event.setIntegerValueField(.mouseEventClickState, value: clickState)
	event.post(tap: .cghidEventTap)
}

/// How many text lines one wheel notch is worth here. Windows counts notches in
/// 120-unit steps; macOS counts lines, so one notch is translated to a small burst
/// that feels like the same amount of travel in a document or a list.
let scrollLinesPerNotch = 6

/// Post a scroll event. Positive scrolls up (towards the top of the document), which
/// is the sign convention the tool's `amount` parameter documents on both platforms.
func postScroll(amount: Int, horizontal: Bool) {
	let source = CGEventSource(stateID: .hidSystemState)
	let lines = Int32(amount * scrollLinesPerNotch)
	let event: CGEvent?
	if horizontal {
		event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: 0, wheel2: lines, wheel3: 0)
	} else {
		event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)
	}
	event?.post(tap: .cghidEventTap)
}

// MARK: - Keys

/// Named keys, mapped onto virtual key codes. The accepted names are the ones the
/// Windows sensor accepts, so a model that learned `key: "pgup"` keeps working; the
/// numbers behind them are different, which is exactly what this table hides.
let namedKeys: [String: (code: CGKeyCode, shift: Bool)] = [
	"enter": (36, false), "return": (36, false),
	"tab": (48, false),
	"esc": (53, false), "escape": (53, false),
	"space": (49, false),
	"backspace": (51, false), "back": (51, false),
	"delete": (117, false), "del": (117, false),
	"home": (115, false),
	"end": (119, false),
	"pageup": (116, false), "pgup": (116, false),
	"pagedown": (121, false), "pgdn": (121, false),
	"up": (126, false),
	"down": (125, false),
	"left": (123, false),
	"right": (124, false),
	"insert": (114, false), "ins": (114, false),
	"f1": (122, false), "f2": (120, false), "f3": (99, false), "f4": (118, false),
	"f5": (96, false), "f6": (97, false), "f7": (98, false), "f8": (100, false),
	"f9": (101, false), "f10": (109, false), "f11": (103, false), "f12": (111, false),
	"f13": (105, false), "f14": (107, false), "f15": (113, false), "f16": (106, false)
]

/// One parsed keystroke.
struct KeyStroke {
	let code: CGKeyCode
	let flags: CGEventFlags
	/// Set for a literal character: delivered as text rather than as a key code, so
	/// the layout never decides which character arrives.
	let text: String?
}

/// Parse `q`, `A`, `enter`, `ctrl+s`, `alt+tab`, `cmd+shift+4`.
///
/// Modifier words cover both platforms' habits: `ctrl` and `cmd` are different keys
/// here, and mapping them onto one another would silently change what a chord does,
/// so each gets its own flag — `win`/`cmd`/`meta` mean ⌘, `ctrl` means ⌃.
func parseKey(_ spec: String) throws -> KeyStroke {
	let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
	if trimmed.isEmpty {
		throw PilotError("key requires a value such as enter, tab, esc, ctrl+s, alt+tab")
	}
	let parts = trimmed.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
	if parts.isEmpty { throw PilotError("key '\(spec)' has no usable key name") }

	var flags: CGEventFlags = []
	var base: String?
	for part in parts {
		switch part.lowercased() {
		case "ctrl", "control": flags.insert(.maskControl)
		case "alt", "option", "opt": flags.insert(.maskAlternate)
		case "shift": flags.insert(.maskShift)
		case "win", "windows", "cmd", "command", "meta", "super": flags.insert(.maskCommand)
		default:
			if let existing = base {
				throw PilotError("key combination '\(spec)' names both '\(existing)' and '\(part)'; only one non-modifier key is supported")
			}
			base = part
		}
	}
	guard let key = base else {
		// Modifiers only (`key: "ctrl"`): a bare modifier press is legitimate, and the
		// Windows build sends exactly that.
		return KeyStroke(code: 0, flags: flags, text: nil)
	}
	if let named = namedKeys[key.lowercased()] {
		return KeyStroke(code: named.code, flags: flags, text: nil)
	}
	if key.count == 1 {
		// An upper-case letter carries Shift so the application sees the case it was
		// asked for; the Windows SendKeys bridge silently lowercased it instead.
		if key.uppercased() == key && key.lowercased() != key { flags.insert(.maskShift) }
		return KeyStroke(code: 0, flags: flags, text: key)
	}
	throw PilotError("key '\(spec)' names an unknown key '\(key)'; use a single character or a name such as enter/tab/esc/backspace/delete/home/end/up/down/left/right/pgup/pgdn/f1..f16")
}

/// Send one parsed keystroke to whatever holds focus.
///
/// A literal character travels as its Unicode text, so `A`, `你` and `,` all arrive
/// as typed rather than as whatever the current layout maps that key code to.
func sendKey(_ stroke: KeyStroke) throws {
	let source = CGEventSource(stateID: .hidSystemState)
	guard let down = CGEvent(keyboardEventSource: source, virtualKey: stroke.code, keyDown: true) else {
		throw PilotError("the keystroke could not be delivered")
	}
	down.flags = stroke.flags
	if let text = stroke.text, !text.isEmpty {
		var units = Array(text.utf16)
		down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
	}
	down.post(tap: .cghidEventTap)
	sleepMS(12)
	let up = CGEvent(keyboardEventSource: source, virtualKey: stroke.code, keyDown: false)
	up?.flags = stroke.flags
	if let text = stroke.text, !text.isEmpty {
		var units = Array(text.utf16)
		up?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
	}
	up?.post(tap: .cghidEventTap)
}

// MARK: - Text

/// A snapshot of everything on the pasteboard, so a paste can put it back.
func snapshotPasteboard() -> [(NSPasteboard.PasteboardType, Data)] {
	let pasteboard = NSPasteboard.general
	guard let items = pasteboard.pasteboardItems else { return [] }
	var snapshot: [(NSPasteboard.PasteboardType, Data)] = []
	for item in items {
		for type in item.types {
			if let data = item.data(forType: type) { snapshot.append((type, data)) }
		}
	}
	return snapshot
}

/// Put a snapshot back, so an agent's paste does not eat the person's clipboard.
func restorePasteboard(_ snapshot: [(NSPasteboard.PasteboardType, Data)]) {
	guard !snapshot.isEmpty else { return }
	let pasteboard = NSPasteboard.general
	pasteboard.clearContents()
	var items: [NSPasteboardItem] = []
	var current = NSPasteboardItem()
	for (type, data) in snapshot {
		if current.types.contains(type) {
			items.append(current)
			current = NSPasteboardItem()
		}
		current.setData(data, forType: type)
	}
	if !current.types.isEmpty { items.append(current) }
	pasteboard.writeObjects(items)
}

/// Deliver text as one paste through ⌘V.
///
/// The Windows sensor pastes too, and for the same reason: a clipboard round trip
/// carries any Unicode, needs no layout, and reaches applications that ignore
/// synthesised per-character input entirely.
func pasteText(_ text: String, cancelFile: String) throws -> [(NSPasteboard.PasteboardType, Data)] {
	let pasteboard = NSPasteboard.general
	let saved = snapshotPasteboard()
	pasteboard.clearContents()
	guard pasteboard.setString(text, forType: .string) else {
		throw PilotError("could not place the text on the clipboard")
	}
	sleepMS(60)
	try assertAlive(cancelFile)
	let source = CGEventSource(stateID: .hidSystemState)
	let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
	commandDown?.flags = .maskCommand
	commandDown?.post(tap: .cghidEventTap)
	sleepMS(12)
	let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
	commandUp?.flags = .maskCommand
	commandUp?.post(tap: .cghidEventTap)
	sleepMS(120)
	return saved
}

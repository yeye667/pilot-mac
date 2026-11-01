//
//  PilotWindows.swift — windows and the Accessibility tree for the macOS backend.
//
//  Windows reaches the same two things through EnumWindows + GetWindowText and UI
//  Automation. macOS splits them differently: window geometry and z-order live in
//  the window server (CGWindowListCopyWindowInfo), while titles, roles and
//  rectangles of individual controls live behind the Accessibility API — which is
//  a permission, not a library, so everything here can fail with "not trusted"
//  and has to say so instead of returning an empty list that looks like an empty
//  window.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Accessibility plumbing

/// Read one attribute, or nil when the element does not have it.
func axAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
	var value: CFTypeRef?
	guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
	return value
}

func axString(_ element: AXUIElement, _ name: String) -> String? {
	guard let value = axAttribute(element, name) else { return nil }
	if let text = value as? String { return text }
	if CFGetTypeID(value) == CFNumberGetTypeID(), let number = value as? NSNumber { return number.stringValue }
	return nil
}

func axBool(_ element: AXUIElement, _ name: String) -> Bool? {
	guard let value = axAttribute(element, name), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
	return (value as? Bool) ?? (value as? NSNumber)?.boolValue
}

func axElements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
	guard let value = axAttribute(element, name) else { return [] }
	if let direct = value as? [AXUIElement] { return direct }
	// Some SDK versions bridge a CFArray of AXUIElements rather than letting it type
	// check directly, so fall back to walking the array by hand.
	guard CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
	let array = unsafeBitCast(value, to: NSArray.self)
	var out: [AXUIElement] = []
	for item in array {
		let object = item as AnyObject
		if CFGetTypeID(object) == AXUIElementGetTypeID() {
			out.append(unsafeBitCast(object, to: AXUIElement.self))
		}
	}
	return out
}

func axElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
	guard let value = axAttribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
	return unsafeBitCast(value, to: AXUIElement.self)
}

func axPoint(_ element: AXUIElement, _ name: String) -> CGPoint? {
	guard let value = axAttribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
	var point = CGPoint.zero
	guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgPoint, &point) else { return nil }
	return point
}

func axSize(_ element: AXUIElement, _ name: String) -> CGSize? {
	guard let value = axAttribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
	var size = CGSize.zero
	guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &size) else { return nil }
	return size
}

/// The rectangle of an element in global display points, if it publishes one.
func axFrame(_ element: AXUIElement) -> CGRect? {
	guard let origin = axPoint(element, kAXPositionAttribute as String),
	      let size = axSize(element, kAXSizeAttribute as String) else { return nil }
	if size.width <= 0 || size.height <= 0 { return nil }
	return CGRect(origin: origin, size: size)
}

func axPid(_ element: AXUIElement) -> pid_t? {
	var pid: pid_t = 0
	guard AXUIElementGetPid(element, &pid) == .success else { return nil }
	return pid
}

// MARK: - Windows from the window server

/// One top-level window as the window server sees it.
struct WindowEntry {
	let id: CGWindowID
	let pid: pid_t
	let title: String
	let process: String
	/// Global display points.
	let pointBounds: CGRect
	let onscreen: Bool
	let layer: Int
	let alpha: Double
}

/// Process name for a pid: the localised app name, else its executable name.
func processName(_ pid: pid_t) -> String? {
	guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
	if let localized = app.localizedName, !localized.isEmpty { return localized }
	if let url = app.executableURL { return url.lastPathComponent }
	return nil
}

/// The frontmost application's pid, as the desktop sees it.
func frontmostPid() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

/// The AX application element for a pid.
func axApplication(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }

/// AX windows of an application, topmost first.
func axWindows(_ pid: pid_t) -> [AXUIElement] {
	let app = axApplication(pid)
	var windows = axElements(app, kAXWindowsAttribute as String)
	if windows.isEmpty, let focused = axElement(app, kAXFocusedWindowAttribute as String) { windows = [focused] }
	return windows
}

/// Find the AX window that corresponds to a window-server window.
///
/// There is no API that maps one id space to the other, so the match is by geometry
/// first (exact frame) and title second — a window that moved between the two reads
/// still matches on title, and a window with an empty title still matches on frame.
func axWindow(for entry: WindowEntry) -> AXUIElement? {
	let windows = axWindows(entry.pid)
	var byFrame: AXUIElement?
	var byTitle: AXUIElement?
	for window in windows {
		if let frame = axFrame(window) {
			if abs(frame.minX - entry.pointBounds.minX) <= 2, abs(frame.minY - entry.pointBounds.minY) <= 2,
			   abs(frame.width - entry.pointBounds.width) <= 2, abs(frame.height - entry.pointBounds.height) <= 2 {
				byFrame = window
				break
			}
		}
		if byTitle == nil, let title = axString(window, kAXTitleAttribute as String), !title.isEmpty, title == entry.title {
			byTitle = window
		}
	}
	return byFrame ?? byTitle ?? windows.first
}

/// Enumerate top-level windows, front to back.
///
/// `all` mirrors EnumWindows (hidden and tray windows included, `visible: false`);
/// the default is what a person can see, which is what focus and target matching use.
func windowList(all: Bool) -> [WindowEntry] {
	let options: CGWindowListOption = all ? [.optionAll, .excludeDesktopElements] : [.optionOnScreenOnly, .excludeDesktopElements]
	guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
	let front = frontmostPid()
	var entries: [WindowEntry] = []
	for row in raw {
		let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
		if layer != 0 { continue }
		guard let number = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
		let pid = pid_t((row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0)
		if pid <= 0 { continue }
		let alpha = (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
		var bounds = CGRect.zero
		if let dictionary = row[kCGWindowBounds as String] as? NSDictionary,
		   let parsed = CGRect(dictionaryRepresentation: dictionary as CFDictionary) { bounds = parsed }
		let serverTitle = (row[kCGWindowName as String] as? String) ?? ""
		entries.append(WindowEntry(
			id: number,
			pid: pid,
			title: serverTitle,
			process: processName(pid) ?? "",
			pointBounds: bounds,
			onscreen: (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
			layer: layer,
			alpha: alpha
		))
	}
	// The window server lists front to back, so the first on-screen window of the
	// frontmost application is the one a person would call focused.
	focusedId = entries.first(where: { $0.pid == front && $0.onscreen })?.id
	// Titles live behind Screen Recording permission: without it every entry has an
	// empty title, which reads to a model as "no windows". Accessibility can supply
	// them instead, so fill gaps before the caller filters on them.
	if entries.contains(where: { $0.title.isEmpty }) {
		var fixed: [WindowEntry] = []
		for entry in entries {
			if entry.title.isEmpty, let window = axWindow(for: entry), let title = axString(window, kAXTitleAttribute as String) {
				fixed.append(WindowEntry(id: entry.id, pid: entry.pid, title: title, process: entry.process,
				                         pointBounds: entry.pointBounds, onscreen: entry.onscreen, layer: entry.layer, alpha: entry.alpha))
			} else {
				fixed.append(entry)
			}
		}
		entries = fixed
	}
	// Mark exactly one window as the focused one, the way GetForegroundWindow names
	// one. This runs after the title repair so a repaired entry is still marked.
	if let frontPid = front, let index = entries.firstIndex(where: { $0.pid == frontPid && $0.onscreen }) {
		focusedId = entries[index].id
	} else {
		focusedId = nil
	}
	return entries
}

/// The window the frontmost application owns, as picked by the last `windowList` call.
/// This is the closest thing macOS has to GetForegroundWindow() == hwnd.
var focusedId: CGWindowID?

/// Titles in this UI carry zero-width characters (browsers append them), so both
/// sides of a substring match are stripped first: a person's "chrome" must match
/// "Chrome". Mirrors Remove-ZeroWidth on the Windows side.
func stripZeroWidth(_ text: String) -> String {
	let hidden: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"]
	var out = String.UnicodeScalarView()
	for scalar in text.unicodeScalars where !hidden.contains(scalar) { out.append(scalar) }
	return String(out)
}

/// Find a window by case-insensitive substring of its title or its process name.
///
/// Rule parity with the Windows sensor: the focused window wins when it matches,
/// otherwise the first match in z-order (front to back), never a hidden one.
func findWindow(_ needle: String, all: Bool = false) -> WindowEntry? {
	let query = stripZeroWidth(needle).lowercased()
	let entries = windowList(all: all).filter { $0.onscreen && !$0.title.isEmpty }
	var fallback: WindowEntry?
	for entry in entries {
		let title = stripZeroWidth(entry.title).lowercased()
		let process = stripZeroWidth(entry.process).lowercased()
		let hit = title.contains(query) || (!process.isEmpty && process.contains(query))
		if !hit { continue }
		if entry.id == focusedId { return entry }
		if fallback == nil { fallback = entry }
	}
	return fallback
}

/// Bring a window forward, restoring it first when it is minimised.
/// macOS activation is cooperative: this returns whether the desktop agreed,
/// and the caller decides whether that is fatal (see the `tolerant` flag).
@discardableResult
func activateWindow(_ entry: WindowEntry) -> Bool {
	if let app = NSRunningApplication(processIdentifier: entry.pid) {
		app.activate(options: [.activateAllWindows])
	}
	guard let window = axWindow(for: entry) else { return frontmostPid() == entry.pid }
	if axBool(window, kAXMinimizedAttribute as String) == true {
		AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
	}
	AXUIElementPerformAction(window, kAXRaiseAction as CFString)
	let app = axApplication(entry.pid)
	AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
	AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
	return frontmostPid() == entry.pid
}

/// Window title, for the result envelope: the focused window of the frontmost app,
/// else the topmost window the window server reports.
func foregroundTitle() -> String {
	if let pid = frontmostPid() {
		if let focused = axElement(axApplication(pid), kAXFocusedWindowAttribute as String),
		   let title = axString(focused, kAXTitleAttribute as String), !title.isEmpty { return title }
		for entry in windowList(all: false) where entry.pid == pid && !entry.title.isEmpty { return entry.title }
	}
	return ""
}

/// Window "class" for the result envelope. macOS has no window classes; the owning
/// application's bundle identifier is the closest stable label, and the plugin's
/// window entries deliberately do not carry this field at all.
func foregroundClass() -> String {
	guard let pid = frontmostPid(), let app = NSRunningApplication(processIdentifier: pid) else { return "" }
	return app.bundleIdentifier ?? ""
}

func foregroundProcess() -> String? {
	guard let pid = frontmostPid() else { return nil }
	return processName(pid)
}

// MARK: - Controls from the Accessibility tree

/// One control line's worth of data.
struct ControlNode {
	let index: Int
	/// Windows ControlType name, so a model that learned the Windows listing reads
	/// the macOS one the same way.
	let role: String
	let name: String
	let rect: CGRect?
	let enabled: Bool
	let offscreen: Bool
	let value: String?
}

/// Roles a person can operate. Same set the Windows sensor filters on, expressed in
/// the names this backend reports (AX roles mapped onto ControlType names).
let interactiveRoles: Set<String> = [
	"Button", "Edit", "ComboBox", "ListItem", "MenuItem", "Tab", "TabItem", "CheckBox",
	"RadioButton", "Hyperlink", "SplitButton", "Slider", "Spinner", "TreeItem", "DataItem"
]

/// Roles that appear once per row; an unnamed one carries no information.
let bulkRoles: Set<String> = ["DataItem", "TreeItem", "ListItem", "MenuItem"]

/// AX role to ControlType name. Anything unmapped loses its `AX` prefix, which is
/// already the right word for most of them (`AXGroup` → `Group`).
func roleName(_ role: String) -> String {
	switch role {
	case "AXButton": return "Button"
	case "AXTextField", "AXTextArea", "AXSecureTextField", "AXSearchField": return "Edit"
	case "AXComboBox": return "ComboBox"
	case "AXRow", "AXCell": return "DataItem"
	case "AXOutlineRow": return "TreeItem"
	case "AXMenuItem", "AXMenuBarItem": return "MenuItem"
	case "AXTabGroup": return "Tab"
	case "AXRadioButton": return "RadioButton"
	case "AXCheckBox": return "CheckBox"
	case "AXLink": return "Hyperlink"
	case "AXSlider": return "Slider"
	case "AXIncrementor": return "Spinner"
	case "AXStaticText": return "Text"
	case "AXScrollArea", "AXSheet": return "Pane"
	case "AXWindow": return "Window"
	case "AXMenu": return "Menu"
	case "AXMenuBar": return "MenuBar"
	case "AXImage": return "Image"
	case "AXList", "AXTable", "AXOutline": return "List"
	case "AXSplitter": return "Separator"
	case "AXToolbar": return "ToolBar"
	case "AXPopUpButton": return "ComboBox"
	case "AXDisclosureTriangle": return "Button"
	default: return role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
	}
}

/// The name of a control: title, then description, then value, then help text.
/// AX spreads a single human label across four attributes depending on the widget.
func controlName(_ element: AXUIElement) -> String {
	for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute] {
		if let text = axString(element, attribute as String), !text.isEmpty {
			return text.replacingOccurrences(of: "\n", with: " ")
		}
	}
	return ""
}

/// Hard cap on how many elements one listing will visit. Parity with the Windows
/// sensor's node cap; a browser window with a full DOM is far past it either way.
let maxControlNodes = 2000

/// Walk an application window's accessibility tree.
///
/// Depth-first and flattened, because that is the shape the Windows listing has:
/// indices are positions in the unfiltered walk, so they carry gaps where layout
/// nodes were dropped, and an index can be used again to hit the same control.
func controlNodes(window: AXUIElement, includeValues: Bool, meaningfulOnly: Bool) -> (nodes: [ControlNode], total: Int, dropped: Int, truncated: Bool) {
	let windowRect = axFrame(window)
	var nodes: [ControlNode] = []
	var visited = 0
	var dropped = 0
	var truncated = false

	func visit(_ element: AXUIElement, depth: Int) {
		if visited >= maxControlNodes { truncated = true; return }
		for child in axElements(element, kAXChildrenAttribute as String) {
			if visited >= maxControlNodes { truncated = true; return }
			// The index is the position in this unfiltered walk, and the node is
			// appended BEFORE its own subtree so that `nodes[index]` really is the node
			// carrying that index — target clicks depend on it.
			let index = visited
			visited += 1

			let role = roleName(axString(child, kAXRoleAttribute as String) ?? "")
			var name = controlName(child)
			let rect = axFrame(child)
			let enabled = axBool(child, kAXEnabledAttribute as String) ?? true
			var offscreen = false
			if let elementRect = rect, let bounds = windowRect {
				offscreen = !elementRect.intersects(bounds)
			} else if rect == nil {
				offscreen = true
			}
			var value: String?
			if includeValues {
				if (axString(child, kAXRoleAttribute as String) ?? "") == "AXSecureTextField" {
					value = "<password field>"
				} else if let text = axString(child, kAXValueAttribute as String), !text.isEmpty {
					value = text
				}
			}

			var keep = true
			if meaningfulOnly {
				let namedPane = role == "Pane" && !name.isEmpty
				let bulkUnnamed = bulkRoles.contains(role) && name.isEmpty
				if !(interactiveRoles.contains(role) || namedPane) || bulkUnnamed {
					keep = false
					dropped += 1
				}
			}
			if keep {
				if name.count > 200 { name = String(name.prefix(200)) + "..." }
				nodes.append(ControlNode(index: index, role: role, name: name, rect: rect, enabled: enabled, offscreen: offscreen, value: value))
			}

			if depth < 40 { visit(child, depth: depth + 1) }
		}
	}

	visit(window, depth: 0)
	return (nodes, visited, dropped, truncated)
}

/// One control line, in the format the Windows sensor prints:
///   `<index> [<Role>] '<name>' @ <left>,<top> <w>x<h>  <flags>`
/// Rectangles are physical pixels on the capture grid, twice-spaced flags.
func formatControls(_ nodes: [ControlNode], scale: CGFloat, truncated: Bool, total: Int) -> [String] {
	var lines: [String] = []
	for node in nodes {
		let rect: String
		if let frame = node.rect {
			let left = Int((frame.minX * scale).rounded())
			let top = Int((frame.minY * scale).rounded())
			let width = Int((frame.width * scale).rounded())
			let height = Int((frame.height * scale).rounded())
			rect = "\(left),\(top) \(width)x\(height)"
		} else {
			rect = "(no rect)"
		}
		var flags: [String] = []
		if !node.enabled { flags.append("disabled") }
		if node.offscreen { flags.append("offscreen") }
		if let value = node.value {
			flags.append("value=" + value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression))
		}
		let tail = flags.isEmpty ? "" : "  " + flags.joined(separator: " ")
		lines.append("\(node.index) [\(node.role)] '\(node.name)' @ \(rect)\(tail)")
	}
	if truncated {
		// The Windows build prints `(0 elements in total)` here because it forgot to
		// pass the count. Reporting the real one is the whole point of the line.
		lines.append("... truncated at the node cap (\(total) elements in total)")
	}
	return lines
}

/// The index list a later `target` click is checked against: role and name per
/// index, so a tree that changed underneath the caller fails instead of hitting
/// whatever moved into that slot.
struct ControlListing {
	let windowId: CGWindowID
	let items: [Int: (role: String, name: String)]
}

var lastListing: ControlListing?

/// Resolve a control index to its centre, in absolute capture pixels.
func targetCentre(index: Int, window: WindowEntry, scale: CGFloat) throws -> CGPoint {
	guard let axWindowElement = axWindow(for: window) else {
		throw PilotError("the window exposes no automation element")
	}
	let walk = controlNodes(window: axWindowElement, includeValues: false, meaningfulOnly: false)
	guard index >= 0, index < walk.nodes.count else {
		throw PilotError("the tree changed: index \(index) is past the end of the listing for '\(window.title)'. Read controls again.")
	}
	// Re-walk for the element behind the index: the flattened list above carries the
	// role and rect, which is all the click needs, plus the identity check below.
	if let listing = lastListing, listing.windowId == window.id, let wanted = listing.items[index] {
		let found = walk.nodes[index]
		if found.role != wanted.role || found.name != wanted.name {
			throw PilotError("the control at index \(index) is not the one that was listed: expected [\(wanted.role)] '\(wanted.name)', found [\(found.role)] '\(found.name)'. Read controls again.")
		}
	}
	guard let rect = walk.nodes[index].rect, rect.width > 0, rect.height > 0 else {
		throw PilotError("the control at index \(index) has no on-screen rectangle - it may be scrolled out of view or collapsed")
	}
	let centre = CGPoint(x: rect.minX + rect.width / 2, y: rect.minY + rect.height / 2)
	return CGPoint(x: (centre.x * scale).rounded(), y: (centre.y * scale).rounded())
}

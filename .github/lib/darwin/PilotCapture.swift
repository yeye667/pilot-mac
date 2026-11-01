//
//  PilotCapture.swift — the sensor: screens, windows and regions, as one PNG plus
//  the numbers needed to act on it.
//
//  The result envelope is the Windows one on purpose (path, kind, imageWidth,
//  imageHeight, originX, originY, scale, dpiAware, dipBounds, screens, cursor,
//  foregroundWindow, rulers, capturedAt), because index.js feeds it straight into
//  the model-facing `<screen_capture>` block and into the pixel contract. Only the
//  values differ: on a Retina display `scale` is 2, and every origin is on that
//  same doubled grid.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Round a rect's numbers for the wire format the plugin expects (`x,y,w,h`).
func boundsString(_ rect: CGRect, scale: CGFloat) -> String {
	let x = Int((rect.minX * scale).rounded())
	let y = Int((rect.minY * scale).rounded())
	let w = Int((rect.width * scale).rounded())
	let h = Int((rect.height * scale).rounded())
	return "\(x),\(y),\(w),\(h)"
}

/// ISO-8601 with fractional seconds and an offset, matching what
/// `[DateTimeOffset]::Now.ToString('o')` produced on the Windows side.
func timestamp() -> String {
	let formatter = ISO8601DateFormatter()
	formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
	return formatter.string(from: Date())
}

/// The window description the capture envelope carries. Exactly six fields: the
/// per-window `visible`/`minimized`/`foreground` flags belong to the `windows`
/// action, and index.js projects this object field by field.
func captureWindowInfo(_ entry: WindowEntry, scale: CGFloat) -> [String: Any] {
	var info: [String: Any] = [
		"handle": String(format: "0x%X", entry.id),
		"title": entry.title,
		"class": entry.process,
		"pid": Int(entry.pid),
		"bounds": boundsString(entry.pointBounds, scale: scale)
	]
	if !entry.process.isEmpty { info["process"] = entry.process }
	return info
}

/// Parse `x,y,width,height` — commas or whitespace, exactly four integers, positive
/// size. Windows accepted the same three shapes and rejected everything else with
/// the same two messages.
func parseRegion(_ spec: String) throws -> CGRect {
	let parts = spec.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { String($0) }.filter { !$0.isEmpty }
	guard parts.count == 4 else { throw PilotError("region must be 'x,y,width,height' (got '\(spec)')") }
	var values: [Int] = []
	for part in parts {
		guard let value = Int(part) else { throw PilotError("region must contain four integers (got '\(spec)')") }
		values.append(value)
	}
	guard values[2] > 0, values[3] > 0 else { throw PilotError("region width and height must be positive") }
	return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
}

/// Where one capture comes from and how big its canvas is, all in absolute pixels.
struct CapturePlan {
	/// Absolute pixel rect the frame covers.
	let canvas: CGRect
	/// Displays to draw, with their absolute pixel rects.
	let displays: [(DisplayInfo, CGRect)]
	/// A single window to draw instead of displays.
	let window: WindowEntry?
	let kind: String
}

/// Nothing is drawn from thin air: every plan resolves to either displays plus a
/// canvas, or one window plus a canvas.
func resolvePlan(_ params: Params, _ space: ScreenSpace) throws -> CapturePlan {
	let union = space.pixelBounds
	if union.width <= 0 || union.height <= 0 {
		throw PilotError("the desktop is not available to this session (no interactive display)")
	}

	// Priority parity with the Windows sensor: window beats region beats screen, and
	// the losers are not even validated.
	if let query = params.string("window"), !query.trimmingCharacters(in: .whitespaces).isEmpty {
		let needle = query.trimmingCharacters(in: .whitespaces)
		guard let entry = findWindow(needle, all: true) else {
			throw PilotError("no visible top-level window matches '\(query)'")
		}
		let canvas = CGRect(x: (entry.pointBounds.minX * space.scale).rounded(),
		                    y: (entry.pointBounds.minY * space.scale).rounded(),
		                    width: max(1, (entry.pointBounds.width * space.scale).rounded()),
		                    height: max(1, (entry.pointBounds.height * space.scale).rounded()))
		return CapturePlan(canvas: canvas, displays: [], window: entry, kind: "window")
	}

	if let spec = params.string("region"), !spec.trimmingCharacters(in: .whitespaces).isEmpty {
		let region = try parseRegion(spec.trimmingCharacters(in: .whitespaces))
		let involved = space.displays.filter { space.pixelRect($0).intersects(region) }
		return CapturePlan(canvas: region, displays: involved.map { ($0, space.pixelRect($0)) }, window: nil, kind: "region")
	}

	let mode = (params.string("screen") ?? "primary").trimmingCharacters(in: .whitespaces)
	switch mode.lowercased() {
	case "all":
		return CapturePlan(canvas: union, displays: space.displays.map { ($0, space.pixelRect($0)) }, window: nil, kind: "all")
	case "primary":
		guard let primary = space.primaryDisplay else {
			throw PilotError("the desktop is not available to this session (no interactive display)")
		}
		return CapturePlan(canvas: space.pixelRect(primary), displays: [(primary, space.pixelRect(primary))], window: nil, kind: "primary")
	default:
		guard let index = Int(mode) else {
			throw PilotError("screen must be 'primary', 'all', or a monitor index (got '\(mode)')")
		}
		guard index >= 0, index < space.displays.count else {
			throw PilotError("monitor index \(index) is out of range (0..\(space.displays.count - 1))")
		}
		let display = space.displays[index]
		return CapturePlan(canvas: space.pixelRect(display), displays: [(display, space.pixelRect(display))], window: nil, kind: "screen:\(index)")
	}
}

/// Run one capture and write the PNG.
func runProbe(_ params: Params) throws -> [String: Any] {
	guard let out = params.string("out")?.trimmingCharacters(in: .whitespaces), !out.isEmpty else {
		throw PilotError("params.out (the PNG destination) is required")
	}
	let rulers = params.bool("rulers") ?? true
	let includeCursor = params.bool("includeCursor") ?? false

	// Screen Recording is checked before anything else: without it a capture returns
	// nil (or a wallpaper-only frame), which would otherwise surface as a confusing
	// "the frame could not be encoded".
	try requireScreenRecording()

	let space = ScreenSpace()
	let plan = try resolvePlan(params, space)
	let width = Int(plan.canvas.width.rounded())
	let height = Int(plan.canvas.height.rounded())

	let cursorPoint = mouseLocation()
	let cursorPixel = space.pixels(cursorPoint)

	// Everything is drawn in one pass so the cursor mark and the rulers land on the
	// same frame the pixels came from; the context stays y-up, so each helper flips.
	guard let image = composeImage(width: width, height: height, draw: { context in
		if let window = plan.window {
			if let shot = captureWindow(window.id) {
				context.draw(shot, in: CGRect(x: 0, y: 0, width: width, height: height))
			}
		} else {
			for pair in plan.displays {
				let pixelRect = pair.1
				guard let shot = captureDisplay(pair.0.id) else { continue }
				let target = CGRect(x: pixelRect.minX - plan.canvas.minX,
				                    y: pixelRect.minY - plan.canvas.minY,
				                    width: pixelRect.width,
				                    height: pixelRect.height)
				// CoreGraphics is y-up: the context's top edge is `height`.
				let flipped = CGRect(x: target.minX, y: CGFloat(height) - target.maxY, width: target.width, height: target.height)
				context.draw(shot, in: flipped)
			}
		}
		if includeCursor {
			drawCursorMark(context, localX: cursorPixel.x - plan.canvas.minX, localY: cursorPixel.y - plan.canvas.minY, width: width, height: height)
		}
		if rulers {
			drawRulers(context, width: width, height: height, originX: plan.canvas.minX, originY: plan.canvas.minY, scale: space.scale)
		}
	}) else {
		throw PilotError("screen capture failed: the frame could not be composed (\(width)x\(height))")
	}

	let absolute = URL(fileURLWithPath: out).standardizedFileURL.path
	try writePNG(image, to: absolute)

	let cursorDisplay = space.display(at: cursorPoint)
	var cursor: [String: Any] = [
		"x": Int(cursorPixel.x.rounded()),
		"y": Int(cursorPixel.y.rounded())
	]
	if let screenOfCursor = cursorDisplay { cursor["screen"] = screenOfCursor.name }

	var result: [String: Any] = [
		"ok": true,
		"path": absolute,
		"kind": plan.kind,
		"imageWidth": width,
		"imageHeight": height,
		"originX": Int(plan.canvas.minX.rounded()),
		"originY": Int(plan.canvas.minY.rounded()),
		"scale": Double(space.scale),
		// Windows reports true unconditionally, meaning "the geometry below is one
		// physical pixel space". On macOS the same guarantee is carried by `scale`, and
		// the flag keeps the field present for the envelope.
		"dpiAware": true,
		"dipBounds": boundsString(CGRect(x: plan.canvas.minX / space.scale, y: plan.canvas.minY / space.scale,
		                                width: plan.canvas.width / space.scale, height: plan.canvas.height / space.scale), scale: 1),
		"screens": space.inventory(),
		"cursor": cursor,
		"rulers": rulers,
		"capturedAt": timestamp()
	]

	if let entry = plan.window {
		result["foregroundWindow"] = captureWindowInfo(entry, scale: space.scale)
	} else if let entry = fgWindowEntry(all: false) {
		result["foregroundWindow"] = captureWindowInfo(entry, scale: space.scale)
	}
	return result
}

/// The window a person would call "the front one": the focused window of the
/// frontmost application, else the topmost on-screen window it owns.
func fgWindowEntry(all: Bool) -> WindowEntry? {
	let entries = windowList(all: all)
	if let focused = focusedId, let entry = entries.first(where: { $0.id == focused }) { return entry }
	guard let pid = frontmostPid() else { return nil }
	return entries.first(where: { $0.pid == pid && $0.onscreen && !$0.title.isEmpty }) ?? entries.first(where: { $0.pid == pid })
}

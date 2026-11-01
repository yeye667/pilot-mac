//
//  Pilot.swift — the macOS half of @momasiku/dsh-pilot-mac.
//
//  Windows drives this plugin through PowerShell scripts that P/Invoke Win32 and
//  UI Automation. macOS has no scripting host with that reach, so this file is one
//  program that talks CoreGraphics, ImageIO and the Accessibility API directly.
//  It keeps the same wire contract as the PowerShell helpers, which is what lets
//  lib/index.js — the tool schemas, the warm worker, the takeover ring, the pixel
//  contract — stay single-sourced:
//
//    pilot-mac probe   <params.json>   one capture, one JSON object on stdout
//    pilot-mac action  <params.json>   one action,  one JSON object on stdout
//    pilot-mac worker                  base64 JSON requests on stdin, replies on stdout
//    pilot-mac overlay <state-dir>     the takeover ring, polls its state directory
//    pilot-mac selftest                permissions, displays, geometry — as JSON
//
//  Coordinate contract (the part everything else rests on)
//  -------------------------------------------------------
//  macOS talks points; screenshots are pixels, and a Retina panel has twice as many
//  of them. Mixing the two is how a click lands in the wrong place, so this program
//  picks ONE grid and puts every number on it:
//
//      captureScale S := the largest backing scale factor among active displays
//      absolute pixel  := point × S
//      point           := absolute pixel ÷ S
//
//  With a single Retina display S = 2, so one image pixel really is one physical
//  screen pixel. With mixed densities the lower-density display is drawn up into
//  the same grid: a little sharpness lost, exact arithmetic everywhere. Every
//  capture reports `scale` = S and `originX`/`originY` — the top-left of the
//  captured area on that same grid — so a reading taken off an image becomes an
//  absolute pixel by adding the origin, and that is exactly what desktop_control
//  consumes. Windows reports scale 1.0 because per-monitor DPI awareness already
//  put it on a physical grid; the field means the same thing on both platforms.
//
//  Build: xcrun swiftc -O -parse-as-library -o pilot-mac lib/darwin/*.swift
//  (lib/darwin/backend.js does this on first use and caches the result.)
//

import AppKit
import ApplicationServices
import CoreGraphics
import CoreText
import Foundation
import ImageIO

// MARK: - Errors and JSON plumbing

/// One reportable failure. The message is what the calling model reads, so it says
/// what went wrong and what to do next rather than naming a syscall.
struct PilotError: Error {
	let message: String
	init(_ message: String) { self.message = message }
}

/// Emit exactly one compact JSON object on stdout, the way the PowerShell helpers
/// do. `JSONSerialization` refuses NaN and infinity, which is the behaviour we
/// want: a capture that could not measure something reports nothing rather than
/// handing the model a coordinate it cannot use.
func emit(_ object: [String: Any]) {
	let safe = sanitize(object)
	if let data = try? JSONSerialization.data(withJSONObject: safe, options: []),
	   let text = String(data: data, encoding: .utf8) {
		print(text)
	} else {
		print("{\"ok\":false,\"error\":\"pilot: the result could not be encoded as JSON\"}")
	}
	fflush(stdout)
}

/// Replace non-finite numbers and drop null-valued entries, so one bad measurement
/// cannot make a whole result unencodable.
func sanitize(_ value: Any) -> Any {
	if let dictionary = value as? [String: Any] {
		var out: [String: Any] = [:]
		for (key, entry) in dictionary {
			if entry is NSNull { continue }
			out[key] = sanitize(entry)
		}
		return out
	}
	if let array = value as? [Any] { return array.map { sanitize($0) } }
	if let number = value as? Double { return number.isFinite ? number : 0 }
	if let number = value as? CGFloat { return number.isFinite ? Double(number) : 0 }
	if let number = value as? Float { return number.isFinite ? Double(number) : 0 }
	return value
}

/// The parameters a helper was asked to run with.
struct Params {
	let raw: [String: Any]

	init(path: String) throws {
		guard let data = FileManager.default.contents(atPath: path) else {
			throw PilotError("could not read the params file '\(path)'")
		}
		let parsed = try? JSONSerialization.jsonObject(with: data, options: [])
		guard let dictionary = parsed as? [String: Any] else {
			throw PilotError("invalid params JSON in '\(path)'")
		}
		raw = dictionary
	}

	init(raw: [String: Any]) { self.raw = raw }

	/// Look a key up case-insensitively, the way PowerShell's `-contains` did.
	func value(_ key: String) -> Any? {
		if let direct = raw[key] { return direct }
		let lowered = key.lowercased()
		for (name, entry) in raw where name.lowercased() == lowered { return entry }
		return nil
	}

	func string(_ key: String) -> String? {
		guard let entry = value(key), !(entry is NSNull) else { return nil }
		if let text = entry as? String { return text }
		return String(describing: entry)
	}

	func int(_ key: String) -> Int? {
		guard let entry = value(key), !(entry is NSNull) else { return nil }
		if let number = entry as? Int { return number }
		if let number = entry as? Double { return Int(number.rounded(.towardZero)) }
		if let number = entry as? NSNumber { return number.intValue }
		if let text = entry as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
		return nil
	}

	/// Strict boolean: only a real JSON boolean counts. PowerShell turned the string
	/// "false" into true, which is a trap worth not reimplementing.
	func bool(_ key: String) -> Bool? {
		guard let entry = value(key), !(entry is NSNull) else { return nil }
		if let flag = entry as? Bool { return flag }
		if let number = entry as? NSNumber { return number.boolValue }
		return nil
	}

	var cancelFile: String {
		guard let text = string("cancelFile"), !text.isEmpty else { return "" }
		return text
	}
}

// MARK: - Cancellation

/// The `stop` token the host stamps when a turn is interrupted and the ring stamps
/// when a person presses Esc. Same file, same word, both platforms.
func stopRequested(_ path: String) -> Bool {
	guard !path.isEmpty else { return false }
	guard let data = FileManager.default.contents(atPath: path) else { return false }
	guard let text = String(data: data, encoding: .utf8) else { return false }
	return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "stop"
}

/// Throw when the loop was told to stop. Every action calls this between its
/// phases, which is what makes an interrupted turn stop mid-gesture instead of
/// letting the remaining clicks play out. The wording is the Windows one, because
/// index.js turns `cancelled: true` into the same model-facing sentence either way.
func assertAlive(_ cancelFile: String) throws {
	if stopRequested(cancelFile) {
		throw PilotError("the action loop was cancelled before this step")
	}
}

func sleepMS(_ milliseconds: Int) {
	if milliseconds <= 0 { return }
	usleep(UInt32(max(0, milliseconds)) * 1000)
}

// MARK: - Screen space

/// One display, described in points (what AppKit and CGEvent use) and in the capture
/// grid (what images and the plugin's coordinates use).
struct DisplayInfo {
	let id: CGDirectDisplayID
	/// Global display space: origin at the top-left of the main display, y down.
	let pointRect: CGRect
	/// Backing scale factor: pixels per point on this display.
	let scale: CGFloat
	let name: String
	let primary: Bool
}

/// The single pixel grid every capture, cursor reading and click lands on.
struct ScreenSpace {
	let displays: [DisplayInfo]
	/// Largest backing scale factor in play; the grid's pixels per point.
	let scale: CGFloat

	init() {
		var found: [DisplayInfo] = []
		var list = [CGDirectDisplayID](repeating: 0, count: 32)
		var count: UInt32 = 0
		let capacity = UInt32(list.count)
		if CGGetActiveDisplayList(capacity, &list, &count) == .success {
			for index in 0..<Int(count) {
				let id = list[index]
				// CGDisplayBounds is already in the global display space CGEvent uses:
				// top-left origin on the main display, y increasing downward, in points.
				let bounds = CGDisplayBounds(id)
				if bounds.width <= 0 || bounds.height <= 0 { continue }
				var scale: CGFloat = 1
				var name = "display \(index)"
				if let screen = ScreenSpace.screen(for: id) {
					scale = max(1, screen.backingScaleFactor)
					name = screen.localizedName
				}
				found.append(DisplayInfo(
					id: id,
					pointRect: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height),
					scale: scale,
					name: name.isEmpty ? "display \(index)" : name,
					primary: CGDisplayIsMain(id) != 0
				))
			}
		}
		if found.isEmpty, let screen = NSScreen.main {
			// No active display list (a locked or headless session). Keep a frame of
			// reference so the caller sees a real error instead of a crash.
			let frame = screen.frame
			found.append(DisplayInfo(
				id: CGMainDisplayID(),
				pointRect: CGRect(x: 0, y: 0, width: frame.width, height: frame.height),
				scale: max(1, screen.backingScaleFactor),
				name: screen.localizedName.isEmpty ? "main display" : screen.localizedName,
				primary: true
			))
		}
		displays = found
		scale = max(1, found.map { $0.scale }.max() ?? 1)
	}

	/// The NSScreen behind a CGDirectDisplayID, for its localised name and its
	/// backing scale factor.
	static func screen(for id: CGDirectDisplayID) -> NSScreen? {
		let key = NSDeviceDescriptionKey("NSScreenNumber")
		for screen in NSScreen.screens {
			if let number = screen.deviceDescription[key] as? NSNumber, number.uint32Value == id { return screen }
		}
		return nil
	}

	/// Pixel rect of one display on the capture grid.
	func pixelRect(_ display: DisplayInfo) -> CGRect {
		CGRect(x: display.pointRect.minX * scale,
		       y: display.pointRect.minY * scale,
		       width: display.pointRect.width * scale,
		       height: display.pointRect.height * scale)
	}

	/// Pixel bounds of the whole desktop (the equivalent of Windows' SM_*VIRTUALSCREEN).
	var pixelBounds: CGRect {
		var rect = CGRect.null
		for display in displays { rect = rect.union(pixelRect(display)) }
		return rect.isNull ? CGRect.zero : rect
	}

	/// Absolute pixel coordinate of a point.
	func pixels(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * scale, y: point.y * scale) }

	/// Point behind an absolute pixel coordinate.
	func points(_ pixel: CGPoint) -> CGPoint { CGPoint(x: pixel.x / scale, y: pixel.y / scale) }

	/// The display a point sits on, if any.
	func display(at point: CGPoint) -> DisplayInfo? {
		for display in displays where display.pointRect.contains(point) { return display }
		return nil
	}

	/// The display an absolute pixel belongs to.
	///
	/// On a uniform-density desktop this is exact: one grid, one divisor. Mixed
	/// densities can overlap on the pixel grid, so the point rect decides first and
	/// the nearest surviving candidate settles the rest.
	func display(atPixel pixel: CGPoint) -> DisplayInfo? {
		if let exact = display(at: points(pixel)) { return exact }
		for display in displays where pixelRect(display).contains(pixel) { return display }
		var best: (DisplayInfo, CGFloat)?
		for display in displays {
			let rect = pixelRect(display)
			let distance = hypot(rect.minX - pixel.x, rect.minY - pixel.y)
			if best == nil || distance < best!.1 { best = (display, distance) }
		}
		return best?.0 ?? displays.first
	}

	/// The primary display, or the first one when nothing claims to be primary.
	var primaryDisplay: DisplayInfo? {
		displays.first(where: { $0.primary }) ?? displays.first
	}

	/// The screen inventory the tool result carries.
	func inventory() -> [[String: Any]] {
		displays.map { display in
			let rect = display.pointRect
			let bounds = "\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded())),\(Int(rect.width.rounded())),\(Int(rect.height.rounded()))"
			return ["device": display.name, "primary": display.primary, "bounds": bounds]
		}
	}
}

// MARK: - Permissions

/// Screen Recording is a TCC permission granted to the *responsible* application —
/// the Harness app that spawned this helper, not the helper's own path. Without it
/// every capture quietly returns wallpaper-only or an empty image, which reads to a
/// model as a blank desktop, so the helper refuses up front and says what to do.
func requireScreenRecording() throws {
	if CGPreflightScreenCaptureAccess() { return }
	_ = CGRequestScreenCaptureAccess()
	throw PilotError(
		"pilot: this process may not record the screen. Open System Settings › Privacy & Security › Screen & System Audio Recording, " +
		"switch on the app that runs DeepSeek Harness (and pilot-mac itself if it is listed separately), then restart that app. " +
		"Run `pilot-mac selftest` to see the current permission state."
	)
}

/// Accessibility is needed twice: to read the control tree, and to post clicks and
/// keystrokes into other applications.
func accessibilityTrusted() -> Bool { AXIsProcessTrusted() }

func requireAccessibility() throws {
	if accessibilityTrusted() { return }
	// The documented literal key; it also avoids depending on how this SDK imports the
	// CFString constant.
	let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
	_ = AXIsProcessTrustedWithOptions(prompt)
	throw PilotError(
		"pilot: this process is not trusted for Accessibility. Open System Settings › Privacy & Security › Accessibility, " +
		"switch on the app that runs DeepSeek Harness (and pilot-mac itself if it is listed separately), then restart that app. " +
		"Run `pilot-mac selftest` to see the current state."
	)
}

// MARK: - Image helpers

/// Build an RGB colour without the newer convenience initialisers, so the helper
/// compiles against older SDKs too. The components always match the RGB space.
func pilotColor(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat) -> CGColor {
	CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [red, green, blue, alpha])!
}
/// Draw into a fresh RGB context and hand back the image.
func composeImage(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage? {
	guard width > 0, height > 0 else { return nil }
	guard let context = CGContext(
		data: nil,
		width: width,
		height: height,
		bitsPerComponent: 8,
		bytesPerRow: 0,
		space: CGColorSpaceCreateDeviceRGB(),
		bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
	) else { return nil }
	context.setFillColor(pilotColor(0, 0, 0, 1))
	context.fill(CGRect(x: 0, y: 0, width: width, height: height))
	context.interpolationQuality = .high
	draw(context)
	return context.makeImage()
}

/// Write a CGImage as PNG. BitBlt on Windows never wrote alpha, so the frames there
/// are opaque; `composeImage` fills black first, which keeps both platforms equal.
func writePNG(_ image: CGImage, to path: String) throws {
	let url = URL(fileURLWithPath: path)
	try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
	guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
		throw PilotError("screen capture failed: the frame could not be encoded as PNG (\(path))")
	}
	CGImageDestinationAddImage(destination, image, nil)
	if !CGImageDestinationFinalize(destination) {
		throw PilotError("screen capture failed: the frame could not be written to \(path)")
	}
}

/// One display's pixels at native resolution. Containing windows are included, so
/// the caller mutes the takeover ring before capturing (index.js does exactly that
/// on both platforms).
func captureDisplay(_ id: CGDirectDisplayID) -> CGImage? {
	// CGDisplayCreateImage is deprecated in favour of ScreenCaptureKit, which needs an
	// async stream and a run loop even for one frame. This synchronous call is still
	// accurate, still honours the same TCC permission, and still returns nil rather
	// than a black frame when the permission is missing.
	return CGDisplayCreateImage(id)
}

/// One window's pixels at native resolution, offscreen or occluded included.
///
/// `CGWindowListCreateImage` is *unavailable* — not merely deprecated — in the
/// macOS 26 SDK, which points at ScreenCaptureKit. ScreenCaptureKit is async and
/// wants a stream configured before the first frame, which fits badly inside a
/// one-shot helper that may be serving a single action. `screencapture -l` reaches
/// the same window pixels through the same Screen Recording permission, is
/// synchronous, and writes a PNG this process can decode.
func captureWindow(_ windowID: CGWindowID) -> CGImage? {
	let path = FileManager.default.temporaryDirectory
		.appendingPathComponent("pilot-window-\(UUID().uuidString).png").path
	defer { try? FileManager.default.removeItem(atPath: path) }

	let process = Process()
	process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
	// -x: silent, -o: no window shadow, -l<id>: that window only.
	process.arguments = ["-x", "-o", "-l\(windowID)", path]
	do { try process.run() } catch { return nil }
	process.waitUntilExit()
	guard process.terminationStatus == 0 else { return nil }
	guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
	return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

// MARK: - Rulers and the cursor crosshair

/// Text drawing in a y-up context: CoreText places the baseline, so a caller that
/// thinks in top-down pixels hands over the top edge and gets the right place.
func drawLabel(_ context: CGContext, text: String, x: CGFloat, topY: CGFloat, size: CGFloat, colour: CGColor) {
	let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, size, nil)
	let attributes: [NSAttributedString.Key: Any] = [
		NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font,
		NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): colour
	]
	let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
	var ascent: CGFloat = 0
	var descent: CGFloat = 0
	var leading: CGFloat = 0
	_ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
	context.textMatrix = .identity
	// CGContext.height is an Int; mixing it with the CGFloat line metrics does not
	// type-check, and silently truncating it would be worse than either.
	context.textPosition = CGPoint(x: x, y: CGFloat(context.height) - topY - ascent)
	CTLineDraw(line, context)
}

/// Draw coordinate rulers on a frame.
///
/// Parity notes with the Windows sensor, because the model reads both: the tick step
/// depends on the frame WIDTH only (200 px when the frame is at least 800 wide, else
/// 100), ticks start one step in and stop before the far edge, labels carry ABSOLUTE
/// screen coordinates, and an origin banner reads `origin <x>,<y>  step <n>` with two
/// spaces before `step`. The context is y-up, so every top-down y is flipped here.
func drawRulers(_ context: CGContext, width: Int, height: Int, originX: CGFloat, originY: CGFloat, scale: CGFloat) {
	let step = width >= 800 ? 200 : 100
	let ink = pilotColor(1, 64.0 / 255.0, 64.0 / 255.0, 1)
	let shadow = pilotColor(0, 0, 0, 200.0 / 255.0)
	context.setShouldAntialias(false)
	context.setStrokeColor(pilotColor(1, 64.0 / 255.0, 64.0 / 255.0, 170.0 / 255.0))
	context.setLineWidth(1)

	let flip = { (y: CGFloat) -> CGFloat in CGFloat(height) - y }

	// Top edge: one tick per step, labelled with the absolute x.
	var x = step
	while x < width {
		let px = CGFloat(x)
		context.move(to: CGPoint(x: px + 0.5, y: flip(0)))
		context.addLine(to: CGPoint(x: px + 0.5, y: flip(10)))
		context.strokePath()
		let label = String(Int((originX + px) / scale))
		drawLabel(context, text: label, x: px + 2, topY: 14, size: 13, colour: shadow)
		drawLabel(context, text: label, x: px + 1, topY: 13, size: 13, colour: ink)
		x += step
	}

	// Left edge: one tick per step, labelled with the absolute y.
	var y = step
	while y < height {
		let py = CGFloat(y)
		context.move(to: CGPoint(x: 0, y: flip(py) + 0.5))
		context.addLine(to: CGPoint(x: 10, y: flip(py) + 0.5))
		context.strokePath()
		let label = String(Int((originY + py) / scale))
		drawLabel(context, text: label, x: 14, topY: py + 2, size: 13, colour: shadow)
		drawLabel(context, text: label, x: 13, topY: py + 1, size: 13, colour: ink)
		y += step
	}

	// Origin banner, so a frame says where it came from without the caller guessing.
	let banner = "origin \(Int(originX)),\(Int(originY))  step \(step)"
	drawLabel(context, text: banner, x: 16, topY: 31, size: 13, colour: shadow)
	drawLabel(context, text: banner, x: 15, topY: 30, size: 13, colour: ink)
	context.setShouldAntialias(true)
}

/// Draw the pointer as a plain red crosshair, 14 px per arm, 2 px thick — the same
/// mark the Windows sensor draws, and drawn for the same reason: a capture never
/// contains the real cursor, so the model would otherwise not know where it is.
/// Outside the frame nothing is drawn, not a clipped half-cross.
func drawCursorMark(_ context: CGContext, localX: CGFloat, localY: CGFloat, width: Int, height: Int) {
	guard localX >= 0, localY >= 0, localX < CGFloat(width), localY < CGFloat(height) else { return }
	let arm: CGFloat = 14
	let y = CGFloat(height) - localY
	context.setStrokeColor(pilotColor(1, 0, 0, 1))
	context.setLineWidth(2)
	context.move(to: CGPoint(x: localX - arm, y: y))
	context.addLine(to: CGPoint(x: localX + arm, y: y))
	context.move(to: CGPoint(x: localX, y: y - arm))
	context.addLine(to: CGPoint(x: localX, y: y + arm))
	context.strokePath()
}

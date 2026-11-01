//
//  PilotRuntime.swift — the three ways this program is started.
//
//   * one shot:  `probe <params>`, `action <params>` — one request, one JSON line.
//   * worker:    `worker`  — the warm path. Requests are base64 JSON lines on stdin,
//                answers are JSON lines on stdout, the first line is `{"ready":true}`.
//                Same protocol as desktop-worker.ps1, so index.js needs one client.
//   * overlay:   `overlay <state-dir>` — the takeover ring, driven by the same
//                show/mute/esc token files the PowerShell ring used.
//
//  Plus `selftest`, which reports the two permissions and the display geometry as
//  JSON: the first thing to run on a new Mac, and the cheapest way to tell "nothing
//  is granted" apart from "the plugin is broken".
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Worker

/// Answer a request dictionary in the shape index.js expects.
func answer(_ request: [String: Any]) -> [String: Any] {
	let params = Params(raw: request)
	let id = request["id"] as? String
	if (request["quit"] as? Bool) == true { return ["quit": true] }
	let kind = ((request["kind"] as? String) ?? "action").lowercased()
	var payload: [String: Any]
	do {
		switch kind {
		case "capture":
			payload = try runProbe(params)
		case "action":
			payload = try runAction(params)
		default:
			payload = ["ok": false, "error": "unknown request kind '\(kind)' (use action or capture)"]
		}
	} catch let error as PilotError {
		payload = ["ok": false, "error": error.message]
		if error.message == "the action loop was cancelled before this step" { payload["cancelled"] = true }
	} catch {
		payload = ["ok": false, "error": "\(error)"]
	}
	if let requestId = id, !requestId.isEmpty { payload["id"] = requestId }
	return payload
}

/// The warm process. One request in flight at a time; a failure answers the request
/// and keeps the process alive, which is the whole point of keeping it warm.
func runWorker() -> Never {
	// A blank line is not a request, and stdout carries the protocol, so nothing else
	// may print here.
	emit(["ok": true, "ready": true, "pid": Int(ProcessInfo.processInfo.processIdentifier)])
	while let line = readLine(strippingNewline: true) {
		let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.isEmpty { continue }
		guard let data = Data(base64Encoded: trimmed, options: []),
		      let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
		      let request = parsed as? [String: Any] else {
			emit(["ok": false, "error": "pilot: a request line was not base64 JSON"])
			continue
		}
		let payload = answer(request)
		if payload["quit"] as? Bool == true { exit(0) }
		emit(payload)
	}
	exit(0)
}

// MARK: - Takeover ring

/// The ring a person sees while an agent drives: a border around the desktop, an Esc
/// that stops the batch, and a mute request so the ring never lands in a screenshot.
///
/// The state directory is the whole protocol, exactly as on Windows:
///   show.txt   the cancel token to stamp when Esc is pressed (present = visible)
///   mute.txt   the host wants the ring out of a frame
///   muted.txt  the ring acknowledges, and clears it once mute.txt disappears
///   esc.txt    stamped when a person pressed Esc
func runOverlay(_ stateDir: String) -> Never {
	let directory = URL(fileURLWithPath: stateDir)
	let showFile = directory.appendingPathComponent("show.txt")
	let muteFile = directory.appendingPathComponent("mute.txt")
	let mutedFile = directory.appendingPathComponent("muted.txt")
	let escFile = directory.appendingPathComponent("esc.txt")

	let app = NSApplication.shared
	app.setActivationPolicy(.accessory)

	let screenFrame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
	let window = NSWindow(contentRect: screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)
	window.isOpaque = false
	window.backgroundColor = .clear
	window.hasShadow = false
	window.level = .statusBar
	window.ignoresMouseEvents = true
	window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

	let ring = OverlayRing(frame: CGRect(origin: .zero, size: screenFrame.size))
	window.contentView = ring
	window.orderOut(nil)

	var cancelFile = ""
	let state = OverlayState()

	// Esc is the one input the ring listens to. A global monitor needs Accessibility
	// permission; when it is missing the ring still shows, and the host's own cancel
	// path still stops the batch.
	let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
		guard event.keyCode == 53 else { return }
		if !cancelFile.isEmpty {
			try? "stop".write(toFile: cancelFile, atomically: true, encoding: .utf8)
			try? "esc".write(toFile: escFile.path, atomically: true, encoding: .utf8)
		}
		state.stopRequested = true
	}

	let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
		let manager = FileManager.default
		if !manager.fileExists(atPath: stateDir) {
			if let installed = monitor { NSEvent.removeMonitor(installed) }
			exit(0)
		}
		let wantVisible = manager.fileExists(atPath: showFile.path)
		if wantVisible, let token = try? String(contentsOf: showFile, encoding: .utf8) {
			cancelFile = token.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		if manager.fileExists(atPath: muteFile.path) {
			window.orderOut(nil)
			try? "1".write(to: mutedFile, atomically: true, encoding: .utf8)
		} else {
			if manager.fileExists(atPath: mutedFile.path) { try? manager.removeItem(at: mutedFile) }
			if wantVisible {
				if window.isVisible == false { window.orderFrontRegardless() }
			} else if window.isVisible {
				window.orderOut(nil)
			}
		}
	}
	RunLoop.main.add(timer, forMode: .common)
	app.run()
	exit(0)
}

/// Shared flags between the ring's timer and its key monitor.
final class OverlayState {
	var stopRequested = false
}

/// The ring itself: four thin edges with a soft inner glow, drawn once and cached by
/// AppKit because it never changes.
final class OverlayRing: NSView {
	override var isOpaque: Bool { false }

	override func draw(_ dirtyRect: NSRect) {
		let bounds = self.bounds
		let context = NSGraphicsContext.current?.cgContext
		context?.setStrokeColor(pilotColor(0.1, 0.9, 0.6, 0.85))
		context?.setLineWidth(3)
		context?.stroke(bounds.insetBy(dx: 2, dy: 2))
		context?.setStrokeColor(pilotColor(0, 0, 0, 0.35))
		context?.setLineWidth(1)
		context?.stroke(bounds.insetBy(dx: 5, dy: 5))
	}
}

// MARK: - Selftest

/// Everything an operator needs to tell "not granted" from "broken", as JSON.
func runSelftest() -> [String: Any] {
	let space = ScreenSpace()
	var displays: [[String: Any]] = []
	for display in space.displays {
		let rect = display.pointRect
		let pixel = space.pixelRect(display)
		displays.append([
			"device": display.name,
			"primary": display.primary,
			"points": "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))",
			"pixels": "\(Int(pixel.minX)),\(Int(pixel.minY)),\(Int(pixel.width)),\(Int(pixel.height))",
			"scale": Double(display.scale)
		])
	}
	let cursor = space.pixels(mouseLocation())
	let bounds = space.pixelBounds
	return [
		"ok": true,
		"platform": "macos",
		"osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
		"screenRecording": CGPreflightScreenCaptureAccess(),
		"accessibility": accessibilityTrusted(),
		"captureScale": Double(space.scale),
		"pixelBounds": "\(Int(bounds.minX)),\(Int(bounds.minY)),\(Int(bounds.width)),\(Int(bounds.height))",
		"cursor": ["x": Int(cursor.x.rounded()), "y": Int(cursor.y.rounded())],
		"frontmost": foregroundTitle(),
		"frontmostClass": foregroundClass(),
		"displays": displays,
		"hints": selftestHints()
	]
}

func selftestHints() -> [String] {
	var hints: [String] = []
	if !CGPreflightScreenCaptureAccess() {
		hints.append("Screen Recording is off: grant it to the app that runs DeepSeek Harness, then restart that app.")
	}
	if !accessibilityTrusted() {
		hints.append("Accessibility is off: clicks, keystrokes and the control tree need it. Grant it to the same app, then restart it.")
	}
	if hints.isEmpty { hints.append("Both permissions are granted; screen_view and desktop_control can drive this Mac.") }
	return hints
}

// MARK: - Entry point

/// Errors that end a one-shot run: one JSON line, then a non-zero exit, matching the
/// PowerShell helpers' `{ok:false,...}` + exit 2.
func failOneShot(_ error: Error) -> Never {
	if let pilot = error as? PilotError {
		var payload: [String: Any] = ["ok": false, "error": pilot.message]
		if pilot.message == "the action loop was cancelled before this step" { payload["cancelled"] = true }
		emit(payload)
		exit(2)
	}
	emit(["ok": false, "error": "pilot: \(error)"])
	exit(2)
}

@main
enum PilotMain {
	static func main() {
		let arguments = CommandLine.arguments
		guard arguments.count >= 2 else {
			emit(["ok": false, "error": "usage: pilot-mac probe|action|worker|overlay|selftest [args]"])
			exit(2)
		}
		let verb = arguments[1]
		switch verb {
		case "probe", "action":
			guard arguments.count >= 3 else {
				emit(["ok": false, "error": "pilot: \(verb) needs a params file"])
				exit(2)
			}
			do {
				let params = try Params(path: arguments[2])
				let result: [String: Any]
				if verb == "probe" {
					result = try runProbe(params)
				} else {
					result = try runAction(params)
				}
				emit(result)
				exit(0)
			} catch {
				failOneShot(error)
			}
		case "worker":
			runWorker()
		case "overlay":
			guard arguments.count >= 3 else {
				emit(["ok": false, "error": "pilot: overlay needs a state directory"])
				exit(2)
			}
			runOverlay(arguments[2])
		case "selftest":
			emit(runSelftest())
			exit(0)
		default:
			emit(["ok": false, "error": "pilot: unknown verb '\(verb)' (use probe, action, worker, overlay, or selftest)"])
			exit(2)
		}
	}
}

#!/usr/bin/env node
/**
 * A stand-in for the compiled macOS helper, for testing the JavaScript half of the
 * plugin on any host.
 *
 * It speaks exactly the protocol `lib/darwin/Pilot.swift` speaks — `probe <params>`,
 * `action <params>`, `worker`, `overlay <dir>` — and answers with the same envelope
 * shapes, so `lib/index.js`, its spawn path, its JSON parsing and the warm worker's
 * base64 line protocol can all be exercised without a Mac.
 *
 * Enabled with:
 *   DSH_PILOT_FORCE_PLATFORM=darwin
 *   DSH_PILOT_MAC_BIN=node
 *   DSH_PILOT_MAC_BIN_PREFIX=/abs/path/to/tools/stub-helper.mjs
 *
 * It is not a mock of the desktop: nothing here touches a screen. It exists so a
 * broken protocol is caught in CI instead of on somebody's Mac.
 */

import { writeFileSync } from 'node:fs';
import { readFileSync } from 'node:fs';

const verb = process.argv[2];
const argument = process.argv[3];

/** A 1x1 transparent PNG: the stub never claims to be a real capture. */
const TINY_PNG = Buffer.from(
	'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
	'base64'
);

const SCREENS = [
	{ device: 'Built-in Retina Display', primary: true, bounds: '0,0,1512,982' },
	{ device: 'Studio Display', primary: false, bounds: '1512,0,2560,1440' }
];

function readParams(path) {
	return JSON.parse(readFileSync(path, 'utf8'));
}

function probe(params) {
	if (typeof params.out !== 'string' || params.out.length === 0) {
		return { ok: false, error: 'params.out (the PNG destination) is required' };
	}
	writeFileSync(params.out, TINY_PNG);
	return {
		ok: true,
		path: params.out,
		kind: params.window === undefined ? (params.region === undefined ? 'primary' : 'region') : 'window',
		imageWidth: 3024,
		imageHeight: 1964,
		originX: 0,
		originY: 0,
		scale: 2,
		dpiAware: true,
		dipBounds: '0,0,1512,982',
		screens: SCREENS,
		cursor: { x: 640, y: 480, screen: 'Built-in Retina Display' },
		foregroundWindow: {
			handle: '0x1A2B3C',
			title: 'Stub Window',
			class: 'com.example.stub',
			process: 'StubApp',
			pid: 4242,
			bounds: '100,100,800,600'
		},
		rulers: params.rulers !== false,
		capturedAt: new Date().toISOString()
	};
}

function action(params) {
	const base = {
		ok: true,
		action: params.action,
		cursor: { x: 640, y: 480 },
		foregroundTitle: 'Stub Window',
		foregroundClass: 'com.example.stub',
		foregroundProcess: 'StubApp',
		notes: [],
		actedAt: new Date().toISOString()
	};
	if (params.action === 'windows') {
		return {
			...base,
			windows: [
				{
					handle: '0x1A2B3C',
					title: 'Stub Window',
					process: 'StubApp',
					pid: 4242,
					bounds: '100,100,800,600',
					minimized: false,
					visible: true,
					foreground: true
				}
			],
			windowCount: 1
		};
	}
	if (params.action === 'controls') {
		return {
			...base,
			controls: ["4 [Button] 'Continue' @ 120,220 96x32", "9 [Edit] 'Name' @ 120,120 240x28"],
			controlCount: 2,
			controlTotal: 12,
			filteredOut: 10,
			controlsTruncated: false,
			controlsWindow: 'Stub Window'
		};
	}
	if (params.action === 'type') {
		return { ...base, notes: ['The text was delivered as one paste, so the target saw no individual keystrokes.'] };
	}
	return base;
}

function worker() {
	process.stdout.write(`${JSON.stringify({ ok: true, ready: true, pid: process.pid })}\n`);
	let buffer = '';
	process.stdin.setEncoding('utf8');
	process.stdin.on('data', (chunk) => {
		buffer += chunk;
		let index = buffer.indexOf('\n');
		while (index >= 0) {
			const line = buffer.slice(0, index).trim();
			buffer = buffer.slice(index + 1);
			if (line.length > 0) handle(line);
			index = buffer.indexOf('\n');
		}
	});
	process.stdin.on('end', () => process.exit(0));
}

function handle(line) {
	let request;
	try {
		request = JSON.parse(Buffer.from(line, 'base64').toString('utf8'));
	} catch {
		process.stdout.write(`${JSON.stringify({ ok: false, error: 'pilot: a request line was not base64 JSON' })}\n`);
		return;
	}
	if (request.quit === true) process.exit(0);
	const payload = request.kind === 'capture' ? probe(request) : action(request);
	if (typeof request.id === 'string' && request.id.length > 0) payload.id = request.id;
	process.stdout.write(`${JSON.stringify(payload)}\n`);
}

switch (verb) {
	case 'probe': {
		try {
			process.stdout.write(`${JSON.stringify(probe(readParams(argument)))}\n`);
		} catch (error) {
			process.stdout.write(`${JSON.stringify({ ok: false, error: String(error && error.message) })}\n`);
			process.exitCode = 2;
		}
		break;
	}
	case 'action': {
		try {
			process.stdout.write(`${JSON.stringify(action(readParams(argument)))}\n`);
		} catch (error) {
			process.stdout.write(`${JSON.stringify({ ok: false, error: String(error && error.message) })}\n`);
			process.exitCode = 2;
		}
		break;
	}
	case 'worker':
		worker();
		break;
	case 'overlay':
		// A ring has nothing to draw in a test; stay alive until killed like the real one.
		setInterval(() => {}, 1 << 30);
		break;
	default:
		process.stdout.write(`${JSON.stringify({ ok: false, error: `pilot: unknown verb '${verb}'` })}\n`);
		process.exitCode = 2;
}

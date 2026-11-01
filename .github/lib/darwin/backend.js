import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * macOS effector/sensor backend for dsh-pilot.
 *
 * The Windows half of this plugin runs PowerShell scripts that P/Invoke Win32 and
 * UI Automation. macOS has no equivalent through a scripting host, so this half is
 * one Swift program (`lib/darwin/Pilot.swift`) that talks CoreGraphics, ImageIO and
 * the Accessibility API directly, compiled on the target machine the first time it
 * is needed and cached by source hash.
 *
 * The contract is deliberately identical to the PowerShell side, because index.js
 * treats both as "a child that takes a params file and prints one JSON object":
 *
 *   pilot-mac probe  /path/params.json   one capture, one JSON result on stdout
 *   pilot-mac action /path/params.json   one action, one JSON result on stdout
 *   pilot-mac worker                     long-lived; base64 JSON requests on stdin
 *   pilot-mac overlay /path/state-dir    takeover ring, polls its state directory
 *
 * Compiling on the target machine is what keeps the package installable from npm:
 * a macOS arm64 binary shipped inside the tarball would be useless on Intel, and
 * shipping both would still break on the next SDK. `swiftc` comes with the Xcode
 * Command Line Tools, which this project requires on macOS; `DSH_PILOT_MAC_BIN`
 * lets an operator point at a prebuilt helper instead.
 *
 * @module dsh-pilot/darwin/backend
 */

/** True when this process should drive the macOS backend. */
export const isDarwin = process.platform === 'darwin' || process.env.DSH_PILOT_FORCE_PLATFORM === 'darwin';

/** Bumped whenever the Swift sources change in a way that must invalidate a cached build. */
const BACKEND_VERSION = '2';

/**
 * The Swift sources that make up the helper, in compile order.
 *
 * One program in five files rather than one file: the sensor, the effector, the
 * window/AX layer, the input layer and the runtime each stayed readable this way,
 * and Swift links them into a single binary anyway.
 * @returns absolute paths, in the order swiftc should see them.
 */
export function swiftSources() {
	const dir = dirname(fileURLToPath(import.meta.url));
	return ['Pilot.swift', 'PilotWindows.swift', 'PilotInput.swift', 'PilotCapture.swift', 'PilotAction.swift', 'PilotRuntime.swift']
		.map((name) => join(dir, name));
}

/** Absolute path of the Swift sources that implement this backend. */
export function swiftSource() {
	return join(dirname(fileURLToPath(import.meta.url)), 'Pilot.swift');
}

/**
 * Where compiled helpers live.
 *
 * `~/Library/Caches` on macOS: per-user, outlives a reboot, and — because the
 * binary is produced locally — carries no quarantine attribute, which is what
 * determines whether Gatekeeper will run it at all.
 * @returns the cache directory.
 */
function cacheRoot() {
	if (process.platform === 'darwin') return join(homedir(), 'Library', 'Caches', 'dsh-pilot');
	return join(tmpdir(), 'dsh-pilot-cache');
}

/** Single-flight guard: two captures at once must not compile twice. */
let building;

/**
 * Resolve the Swift compiler without assuming a shell PATH.
 * @returns absolute path of swiftc, or undefined when the toolchain is absent.
 */
function findCompiler() {
	const xcrun = spawnSync('xcrun', ['-f', 'swiftc'], { encoding: 'utf8' });
	if (xcrun.status === 0) {
		const found = xcrun.stdout.trim();
		if (found.length > 0 && existsSync(found)) return found;
	}
	for (const candidate of ['/usr/bin/swiftc', '/usr/local/bin/swiftc', '/opt/homebrew/bin/swiftc']) {
		if (existsSync(candidate)) return candidate;
	}
	const which = spawnSync('swiftc', ['--version'], { encoding: 'utf8' });
	if (which.status === 0) return 'swiftc';
	return undefined;
}

/**
 * Build the helper once per source revision and return its path.
 *
 * A failed build is reported with the compiler's own output tail: every failure
 * here is a toolchain or SDK problem the operator has to fix by hand, so guessing
 * at the cause would cost more than quoting it.
 *
 * @returns absolute path of a runnable helper.
 */
export async function ensureBinary() {
	const override = process.env.DSH_PILOT_MAC_BIN;
	if (typeof override === 'string' && override.length > 0) return override;
	if (building !== undefined) return building;

	building = (async () => {
		const sources = swiftSources();
		for (const source of sources) {
			if (!existsSync(source)) throw new Error(`pilot: the macOS helper source is missing at ${source}`);
		}
		const digest = createHash('sha256');
		for (const source of sources) digest.update(readFileSync(source));
		const hash = digest.update(BACKEND_VERSION).digest('hex').slice(0, 12);
		const dir = join(cacheRoot(), 'bin');
		const binary = join(dir, `pilot-mac-${hash}`);
		if (existsSync(binary)) return binary;

		const compiler = findCompiler();
		if (compiler === undefined) {
			throw new Error(
				'pilot: the macOS helper needs a Swift compiler, and none was found. ' +
				'Install the Xcode Command Line Tools with `xcode-select --install`, then run the same call again. ' +
				'An already built helper can also be pointed at with DSH_PILOT_MAC_BIN=/path/to/pilot-mac.'
			);
		}

		mkdirSync(dir, { recursive: true });
		const staging = `${binary}.${process.pid.toString(36)}.tmp`;
		const built = await new Promise((resolvePromise, rejectPromise) => {
			// -parse-as-library: the entry point is `@main`, not a main.swift with top-level code.
			const child = spawn(compiler, ['-O', '-parse-as-library', '-module-name', 'Pilot', '-o', staging, ...sources], {
				stdio: ['ignore', 'pipe', 'pipe'],
				env: process.env
			});
			let stderr = '';
			child.stdout.on('data', () => {});
			child.stderr.on('data', (chunk) => {
				stderr += chunk.toString('utf8');
				if (stderr.length > 16000) stderr = stderr.slice(-16000);
			});
			child.on('error', (error) => rejectPromise(error));
			child.on('close', (code) => {
				if (code === 0) resolvePromise(true);
				else rejectPromise(new Error(`swiftc exited with ${code}:\n${stderr.trim()}`));
			});
		}).catch((error) => {
			try {
				rmSync(staging, { force: true });
			} catch {
				// A leftover staging file cannot be executed: it is not at `binary`.
			}
			throw new Error(`pilot: could not build the macOS helper (${error instanceof Error ? error.message : String(error)})`);
		});
		if (built !== true) throw new Error('pilot: the macOS helper build produced nothing');
		chmodSync(staging, 0o755);
		renameSync(staging, binary);
		return binary;
	})();

	try {
		return await building;
	} finally {
		// Keep the resolved path, drop the in-flight promise so a later failure retries.
		building = undefined;
	}
}

/**
 * Leading arguments prepended to every helper command line.
 *
 * Production leaves this empty. The test harness uses it to run a stand-in written
 * in Node through the real command line (`DSH_PILOT_MAC_BIN=node` plus
 * `DSH_PILOT_MAC_BIN_PREFIX=<stub.mjs>`), which is the only way to exercise the
 * spawn → params file → JSON line path on a host that is not a Mac.
 * @returns the leading argument vector.
 */
function argumentPrefix() {
	const raw = process.env.DSH_PILOT_MAC_BIN_PREFIX;
	if (typeof raw !== 'string' || raw.trim().length === 0) return [];
	return raw.split(' ').filter((part) => part.length > 0);
}

/**
 * Arguments for the one-shot sensor: `probe <params file>`.
 * @param paramsPath - absolute path of the JSON parameter file.
 * @returns the argument vector.
 */
export function probeArgs(paramsPath) {
	return [...argumentPrefix(), 'probe', paramsPath];
}

/**
 * Arguments for the one-shot effector: `action <params file>`.
 * @param paramsPath - absolute path of the JSON parameter file.
 * @returns the argument vector.
 */
export function actionArgs(paramsPath) {
	return [...argumentPrefix(), 'action', paramsPath];
}

/** Arguments for the warm worker: it speaks the same line protocol as the PowerShell one. */
export function workerArgs() {
	return [...argumentPrefix(), 'worker'];
}

/**
 * Arguments for the takeover ring helper.
 * @param stateDir - directory the ring polls for show/mute/esc tokens.
 * @returns the argument vector.
 */
export function overlayArgs(stateDir) {
	return [...argumentPrefix(), 'overlay', stateDir];
}

/** Human-readable name used in error messages from index.js. */
export const helperName = 'the macOS helper';

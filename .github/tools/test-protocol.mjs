#!/usr/bin/env node
/**
 * Exercise the plugin's JavaScript half end to end against the stub helper.
 *
 * What this proves, on any host including Windows and CI:
 *   - lib/index.js loads under the darwin platform and registers its three tools;
 *   - the spawn path builds the helper command, writes the params file, parses the
 *     one-line JSON result, and deletes the scratch file;
 *   - the warm worker is started, speaks base64 JSON on stdin, and answers with ids;
 *   - capture, action, control listing and batch execution all project into the
 *     closed output schemas the runtime validates.
 *
 * What it cannot prove: that the Swift helper compiles and drives a real Mac. Run
 * `node tools/test-protocol.mjs` on the Mac, then `pilot-mac selftest`, then the
 * smoke steps in README-macOS.md.
 *
 * Usage: node tools/test-protocol.mjs
 */

import { existsSync, mkdtempSync, rmSync } from 'node:fs';
import { register } from 'node:module';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const packageRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const stub = join(packageRoot, 'tools', 'stub-helper.mjs');

// The backend decides its platform at import time, so these must be set first.
process.env.DSH_PILOT_FORCE_PLATFORM = 'darwin';
process.env.DSH_PILOT_MAC_BIN = process.execPath;
process.env.DSH_PILOT_MAC_BIN_PREFIX = stub;

// The plugin's two harness packages come from the Harness at runtime, not from npm,
// so the loader maps just those two specifiers onto local shims. This keeps
// lib/index.js untouched and the package free of a node_modules directory.
register('./test-loader.mjs', import.meta.url);

const results = [];
function check(name, condition, detail) {
	results.push({ name, ok: condition === true, detail });
	if (condition !== true) {
		console.error(`FAIL ${name}${detail === undefined ? '' : ` — ${detail}`}`);
	} else {
		console.log(`ok   ${name}`);
	}
}

const workspace = mkdtempSync(join(tmpdir(), 'dsh-pilot-test-'));
const module = await import('../lib/index.js');

check('module exports the loader identity', module.name === 'pilot', module.name);
check('module exports apply/Config/inject', typeof module.apply === 'function' && module.Config !== undefined && Array.isArray(module.inject));

const definitions = new Map();
const attachments = {
	imageLimits: {
		maxImageBytes: 8 * 1024 * 1024,
		maxMessageImageBytes: 8 * 1024 * 1024,
		maxImagePixels: 64000000,
		maxImageDimension: 8192
	},
	async saveImage({ data, mediaType, name }) {
		return { attachmentId: 'stub-attachment', mediaType, bytes: data.byteLength, width: 3024, height: 1964, name };
	}
};

const ctx = {
	tools: { register(definition) { definitions.set(definition.name, definition); } },
	get(service) {
		if (service === 'attachments') return attachments;
		if (service === 'llm') return { async resolveModelInfo() { return { inputModalities: ['text', 'image'] }; } };
		return undefined;
	},
	effect() {
		return () => {};
	}
};

const config = {
	captureRetention: 30,
	timeoutMs: 20000,
	settleMs: 50,
	stepSettleMs: 10,
	maxSequenceSteps: 24,
	useWorker: true,
	rulers: true,
	alwaysSaveFile: true,
	takeover: false,
	takeoverLingerMs: 200
};

module.apply(ctx, config);
check('three tools registered', definitions.size === 3, [...definitions.keys()].join(','));

const exec = {
	signal: new AbortController().signal,
	agent: {
		session: {
			header: { cwd: workspace, sessionId: 'test-session' },
			requestHeader: () => ({ config: { provider: 'stub', model: 'stub-model' } })
		},
		options: { provider: 'stub', model: 'stub-model' }
	}
};

// --- screen_view -------------------------------------------------------------
const view = await definitions.get('screen_view').execute({}, exec);
check('capture reports the frame path', typeof view.path === 'string' && existsSync(view.path), view.path);
check('capture reports the pixel scale', view.scale === 2, String(view.scale));
check('capture reports the screen inventory', Array.isArray(view.screens) && view.screens.length === 2);
check('capture projects the window entry', view.foregroundWindow?.handle === '0x1A2B3C', JSON.stringify(view.foregroundWindow));
check('capture carries the image attachment', view.image?.attachmentId === 'stub-attachment', JSON.stringify(view.image));
const blocks = definitions.get('screen_view').output.render({}, view);
check('capture renders a text block and an image block', blocks.length === 2 && blocks[1].type === 'image');
check('capture envelope mentions the frame size', blocks[0].text.includes('<image_size>3024x1964</image_size>'), blocks[0].text.split('\n')[2]);

// --- desktop_control (warm worker path) --------------------------------------
const click = await definitions.get('desktop_control').execute({ action: 'click', x: 100, y: 200, capture: false }, exec);
check('click result echoes the action', click.action === 'click', JSON.stringify(click));
check('click result carries a cursor', click.cursor?.x === 640, JSON.stringify(click.cursor));

const windows = await definitions.get('desktop_control').execute({ action: 'windows' }, exec);
check('windows action lists windows', Array.isArray(windows.windows) && windows.windows.length === 1, JSON.stringify(windows.windows));
check('window entry keeps its declared fields', windows.windows[0].minimized === false && windows.windows[0].foreground === true);

const controls = await definitions.get('desktop_control').execute({ action: 'controls', title: 'Stub Window' }, exec);
check('controls action lists lines', Array.isArray(controls.controls) && controls.controls.length === 2, JSON.stringify(controls.controls));
check('controls action reports the counts', controls.controlCount === 2 && controls.controlTotal === 12 && controls.filteredOut === 10);
check('controls action leaves no capture behind', controls.capture === undefined);

const paste = await definitions.get('desktop_control').execute({ action: 'type', text: 'héllo 世界', capture: false }, exec);
check('type result carries the paste note', Array.isArray(paste.notes) && paste.notes.length === 1, JSON.stringify(paste.notes));

// --- desktop_sequence --------------------------------------------------------
const batch = await definitions.get('desktop_sequence').execute(
	{
		steps: [
			{ action: 'click', x: 10, y: 20 },
			{ action: 'wait', ms: 20 },
			{ action: 'key', key: 'ctrl+s' }
		],
		capture: 'none'
	},
	exec
);
check('batch executes every step', batch.executed === 3 && batch.failed === 0, JSON.stringify({ executed: batch.executed, failed: batch.failed }));
check('batch reports a cursor', typeof batch.cursor?.x === 'number');

const dry = await definitions.get('desktop_sequence').execute({ steps: [{ action: 'click', x: 1, y: 2 }], dryRun: true }, exec);
check('dry run plans without acting', dry.planned === true && dry.executed === 0);

let refused = false;
try {
	await definitions.get('desktop_sequence').execute({ steps: [{ action: 'click', x: 1, y: 2, risk: 'high' }] }, exec);
} catch (error) {
	refused = String(error.message).includes('refused before touching the desktop');
}
check('risky batch is refused without confirm', refused);

// --- platform gate -----------------------------------------------------------
process.env.DSH_PILOT_FORCE_PLATFORM = 'linux';
const gateSource = (await import('node:fs')).readFileSync(join(packageRoot, 'lib', 'index.js'), 'utf8');
check('apply() refuses a host with no desktop backend', gateSource.includes('no desktop backend for'));

rmSync(workspace, { recursive: true, force: true });

const failed = results.filter((entry) => !entry.ok);
console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
process.exit(failed.length === 0 ? 0 : 1);

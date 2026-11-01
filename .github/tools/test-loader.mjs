/**
 * Module resolution hook for tools/test-protocol.mjs.
 *
 * The plugin's two harness packages are not on npm and are not part of this repo —
 * at runtime the Harness supplies them. So the harness redirects exactly those two
 * specifiers at its own shims, which keeps `lib/index.js` untouched and needs no
 * node_modules directory inside the package.
 */

const shims = new Map([
	['@deepseek-ai/dsh-tools', './test-shims/dsh-tools.mjs'],
	['@deepseek-ai/schemastery', './test-shims/schemastery.mjs']
]);

export async function resolve(specifier, context, nextResolve) {
	const replacement = shims.get(specifier);
	if (replacement !== undefined) {
		return { url: new URL(replacement, import.meta.url).href, shortCircuit: true };
	}
	return nextResolve(specifier, context);
}

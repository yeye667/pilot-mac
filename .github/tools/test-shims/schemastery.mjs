/**
 * Stand-in for `@deepseek-ai/schemastery`, loaded only by tools/test-protocol.mjs.
 *
 * lib/index.js builds one schema at import time and then reads the already-validated
 * config the harness supplies, so the chain has to exist and must not throw.
 * Nothing here validates anything.
 */

function chain() {
	const api = {
		default: () => api,
		description: () => api,
		required: () => api,
		optional: () => api,
		minimum: () => api,
		maximum: () => api,
		enum: () => api
	};
	return api;
}

const z = {
	object: (shape) => shape,
	array: (inner) => inner,
	number: chain,
	string: chain,
	boolean: chain,
	union: (shapes) => shapes,
	any: chain,
	dict: (value) => value
};

export default z;
export { z };

/**
 * Stand-in for `@deepseek-ai/dsh-tools`, loaded only by tools/test-protocol.mjs
 * through tools/test-loader.mjs.
 *
 * The real package validates a tool definition and turns the `parameters` shorthand
 * into JSON Schema; the plugin hands the definition straight to `ctx.tools.register`,
 * so a passthrough is enough to exercise everything below that boundary.
 */

export function defineTool(definition) {
	return definition;
}

export default { defineTool };

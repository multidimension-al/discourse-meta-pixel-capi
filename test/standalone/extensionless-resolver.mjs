/**
 * Node ESM resolver hook for the standalone test run.
 *
 * Discourse's build resolves extensionless relative imports (`./ga4-schema`),
 * which bare Node does not. Rather than writing non-idiomatic `.js` suffixes
 * into the plugin source purely to satisfy `node --test`, this hook retries a
 * failed relative resolution with `.js` appended.
 *
 * Only used by test/standalone; the QUnit suite and the real build never see
 * it.
 */
export async function resolve(specifier, context, nextResolve) {
  try {
    return await nextResolve(specifier, context);
  } catch (error) {
    if (specifier.startsWith(".") && !specifier.endsWith(".js")) {
      return nextResolve(`${specifier}.js`, context);
    }
    throw error;
  }
}

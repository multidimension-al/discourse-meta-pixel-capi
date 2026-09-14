import { resetPixelForTesting } from "discourse/plugins/discourse-meta-pixel-capi/discourse/lib/meta-pixel-tag";

/**
 * Acceptance tests share one page, and the Pixel installer is deliberately
 * idempotent — so a leaked install flag would make the second test in a module
 * silently assert nothing.
 */
export function resetPixel() {
  resetPixelForTesting(window, document);
  window.__metaPixelCalls = [];
}

/**
 * Install a recording `fbq` in place of the real one.
 *
 * Records the full argument list of every call, which is what lets a test
 * assert that the Pixel and the server mirror were given the *same* event id —
 * the property Meta's deduplication depends on.
 */
export function installRecordingFbq() {
  window.__metaPixelCalls = [];
  window.fbq = function (...args) {
    window.__metaPixelCalls.push(args);
  };
  window.__discourseMetaPixelInstalled = true;
}

export function fbqCalls() {
  return window.__metaPixelCalls || [];
}

export function trackedEvents(name) {
  return fbqCalls().filter((call) => call[0] === "track" && call[1] === name);
}

export function trackedEventNames() {
  return fbqCalls()
    .filter((call) => call[0] === "track")
    .map((call) => call[1]);
}

/** The `eventID` passed as the fourth argument to `fbq('track', ...)`. */
export function eventIdOf(call) {
  return call[3]?.eventID;
}

/**
 * The calls queued on the *real* `fbq` stub that the plugin installs.
 *
 * `installRecordingFbq` replaces `fbq` outright, so a test that needs to see
 * what the genuine base code did — that `init` ran, and ran once — has to read
 * the stub's own queue instead.
 */
export function queuedFbqCalls() {
  return Array.from(window.fbq?.queue ?? []);
}

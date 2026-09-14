/**
 * Event identity, browser side.
 *
 * Meta deduplicates a Pixel event against a Conversions API event when the
 * event **name** and event **id** both match, within 48 hours. So a mirrored
 * event has exactly one id, generated once here, handed to `fbq` as `eventID`
 * and posted to this plugin's endpoint as `event_id`.
 *
 * Generating a second id anywhere — a "server-side uuid" for the same logical
 * event — would produce two conversions that look like two people. That is why
 * this module exists at all rather than the id being created inline at each
 * call site.
 *
 * The format (32 lowercase hex characters, 128 bits) is not cosmetic: the
 * server endpoint validates it exactly, so an id it did not shape is an id it
 * refuses.
 */

const HEX = "0123456789abcdef";

/**
 * A cryptographically random 128-bit id as 32 lowercase hex characters.
 *
 * `crypto.getRandomValues` is available in every browser Discourse supports.
 * The fallback exists only so that a missing crypto implementation degrades to
 * a working (if less collision-resistant) id rather than throwing inside an
 * analytics call path.
 */
export function generateEventId() {
  const bytes = new Uint8Array(16);

  if (typeof crypto !== "undefined" && crypto.getRandomValues) {
    crypto.getRandomValues(bytes);
  } else {
    for (let i = 0; i < bytes.length; i++) {
      bytes[i] = Math.floor(Math.random() * 256);
    }
  }

  let out = "";
  for (const byte of bytes) {
    out += HEX[Math.floor(byte / 16)] + HEX[byte % 16];
  }
  return out;
}

export const EVENT_ID_PATTERN = /^[0-9a-f]{32}$/;

export function isValidEventId(value) {
  return typeof value === "string" && EVENT_ID_PATTERN.test(value);
}

/**
 * Ids the server may hand back for a server-paired event.
 *
 * Browser-generated ids are exactly 32 hex characters; ids the server derives
 * from an object are a SHA-256 hex digest, so 64. This accepts either, and
 * still rejects anything that is not lowercase hex — the meta tag it validates
 * is server-rendered, but validating it anyway keeps the one rule about what
 * an event id may look like in one file.
 */
export const SERVER_EVENT_ID_PATTERN = /^[0-9a-f]{32,64}$/;

export function isValidEventId32Plus(value) {
  return typeof value === "string" && SERVER_EVENT_ID_PATTERN.test(value);
}

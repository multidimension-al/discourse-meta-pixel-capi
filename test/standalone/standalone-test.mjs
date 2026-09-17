/**
 * Standalone tests for the dependency-free JavaScript in this plugin.
 *
 * Plain Node — no Discourse checkout, no browser, no build:
 *
 *   node --import ./test/standalone/register.mjs test/standalone/standalone-test.mjs
 *
 * Covers event identity and the eligibility rules: the two things that decide
 * whether a Pixel event fires at all and whether it can be deduplicated
 * against its Conversions API twin. The QUnit suite under test/javascripts
 * covers these plus everything needing a running application, and is what CI
 * runs.
 */

import assert from "node:assert/strict";
import test from "node:test";

import {
  EVENT_ID_PATTERN,
  generateEventId,
  isValidEventId,
  isValidEventId32Plus,
} from "../../assets/javascripts/discourse/lib/meta-event-id.js";
import {
  EXCLUSION,
  isSensitiveRoute,
  MIRRORED_EVENTS,
  topicExclusion,
  topicIsEligible,
} from "../../assets/javascripts/discourse/lib/meta-eligibility.js";
import {
  fbqMethodFor,
  isStandardEvent,
  STANDARD_EVENTS,
} from "../../assets/javascripts/discourse/lib/meta-standard-events.js";

test("generated event ids match the shape the server enforces", () => {
  for (let i = 0; i < 200; i++) {
    const id = generateEventId();
    assert.match(id, EVENT_ID_PATTERN, `${id} is 32 lowercase hex characters`);
    assert.ok(isValidEventId(id));
  }
});

test("generated event ids are unique", () => {
  const ids = new Set();
  for (let i = 0; i < 5000; i++) {
    ids.add(generateEventId());
  }
  assert.equal(ids.size, 5000, "no collisions across 5000 ids");
});

test("event id validation refuses anything it did not shape", () => {
  for (const bad of [
    "",
    null,
    undefined,
    "A".repeat(32),
    "a".repeat(31),
    "a".repeat(33),
    "g".repeat(32),
    "../../etc/passwd",
    `${"a".repeat(32)}\n`,
  ]) {
    assert.equal(isValidEventId(bad), false, JSON.stringify(bad));
  }
});

test("server-derived ids are accepted where the server chose them", () => {
  // A browser id is 32 hex characters; an id the server derives from an object
  // is a SHA-256 digest, so 64. The registration pairing hands the browser a
  // server-derived id, so that path has to accept both lengths — while still
  // rejecting anything that is not lowercase hex.
  assert.equal(isValidEventId32Plus("a".repeat(32)), true);
  assert.equal(isValidEventId32Plus("a".repeat(64)), true);
  assert.equal(isValidEventId32Plus("a".repeat(31)), false);
  assert.equal(isValidEventId32Plus("a".repeat(65)), false);
  assert.equal(isValidEventId32Plus("A".repeat(64)), false);
  assert.equal(isValidEventId32Plus("g".repeat(64)), false);
  assert.equal(isValidEventId32Plus(null), false);

  // The stricter browser check must still refuse a 64-character id: the
  // endpoint only ever accepts ids the browser itself generated.
  assert.equal(isValidEventId("a".repeat(64)), false);
});

test("only four events may be mirrored from the browser", () => {
  assert.deepEqual(MIRRORED_EVENTS, [
    "PageView",
    "ViewContent",
    "Search",
    "TopicEngaged",
  ]);
  // The server-authoritative conversions must never be browser-originated.
  for (const name of ["CompleteRegistration", "TopicCreated", "ReplyCreated"]) {
    assert.ok(!MIRRORED_EVENTS.includes(name), `${name} is server-only`);
  }
});

const categories = [
  { id: 4, slug: "general", read_restricted: false },
  { id: 9, slug: "staff", read_restricted: true },
];
const options = {
  findCategoryById: (id) => categories.find((c) => c.id === id) ?? null,
};

test("a private message is always excluded", () => {
  assert.equal(
    topicExclusion({ id: 1, archetype: "private_message" }, options),
    EXCLUSION.PRIVATE_MESSAGE
  );
  // Not even by turning the public-content-only setting off.
  assert.equal(
    topicExclusion(
      { id: 1, archetype: "private_message" },
      { ...options, publicContentOnly: false }
    ),
    EXCLUSION.PRIVATE_MESSAGE,
    "the PM rule is checked first and is not opt-out-able"
  );
});

test("restricted and unresolvable content is excluded", () => {
  assert.equal(
    topicExclusion({ id: 1, archetype: "regular", category_id: 9 }, options),
    EXCLUSION.RESTRICTED
  );
  assert.equal(
    topicExclusion({ id: 1, archetype: "regular", category_id: 404 }, options),
    EXCLUSION.NOT_LOADED,
    "an unresolvable category is not provably public"
  );
  assert.equal(topicExclusion(null, options), EXCLUSION.NOT_LOADED);
  assert.equal(
    topicExclusion({ id: 1, category_id: 4 }, options),
    EXCLUSION.NOT_LOADED,
    "archetype not loaded"
  );
  assert.equal(
    topicExclusion(
      { id: 1, archetype: "regular", category_id: 4 },
      { ...options, loginRequired: true }
    ),
    EXCLUSION.RESTRICTED,
    "nothing is anonymously visible on a login-required forum"
  );
});

test("a genuinely public topic is eligible", () => {
  assert.ok(
    topicIsEligible({ id: 1, archetype: "regular", category_id: 4 }, options)
  );
  assert.ok(
    topicIsEligible({ id: 1, archetype: "regular" }, options),
    "uncategorised"
  );
});

test("sensitive routes are refused", () => {
  const cases = [
    "/admin",
    "/admin/users/1/alice",
    "/review",
    "/safe-mode",
    "/my/messages",
    "/u/alice/messages",
    "/u/alice/messages/sent",
    "/u/alice/preferences/security",
    "/topics/private-messages/alice",
    "/u/password-reset/tok",
    "/u/activate-account/tok",
    "/u/email-login/tok",
    "/u/confirm-new-email/tok",
    "/invites/tok",
    "/associate/tok",
    "/auth/facebook/callback",
  ];

  for (const url of cases) {
    assert.ok(isSensitiveRoute({ url }), `${url} should be refused`);
  }
});

test("lookalike public routes are not refused", () => {
  for (const url of [
    "/latest",
    "/t/a-topic/12",
    "/c/reviews/12",
    "/tags/c/admin",
    "/u/alice/summary",
    "/u/alice",
  ]) {
    assert.ok(!isSensitiveRoute({ url }), `${url} should be allowed`);
  }
});

test("route names are refused independently of the path", () => {
  assert.ok(isSensitiveRoute({ url: "/", routeName: "adminPlugins.show" }));
  assert.ok(isSensitiveRoute({ url: "/", routeName: "userPrivateMessages" }));
  assert.ok(!isSensitiveRoute({ url: "/", routeName: "discovery.latest" }));
});

test("suppression survives a subfolder install", () => {
  assert.ok(isSensitiveRoute({ url: "/forum/admin/x", basePath: "/forum/" }));
  assert.ok(!isSensitiveRoute({ url: "/forum/latest", basePath: "/forum/" }));
});

test("standard events are sent through fbq('track')", () => {
  for (const name of STANDARD_EVENTS) {
    assert.equal(isStandardEvent(name), true, name);
    assert.equal(fbqMethodFor(name), "track", name);
  }
});

test("this plugin's own events are sent through fbq('trackCustom')", () => {
  for (const name of ["TopicEngaged", "TopicCreated", "ReplyCreated"]) {
    assert.equal(isStandardEvent(name), false, name);
    assert.equal(fbqMethodFor(name), "trackCustom", name);
  }
});

test("every mirrored event is classified deliberately", () => {
  const expected = {
    PageView: "track",
    ViewContent: "track",
    Search: "track",
    TopicEngaged: "trackCustom",
  };

  for (const name of MIRRORED_EVENTS) {
    assert.equal(fbqMethodFor(name), expected[name], name);
  }
});

test("an unknown name falls back to trackCustom", () => {
  for (const name of ["", null, undefined, "pageview", "viewcontent", "Nope"]) {
    assert.equal(fbqMethodFor(name), "trackCustom", JSON.stringify(name));
  }
});

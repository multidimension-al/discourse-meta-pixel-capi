import { visit } from "@ember/test-helpers";
import { test } from "qunit";
import pretender, { response } from "discourse/tests/helpers/create-pretender";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";
import { pixelScriptCount } from "discourse/plugins/discourse-meta-pixel-capi/discourse/lib/meta-pixel-tag";
import {
  eventIdOf,
  fbqCalls,
  installRecordingFbq,
  queuedFbqCalls,
  resetPixel,
  trackedEventNames,
  trackedEvents,
  trackMethodOf,
} from "../helpers/meta-pixel-helpers";

const SETTINGS = {
  discourse_meta_pixel_enabled: true,
  meta_pixel_pixel_enabled: true,
  meta_pixel_dataset_id: "123456789012345",
  meta_pixel_capi_enabled: true,
  meta_pixel_respect_do_not_track: false,
  meta_pixel_public_content_only: true,
};

const CATEGORIES = [
  { id: 4, slug: "general", name: "General", read_restricted: false },
  { id: 9, slug: "staff", name: "Staff", read_restricted: true },
];

const PUBLIC_TOPIC = {
  id: 280,
  archetype: "regular",
  title: "A public topic",
  category_id: 4,
};

const PRIVATE_MESSAGE = {
  id: 999,
  archetype: "private_message",
  title: "Re: invoice 44821",
  category_id: null,
  details: { allowed_users: [{ username: "alice" }] },
};

const STAFF_TOPIC = {
  id: 777,
  archetype: "regular",
  title: "Moderation notes",
  category_id: 9,
};

/** Records every body POSTed to the mirror endpoint. */
function captureMirror() {
  const captured = [];
  pretender.post("/meta-pixel/events", (request) => {
    captured.push(new URLSearchParams(request.requestBody));
    return response({ success: true });
  });
  return captured;
}

acceptance("Meta Pixel | initialisation", function (needs) {
  needs.settings(SETTINGS);
  needs.site({ categories: CATEGORIES });

  needs.hooks.beforeEach(function () {
    resetPixel();
    // Every module needs the mirror endpoint stubbed: an unhandled POST is a
    // global error that aborts the whole run, not a single test failure.
    captureMirror();
  });
  needs.hooks.afterEach(function () {
    resetPixel();
  });

  // This module deliberately leaves the genuine `fbq` stub in place: the thing
  // under test is the base code the plugin installs, so a recording stand-in
  // would assert nothing about it.
  test("initialises the dataset exactly once", async function (assert) {
    await visit("/");
    await visit("/faq");
    await visit("/");

    const inits = queuedFbqCalls().filter((call) => call[0] === "init");

    assert.strictEqual(inits.length, 1, "init is not repeated on navigation");
    assert.strictEqual(inits[0][1], "123456789012345");
  });

  test("does not accumulate loader scripts", async function (assert) {
    await visit("/");
    await visit("/faq");

    assert.strictEqual(
      pixelScriptCount(document),
      0,
      "script injection is skipped under test and never accumulates"
    );
  });
});

acceptance("Meta Pixel | events", function (needs) {
  needs.settings(SETTINGS);
  needs.site({ categories: CATEGORIES });

  let mirrored;

  needs.hooks.beforeEach(function () {
    resetPixel();
    installRecordingFbq();
    mirrored = captureMirror();
  });
  needs.hooks.afterEach(function () {
    resetPixel();
  });

  test("fires one PageView per eligible navigation", async function (assert) {
    await visit("/");
    assert.strictEqual(trackedEvents("PageView").length, 1, "boot");

    await visit("/faq");
    assert.strictEqual(trackedEvents("PageView").length, 2, "one transition");
  });

  test("fires ViewContent once per public topic visit", async function (assert) {
    await visit("/");
    const pixel = this.owner.lookup("service:meta-pixel");

    pixel.track("ViewContent", {
      customData: { content_type: "topic", content_ids: ["280"] },
      topicId: PUBLIC_TOPIC.id,
    });

    const events = trackedEvents("ViewContent");
    assert.strictEqual(events.length, 1);
    assert.deepEqual(events[0][2].content_ids, ["280"]);
  });

  // Sending a standard event through `trackCustom` would lose Meta's own
  // reporting for it, exactly as sending a custom one through `track` earns a
  // console warning and a second-class custom conversion.
  test("standard events are sent through fbq('track')", async function (assert) {
    await visit("/");
    const pixel = this.owner.lookup("service:meta-pixel");

    pixel.track("ViewContent", { topicId: PUBLIC_TOPIC.id });

    assert.strictEqual(
      trackMethodOf(trackedEvents("PageView").at(-1)),
      "track"
    );
    assert.strictEqual(
      trackMethodOf(trackedEvents("ViewContent").at(-1)),
      "track"
    );
  });

  // The property Meta's deduplication depends on. If these ever diverge the
  // events still arrive — they are simply counted twice.
  test("the Pixel and the server mirror share one event id", async function (assert) {
    await visit("/");
    const pixel = this.owner.lookup("service:meta-pixel");

    const returnedId = pixel.track("ViewContent", { topicId: PUBLIC_TOPIC.id });
    await new Promise((resolve) => setTimeout(resolve, 0));

    const pixelCall = trackedEvents("ViewContent").at(-1);
    const mirrorCall = mirrored.at(-1);

    assert.strictEqual(
      eventIdOf(pixelCall),
      returnedId,
      "the Pixel got the generated id"
    );
    assert.strictEqual(
      mirrorCall.get("event_id"),
      returnedId,
      "and the server got the same one"
    );
    assert.strictEqual(
      mirrorCall.get("event_name"),
      pixelCall[1],
      "and the event names match"
    );
  });

  test("the mirror body carries nothing but the tiny schema", async function (assert) {
    await visit("/");
    const pixel = this.owner.lookup("service:meta-pixel");

    pixel.track("ViewContent", { topicId: PUBLIC_TOPIC.id });
    await new Promise((resolve) => setTimeout(resolve, 0));

    const keys = [...mirrored.at(-1).keys()].sort();

    assert.deepEqual(keys, ["event_id", "event_name", "topic_id"]);
    assert.false(keys.includes("user_data"), "no user data is asserted");
    assert.false(keys.includes("access_token"), "no credential is sent");
  });
});

acceptance("Meta Pixel | privacy", function (needs) {
  needs.settings(SETTINGS);
  needs.site({ categories: CATEGORIES });

  needs.hooks.beforeEach(function () {
    resetPixel();
    installRecordingFbq();
    captureMirror();
  });
  needs.hooks.afterEach(function () {
    resetPixel();
  });

  test("no content event for a private message", async function (assert) {
    await visit("/");
    const engagement = this.owner.lookup("service:meta-topic-engagement");
    const before = trackedEventNames().length;

    engagement.startVisit(PRIVATE_MESSAGE);
    engagement.tick(true, Date.now() + 600000);

    assert.strictEqual(
      trackedEventNames().length,
      before,
      "no ViewContent and no TopicEngaged"
    );
    assert.strictEqual(
      engagement.topic,
      null,
      "no engagement state is held for a PM"
    );
  });

  test("no private message detail can reach the Pixel", async function (assert) {
    await visit("/");
    const engagement = this.owner.lookup("service:meta-topic-engagement");

    engagement.startVisit(PRIVATE_MESSAGE);
    engagement.tick(true, Date.now() + 600000);

    const serialized = JSON.stringify(fbqCalls());
    assert.false(serialized.includes("999"), "no PM topic id");
    assert.false(serialized.includes("invoice"), "no PM title");
    assert.false(serialized.includes("alice"), "no participants");
  });

  test("no content event for a staff-only topic", async function (assert) {
    await visit("/");
    const engagement = this.owner.lookup("service:meta-topic-engagement");

    engagement.startVisit(STAFF_TOPIC);

    assert.strictEqual(engagement.topic, null);
    assert.false(
      JSON.stringify(fbqCalls()).includes("Moderation notes"),
      "no restricted title"
    );
  });

  test("no event on a sensitive route", async function (assert) {
    await visit("/");
    const before = trackedEvents("PageView").length;

    await visit("/u/eviltrout/messages");

    assert.strictEqual(
      trackedEvents("PageView").length,
      before,
      "the PM inbox produces no PageView"
    );
  });

  test("topic titles are never sent", async function (assert) {
    await visit("/t/internationalization-localization/280");

    assert.false(
      JSON.stringify(fbqCalls()).toLowerCase().includes("internationalization"),
      "custom data carries ids and a category, never the title"
    );
  });
});

acceptance("Meta Pixel | admin routes", function (needs) {
  needs.settings(SETTINGS);
  needs.site({ categories: CATEGORIES });
  // `/admin` is only reachable by an admin, and core's admin chrome
  // dereferences `currentUser` — an anonymous visit fails in the harness
  // before the plugin is consulted at all.
  needs.user({ admin: true, moderator: true });

  needs.hooks.beforeEach(function () {
    resetPixel();
    installRecordingFbq();
    // Every module needs the mirror endpoint stubbed: an unhandled POST is a
    // global error that aborts the whole run, not a single test failure.
    captureMirror();
  });
  needs.hooks.afterEach(function () {
    resetPixel();
  });

  test("no event on an admin route", async function (assert) {
    await visit("/");
    const before = trackedEvents("PageView").length;

    await visit("/admin");

    assert.strictEqual(trackedEvents("PageView").length, before);
  });
});

acceptance("Meta Pixel | engagement", function (needs) {
  needs.settings({ ...SETTINGS, meta_pixel_topic_engaged_seconds: 30 });
  needs.site({ categories: CATEGORIES });

  needs.hooks.beforeEach(function () {
    resetPixel();
    installRecordingFbq();
    captureMirror();
  });
  needs.hooks.afterEach(function () {
    resetPixel();
  });

  // Each tick is placed exactly one second after the service's own last one.
  // Deriving the time from `Date.now()` instead rewound the clock behind that
  // mark on a second call, and a negative delta banks no time at all.
  function advance(engagement, seconds, present = true) {
    for (let i = 0; i < seconds; i++) {
      engagement.tick(present, engagement._lastTickAt + 1000);
    }
  }

  test("fires once, after the threshold", async function (assert) {
    await visit("/");
    const engagement = this.owner.lookup("service:meta-topic-engagement");

    engagement.startVisit(PUBLIC_TOPIC);

    advance(engagement, 29);
    assert.strictEqual(trackedEvents("TopicEngaged").length, 0, "not yet");

    advance(engagement, 1);
    assert.strictEqual(trackedEvents("TopicEngaged").length, 1, "fired");

    // Not one of Meta's standard events: sent through `track` it still
    // arrives, but fbevents.js warns and Events Manager does not treat it as a
    // custom conversion.
    assert.strictEqual(
      trackMethodOf(trackedEvents("TopicEngaged")[0]),
      "trackCustom",
      "a custom event goes through trackCustom"
    );

    advance(engagement, 300);
    assert.strictEqual(
      trackedEvents("TopicEngaged").length,
      1,
      "and only once per visit"
    );
  });

  test("time with the reader absent does not count", async function (assert) {
    await visit("/");
    const engagement = this.owner.lookup("service:meta-topic-engagement");

    engagement.startVisit(PUBLIC_TOPIC);
    advance(engagement, 600, false);

    assert.strictEqual(
      trackedEvents("TopicEngaged").length,
      0,
      "ten minutes of a hidden tab is not engagement"
    );
  });

  test("a suspended tab cannot bank the elapsed time", async function (assert) {
    await visit("/");
    const engagement = this.owner.lookup("service:meta-topic-engagement");

    engagement.startVisit(PUBLIC_TOPIC);
    engagement.tick(true, Date.now() + 3600000);

    assert.strictEqual(trackedEvents("TopicEngaged").length, 0);
    assert.true(engagement.engagedSeconds <= 2, "the delta is capped");
  });

  test("leaving the topic resets the visit", async function (assert) {
    await visit("/");
    const engagement = this.owner.lookup("service:meta-topic-engagement");

    engagement.startVisit(PUBLIC_TOPIC);
    advance(engagement, 20);
    engagement.endVisit();

    assert.strictEqual(engagement.engagedSeconds, 0);

    engagement.startVisit(PUBLIC_TOPIC);
    advance(engagement, 20);

    assert.strictEqual(
      trackedEvents("TopicEngaged").length,
      0,
      "the second visit starts its own clock"
    );
  });
});

acceptance("Meta Pixel | server-paired registration", function (needs) {
  needs.settings(SETTINGS);
  needs.site({ categories: CATEGORIES });

  let mirrored;
  needs.hooks.beforeEach(function () {
    resetPixel();
    installRecordingFbq();
    mirrored = captureMirror();
  });
  needs.hooks.afterEach(function () {
    resetPixel();
  });

  const SERVER_ID = "a".repeat(64);

  // The whole point of the pairing: Meta deduplicates on event_name plus
  // event_id, so the Pixel copy must carry the id the server already used for
  // the Conversions API copy rather than minting its own.
  test("fires the Pixel with the id the server chose", async function (assert) {
    await visit("/");
    const metaPixel = this.owner.lookup("service:meta-pixel");

    assert.true(
      metaPixel.trackServerPairedEvent("CompleteRegistration", SERVER_ID)
    );

    const calls = trackedEvents("CompleteRegistration");
    assert.strictEqual(calls.length, 1);
    assert.strictEqual(eventIdOf(calls[0]), SERVER_ID);
  });

  // The server half already exists. Posting a second copy through the mirror
  // endpoint would only be refused as a duplicate, so it must not be sent.
  test("does not mirror a second copy to the server", async function (assert) {
    await visit("/");
    const metaPixel = this.owner.lookup("service:meta-pixel");

    metaPixel.trackServerPairedEvent("CompleteRegistration", SERVER_ID);

    const registrations = mirrored.filter(
      (body) => body.get("event_name") === "CompleteRegistration"
    );
    assert.deepEqual(registrations, [], "no mirror POST for the registration");
  });

  // A marker that is not a well-formed id means something other than this
  // plugin put it in the page; firing on it would report a conversion Meta
  // could never match to the server copy.
  test("refuses an id it did not recognise", async function (assert) {
    await visit("/");
    const metaPixel = this.owner.lookup("service:meta-pixel");

    for (const bogus of ["", "not-an-event-id", "A".repeat(64), null]) {
      assert.false(
        metaPixel.trackServerPairedEvent("CompleteRegistration", bogus),
        `refused ${JSON.stringify(bogus)}`
      );
    }

    assert.deepEqual(
      trackedEventNames().filter((name) => name === "CompleteRegistration"),
      [],
      "nothing was reported as a registration"
    );
  });
});

acceptance("Meta Pixel | excluded group", function (needs) {
  needs.settings(SETTINGS);
  needs.site({ categories: CATEGORIES });
  // The server decides membership and serialises a boolean; the browser never
  // evaluates groups itself. The server also enforces this on every
  // server-side dispatch path, so this suppression is at source, not the only
  // thing standing between an excluded member and an event.
  needs.user({ meta_pixel_excluded: true });

  let mirrored;
  needs.hooks.beforeEach(function () {
    resetPixel();
    installRecordingFbq();
    mirrored = captureMirror();
  });
  needs.hooks.afterEach(function () {
    resetPixel();
  });

  test("fires no Pixel event and mirrors nothing", async function (assert) {
    await visit("/");
    await visit("/t/internationalization-localization/280");

    assert.deepEqual(trackedEventNames(), [], "no Pixel events");
    assert.deepEqual(mirrored, [], "and no Conversions API mirror");
  });

  test("holds no engagement state either", async function (assert) {
    await visit("/");
    const engagement = this.owner.lookup("service:meta-topic-engagement");

    engagement.startVisit(PUBLIC_TOPIC);
    engagement.tick(true, Date.now() + 600000);

    assert.strictEqual(engagement.topic, null, "no visit is started at all");
    assert.deepEqual(trackedEventNames(), []);
  });

  test("refuses even a server-paired registration", async function (assert) {
    await visit("/");
    const metaPixel = this.owner.lookup("service:meta-pixel");

    assert.false(metaPixel.enabled);
    assert.true(metaPixel.excludedByGroup);
    assert.false(
      metaPixel.trackServerPairedEvent("CompleteRegistration", "a".repeat(64))
    );
    assert.deepEqual(trackedEventNames(), []);
  });
});

acceptance("Meta Pixel | not in an excluded group", function (needs) {
  needs.settings(SETTINGS);
  needs.site({ categories: CATEGORIES });
  needs.user({ meta_pixel_excluded: false });

  needs.hooks.beforeEach(function () {
    resetPixel();
    installRecordingFbq();
    captureMirror();
  });
  needs.hooks.afterEach(function () {
    resetPixel();
  });

  test("is tracked normally", async function (assert) {
    await visit("/");

    assert.true(this.owner.lookup("service:meta-pixel").enabled);
    assert.true(trackedEvents("PageView").length > 0);
  });
});

acceptance("Meta Pixel | disabled", function (needs) {
  needs.settings({ ...SETTINGS, discourse_meta_pixel_enabled: false });
  needs.site({ categories: CATEGORIES });

  needs.hooks.beforeEach(function () {
    resetPixel();
    installRecordingFbq();
    // Every module needs the mirror endpoint stubbed: an unhandled POST is a
    // global error that aborts the whole run, not a single test failure.
    captureMirror();
  });
  needs.hooks.afterEach(function () {
    resetPixel();
  });

  test("sends nothing at all", async function (assert) {
    await visit("/t/internationalization-localization/280");

    assert.deepEqual(trackedEventNames(), []);
  });
});

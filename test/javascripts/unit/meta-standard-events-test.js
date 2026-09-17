import { setupTest } from "ember-qunit";
import { module, test } from "qunit";
import { MIRRORED_EVENTS } from "discourse/plugins/discourse-meta-pixel-capi/discourse/lib/meta-eligibility";
import {
  fbqMethodFor,
  isStandardEvent,
  STANDARD_EVENTS,
} from "discourse/plugins/discourse-meta-pixel-capi/discourse/lib/meta-standard-events";

module("Unit | Meta | standard events", function (hooks) {
  setupTest(hooks);

  test("the events Meta defines go through track", function (assert) {
    for (const name of STANDARD_EVENTS) {
      assert.strictEqual(fbqMethodFor(name), "track", name);
    }
  });

  test("this plugin's own events go through trackCustom", function (assert) {
    for (const name of ["TopicEngaged", "TopicCreated", "ReplyCreated"]) {
      assert.false(isStandardEvent(name), `${name} is not a standard event`);
      assert.strictEqual(fbqMethodFor(name), "trackCustom", name);
    }
  });

  test("the events the browser mirrors are classified", function (assert) {
    // A name the Pixel would warn about is a name sent the wrong way, so every
    // event this plugin can fire from the browser has to land deliberately on
    // one side or the other rather than by accident.
    for (const name of MIRRORED_EVENTS) {
      const method = fbqMethodFor(name);
      assert.true(
        method === "track" || method === "trackCustom",
        `${name} -> ${method}`
      );
    }

    assert.strictEqual(fbqMethodFor("PageView"), "track");
    assert.strictEqual(fbqMethodFor("ViewContent"), "track");
    assert.strictEqual(fbqMethodFor("Search"), "track");
    assert.strictEqual(fbqMethodFor("TopicEngaged"), "trackCustom");
  });

  test("an unknown or malformed name is treated as custom", function (assert) {
    for (const name of ["", null, undefined, "pageview", "Whatever"]) {
      assert.strictEqual(
        fbqMethodFor(name),
        "trackCustom",
        JSON.stringify(name)
      );
    }
  });
});

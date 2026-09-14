import { setupTest } from "ember-qunit";
import { module, test } from "qunit";
import {
  EVENT_ID_PATTERN,
  generateEventId,
  isValidEventId,
} from "discourse/plugins/discourse-meta-pixel-capi/discourse/lib/meta-event-id";

module("Unit | Meta | event id", function (hooks) {
  setupTest(hooks);

  test("generates the shape the server endpoint enforces", function (assert) {
    for (let i = 0; i < 100; i++) {
      const id = generateEventId();
      assert.true(EVENT_ID_PATTERN.test(id), `${id} is 32 lowercase hex chars`);
    }
  });

  test("generates unique ids", function (assert) {
    const ids = new Set();
    for (let i = 0; i < 2000; i++) {
      ids.add(generateEventId());
    }
    assert.strictEqual(ids.size, 2000, "no collisions");
  });

  test("validation refuses anything it did not shape", function (assert) {
    assert.false(isValidEventId(""));
    assert.false(isValidEventId(null));
    assert.false(isValidEventId("A".repeat(32)), "upper case");
    assert.false(isValidEventId("a".repeat(31)), "too short");
    assert.false(isValidEventId("a".repeat(33)), "too long");
    assert.false(isValidEventId("g".repeat(32)), "not hex");
    assert.false(isValidEventId("../../etc/passwd"));
  });
});

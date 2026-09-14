import { setupTest } from "ember-qunit";
import { module, test } from "qunit";
import {
  EXCLUSION,
  isSensitiveRoute,
  MIRRORED_EVENTS,
  topicExclusion,
} from "discourse/plugins/discourse-meta-pixel-capi/discourse/lib/meta-eligibility";

const CATEGORIES = [
  { id: 4, slug: "general", read_restricted: false },
  { id: 9, slug: "staff", read_restricted: true },
];

const options = {
  findCategoryById: (id) => CATEGORIES.find((c) => c.id === id) ?? null,
};

module("Unit | Meta | eligibility | topics", function (hooks) {
  setupTest(hooks);

  test("a public topic is eligible", function (assert) {
    assert.strictEqual(
      topicExclusion({ id: 1, archetype: "regular", category_id: 4 }, options),
      EXCLUSION.NONE
    );
  });

  test("a private message is always excluded", function (assert) {
    assert.strictEqual(
      topicExclusion({ id: 1, archetype: "private_message" }, options),
      EXCLUSION.PRIVATE_MESSAGE
    );
  });

  test("the private message rule cannot be switched off", function (assert) {
    assert.strictEqual(
      topicExclusion(
        { id: 1, archetype: "private_message" },
        { ...options, publicContentOnly: false }
      ),
      EXCLUSION.PRIVATE_MESSAGE,
      "checked before the public-content-only setting is consulted"
    );
  });

  test("restricted content is excluded", function (assert) {
    assert.strictEqual(
      topicExclusion({ id: 1, archetype: "regular", category_id: 9 }, options),
      EXCLUSION.RESTRICTED
    );
  });

  test("fails closed on incomplete data", function (assert) {
    assert.strictEqual(topicExclusion(null, options), EXCLUSION.NOT_LOADED);
    assert.strictEqual(
      topicExclusion({ id: 1, category_id: 4 }, options),
      EXCLUSION.NOT_LOADED,
      "archetype not loaded"
    );
    assert.strictEqual(
      topicExclusion(
        { id: 1, archetype: "regular", category_id: 404 },
        options
      ),
      EXCLUSION.NOT_LOADED,
      "category cannot be resolved"
    );
  });

  test("a login-required forum excludes everything", function (assert) {
    assert.strictEqual(
      topicExclusion(
        { id: 1, archetype: "regular", category_id: 4 },
        { ...options, loginRequired: true }
      ),
      EXCLUSION.RESTRICTED
    );
  });
});

module("Unit | Meta | eligibility | routes", function (hooks) {
  setupTest(hooks);

  test("sensitive routes are refused", function (assert) {
    [
      "/admin",
      "/review",
      "/my/messages",
      "/u/alice/messages",
      "/u/alice/preferences/security",
      "/u/password-reset/tok",
      "/u/email-login/tok",
      "/invites/tok",
      "/auth/facebook/callback",
    ].forEach((url) => {
      assert.true(isSensitiveRoute({ url }), `${url} refused`);
    });
  });

  test("lookalike public routes are allowed", function (assert) {
    ["/latest", "/t/a/1", "/c/reviews/12", "/tags/c/admin", "/u/alice"].forEach(
      (url) => {
        assert.false(isSensitiveRoute({ url }), `${url} allowed`);
      }
    );
  });

  test("route names are checked independently of the path", function (assert) {
    assert.true(isSensitiveRoute({ url: "/", routeName: "adminPlugins.show" }));
    assert.false(isSensitiveRoute({ url: "/", routeName: "discovery.latest" }));
  });

  test("only four events may be mirrored", function (assert) {
    assert.deepEqual(MIRRORED_EVENTS, [
      "PageView",
      "ViewContent",
      "Search",
      "TopicEngaged",
    ]);
  });
});

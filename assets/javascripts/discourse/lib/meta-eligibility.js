/**
 * Browser-side eligibility.
 *
 * This is the first of two gates. The server re-checks every topic with an
 * anonymous `Guardian` before anything reaches the Conversions API, so this
 * layer exists to stop the *Pixel* firing — which the server cannot do,
 * because by then the browser has already sent it.
 *
 * The rule is that an excluded page produces **no event**, not an event with
 * the fields removed. A parameter-free `ViewContent` on a private message
 * still tells Meta that someone read a private message, and when.
 *
 * Pure functions over plain data, so the rules can be tested exhaustively.
 */

export const MIRRORED_EVENTS = Object.freeze([
  "PageView",
  "ViewContent",
  "Search",
  "TopicEngaged",
]);

export const EXCLUSION = Object.freeze({
  NONE: "none",
  PRIVATE_MESSAGE: "private_message",
  RESTRICTED: "restricted",
  SENSITIVE_ROUTE: "sensitive_route",
  NOT_LOADED: "not_loaded",
});

/**
 * Routes that must never produce a Meta event.
 *
 * Matched against the pathname only, anchored, so a tag or category whose name
 * happens to be "admin" or "review" is unaffected.
 */
const SENSITIVE_PATH_PATTERNS = Object.freeze([
  /^\/admin(\/|$)/,
  /^\/review(\/|$)/,
  /^\/safe-mode(\/|$)/,
  /^\/my\//,
  /^\/u\/[^/]+\/messages(\/|$)/,
  /^\/u\/[^/]+\/preferences(\/|$)/,
  /^\/topics\/private-messages(\/|$)/,
  /^\/session\//,
  /^\/u\/password-reset(\/|$)/,
  /^\/u\/activate-account(\/|$)/,
  /^\/u\/email-login(\/|$)/,
  /^\/u\/confirm-/,
  /^\/invites\//,
  /^\/associate\//,
  /^\/auth\//,
]);

/**
 * Ember route name prefixes covering the same ground, so a route reached
 * without a matching path still fails closed.
 */
const SENSITIVE_ROUTE_PREFIXES = Object.freeze([
  "admin",
  "adminPlugins",
  "review",
  "userPrivateMessages",
  "preferences",
  "user.preferences",
  "associateAccount",
  "account-created",
  "email-login",
  "invites",
  "password-reset",
  "activate-account",
  "confirm-new-email",
  "confirm-old-email",
  "safe-mode",
]);

function pathnameOf(url) {
  if (typeof url !== "string" || url.length === 0) {
    return "/";
  }
  try {
    return new URL(url, "https://placeholder.invalid").pathname;
  } catch {
    return "/";
  }
}

function stripBasePath(pathname, basePath) {
  if (!basePath || basePath === "/") {
    return pathname;
  }
  const normalized = basePath.endsWith("/") ? basePath.slice(0, -1) : basePath;
  if (pathname === normalized) {
    return "/";
  }
  if (pathname.startsWith(normalized + "/")) {
    return pathname.slice(normalized.length);
  }
  return pathname;
}

export function isSensitiveRoute({ url, routeName, basePath = "/" } = {}) {
  if (routeName) {
    for (const prefix of SENSITIVE_ROUTE_PREFIXES) {
      if (routeName === prefix || routeName.startsWith(prefix + ".")) {
        return true;
      }
    }
  }

  const pathname = stripBasePath(pathnameOf(url), basePath);
  return SENSITIVE_PATH_PATTERNS.some((pattern) => pattern.test(pathname));
}

/**
 * Why this topic may not produce a content event, or `NONE`.
 *
 * Fails closed: a missing topic, an archetype that has not loaded, or a
 * category that cannot be resolved all count as excluded. Being unable to
 * prove something is public is not the same as it being public.
 */
export function topicExclusion(topic, options = {}) {
  const {
    loginRequired = false,
    publicContentOnly = true,
    findCategoryById = () => null,
  } = options;

  if (!topic) {
    return EXCLUSION.NOT_LOADED;
  }

  // Checked first and never opt-out-able.
  if (topic.archetype === "private_message") {
    return EXCLUSION.PRIVATE_MESSAGE;
  }

  if (!topic.archetype) {
    return EXCLUSION.NOT_LOADED;
  }

  if (!publicContentOnly) {
    return EXCLUSION.NONE;
  }

  if (loginRequired) {
    return EXCLUSION.RESTRICTED;
  }

  if (topic.category_id) {
    const category = topic.category ?? findCategoryById(topic.category_id);
    if (!category) {
      return EXCLUSION.NOT_LOADED;
    }
    if (category.read_restricted) {
      return EXCLUSION.RESTRICTED;
    }
  }

  return EXCLUSION.NONE;
}

export function topicIsEligible(topic, options) {
  return topicExclusion(topic, options) === EXCLUSION.NONE;
}

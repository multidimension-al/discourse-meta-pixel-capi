import { apiInitializer } from "discourse/lib/api";
import getURL from "discourse/lib/get-url";
import {
  currentTopicFromRouter,
  isTopicRoute,
} from "../lib/meta-current-topic";
import {
  EXCLUSION,
  isSensitiveRoute,
  topicExclusion,
} from "../lib/meta-eligibility";

/**
 * Wires Discourse application events to the Meta dispatcher.
 *
 * Only browser-originated events live here. `CompleteRegistration`,
 * `TopicCreated` and `ReplyCreated` are server-authoritative and are dispatched
 * from `DiscourseEvent` hooks in plugin.rb — firing them here as well would
 * create a second, differently-identified conversion for the same action.
 *
 * Nothing in this file calls `fbq`; everything goes through `service:meta-pixel`,
 * which owns the single event id shared by the Pixel and the Conversions API.
 */
export default apiInitializer((api) => {
  const owner = api.container;
  const metaPixel = owner.lookup("service:meta-pixel");

  if (!metaPixel.enabled) {
    return;
  }

  const siteSettings = owner.lookup("service:site-settings");
  const site = owner.lookup("service:site");
  const router = owner.lookup("service:router");
  const engagement = owner.lookup("service:meta-topic-engagement");

  const exclusionFor = (topic) =>
    topicExclusion(topic, {
      loginRequired: !!siteSettings.login_required,
      publicContentOnly: !!siteSettings.meta_pixel_public_content_only,
      findCategoryById: (id) => site?.categories?.find((c) => c.id === id),
    });

  let currentTopicId = null;

  // `page:changed` rather than `api.onPageChange`, because the latter narrows
  // the payload to `(url, title)` and drops `replacedOnlyQueryParams` and
  // `currentRouteName` — the fields needed to avoid counting a query-string
  // replacement as a navigation and to recognise a sensitive route.
  api.onAppEvent("page:changed", (data) => {
    const topic = isTopicRoute(data.currentRouteName)
      ? currentTopicFromRouter(router)
      : null;

    handlePageView(data, topic);
    handleTopicTransition(topic);
  });

  function handlePageView(data, topic) {
    // Discourse replaces the URL while a topic is scrolled and while a search
    // is refined; neither is a new page to a human.
    if (data.replacedOnlyQueryParams) {
      return;
    }

    if (
      isSensitiveRoute({
        url: data.url,
        routeName: data.currentRouteName,
        basePath: getURL("/"),
      })
    ) {
      return;
    }

    // A private message topic route looks identical to a public one, so this
    // has to be decided from the model rather than the path.
    if (topic && exclusionFor(topic) !== EXCLUSION.NONE) {
      return;
    }

    metaPixel.track("PageView", { path: pathOf(data.url) });
  }

  function handleTopicTransition(topic) {
    const topicId = topic?.id ?? null;

    if (topicId === currentTopicId) {
      return;
    }
    currentTopicId = topicId;

    if (!topic) {
      engagement.endVisit();
      return;
    }

    // ViewContent is about a specific piece of public content. An excluded
    // topic produces no event at all — not an event with the fields removed.
    if (exclusionFor(topic) === EXCLUSION.NONE) {
      metaPixel.track("ViewContent", {
        customData: {
          content_type: "topic",
          content_ids: [String(topic.id)],
          ...(topic.category_id
            ? {
                content_category: site?.categories?.find(
                  (c) => c.id === topic.category_id
                )?.slug,
              }
            : {}),
        },
        topicId: topic.id,
      });
    }

    // Starts a visit only for an eligible topic; the service re-checks.
    engagement.startVisit(topic);
  }

  // Full-page search only. The header search menu has no application event
  // reporting a completed search, and inferring one from keystrokes would fire
  // an event per character typed.
  api.onAppEvent("search:search_result_view", (data) => {
    // Paging through existing results is not a new search.
    if (data?.page && data.page > 1) {
      return;
    }

    // The query itself is deliberately not forwarded. A forum search box
    // routinely receives names, email addresses and health-related text, and
    // Meta does not need it to attribute a search event.
    metaPixel.track("Search", {
      customData: { content_type: "topic" },
      path: pathOf(window.location.pathname),
    });
  });

  // ---------------------------------------------------------------------
  // Registration
  // ---------------------------------------------------------------------
  //
  // Discourse's signup flow ends in a full page reload, so there is no live
  // callback to fire this from. Instead the server dispatched the Conversions
  // API copy during this render and rendered the event id it used; firing the
  // Pixel with the *same* id gives Meta a browser copy to deduplicate against,
  // and with it the browser identity signals a server-only conversion cannot
  // carry. Consumed with GETDEL server-side, so this cannot replay on reload.
  const registrationEventId = document.querySelector(
    "meta[name=discourse-meta-pixel-registration]"
  )?.content;

  if (registrationEventId) {
    metaPixel.trackServerPairedEvent(
      "CompleteRegistration",
      registrationEventId
    );
  }

  function pathOf(url) {
    if (typeof url !== "string" || url.length === 0) {
      return null;
    }
    try {
      const parsed = new URL(url, window.location.origin);
      return `${parsed.pathname}${parsed.search}`;
    } catch {
      return null;
    }
  }
});

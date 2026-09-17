import Service, { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import EmbedMode from "discourse/lib/embed-mode";
import { isTesting } from "discourse/lib/environment";
import { MIRRORED_EVENTS } from "../lib/meta-eligibility";
import { generateEventId, isValidEventId32Plus } from "../lib/meta-event-id";
import { fbqMethodFor } from "../lib/meta-standard-events";

const MIRROR_ENDPOINT = "/meta-pixel/events";

/**
 * The only thing in this plugin that calls `fbq`.
 *
 * Its whole reason for existing is the pairing in `track()`: one event id is
 * generated, given to the Pixel as `eventID`, and posted to the server as
 * `event_id`. Meta then recognises the browser and server copies as one
 * conversion. Any code path that generated its own id, or fired `fbq`
 * directly, would break deduplication silently — the events would arrive, they
 * would simply be counted twice.
 */
export default class MetaPixelService extends Service {
  @service siteSettings;

  diagnostics = {
    pixelEvents: 0,
    mirrored: 0,
    mirrorFailures: 0,
    suppressed: 0,
    lastEvent: null,
    pixelInitialized: false,
    pixelFailed: null,
  };

  get enabled() {
    if (!this.siteSettings.discourse_meta_pixel_enabled) {
      return false;
    }
    if (EmbedMode.enabled) {
      return false;
    }
    if (this.respectingDoNotTrack) {
      return false;
    }
    if (this.excludedByGroup) {
      return false;
    }
    return true;
  }

  /**
   * Whether this person's group membership excludes them entirely.
   *
   * Decided on the server, which also enforces it on every server-side
   * dispatch path — this getter suppresses the Pixel and the mirror at source,
   * it is not the only thing standing between an excluded member and an event.
   */
  get excludedByGroup() {
    return !!this.currentUser?.meta_pixel_excluded;
  }

  /**
   * Do Not Track is not a legal instruction and Meta does not honour it, but a
   * visitor who set it has expressed a preference and the plugin can act on it
   * cheaply. Off means the plugin sends nothing for that visitor at all —
   * neither Pixel nor the server mirror.
   */
  get respectingDoNotTrack() {
    if (!this.siteSettings.meta_pixel_respect_do_not_track) {
      return false;
    }
    if (typeof navigator === "undefined") {
      return false;
    }
    return (
      navigator.doNotTrack === "1" ||
      navigator.doNotTrack === "yes" ||
      window.doNotTrack === "1"
    );
  }

  get pixelEnabled() {
    return (
      this.enabled &&
      this.siteSettings.meta_pixel_pixel_enabled &&
      !!this.siteSettings.meta_pixel_dataset_id
    );
  }

  get debug() {
    return !!this.siteSettings.meta_pixel_debug_mode;
  }

  get fbqAvailable() {
    return typeof window !== "undefined" && typeof window.fbq === "function";
  }

  eventEnabled(eventName) {
    const setting = EVENT_SETTINGS[eventName];
    if (!setting) {
      return false;
    }
    return !!this.siteSettings[setting];
  }

  /**
   * Fire a mirrored event.
   *
   * One id, both destinations. The Pixel call happens first and synchronously
   * so it is never lost to a slow request; the server mirror is fire and
   * forget.
   *
   * @param {string} eventName one of MIRRORED_EVENTS
   * @param {object} options
   * @param {object} [options.customData] Pixel-side custom data
   * @param {number} [options.topicId] re-validated server-side before use
   * @param {string} [options.path] same-site path, re-validated server-side
   * @returns {string|null} the event id used, or null if nothing was sent
   */
  track(eventName, { customData = {}, topicId = null, path = null } = {}) {
    try {
      return this.#track(eventName, { customData, topicId, path });
    } catch (error) {
      // An advertising pixel must never surface as a broken forum action.
      this.diagnostics.pixelFailed = String(error?.message ?? error);
      this.#log("dispatch failed", { eventName, error });
      return null;
    }
  }

  #track(eventName, { customData, topicId, path }) {
    if (!this.enabled || !MIRRORED_EVENTS.includes(eventName)) {
      this.diagnostics.suppressed++;
      return null;
    }

    if (!this.eventEnabled(eventName)) {
      this.diagnostics.suppressed++;
      return null;
    }

    // Generated once. This value is the deduplication key.
    const eventId = generateEventId();

    if (this.pixelEnabled && this.fbqAvailable) {
      // `TopicEngaged` is not one of Meta's standard events, so it goes
      // through `trackCustom`. See lib/meta-standard-events.
      window.fbq(fbqMethodFor(eventName), eventName, customData, {
        eventID: eventId,
      });
      this.diagnostics.pixelEvents++;
    }

    this.diagnostics.lastEvent = eventName;

    this.#mirror(eventName, eventId, topicId, path);

    this.#log("tracked", { eventName, eventId, customData });

    return eventId;
  }

  /**
   * Hand the same event id to the server so its Conversions API copy
   * deduplicates against the Pixel event just fired.
   *
   * The body is intentionally tiny. The server derives the person, their IP,
   * their user agent and the `_fbp` / `_fbc` cookies from the real request,
   * and re-checks the topic's visibility itself — none of that is asserted
   * here, and the endpoint would reject it if it were.
   */
  #mirror(eventName, eventId, topicId, path) {
    if (!this.siteSettings.meta_pixel_capi_enabled) {
      return;
    }

    const data = { event_name: eventName, event_id: eventId };
    if (topicId) {
      data.topic_id = topicId;
    }
    if (path) {
      data.path = path;
    }

    // Deliberately not awaited: no forum interaction waits on this, and a
    // failure is recorded rather than surfaced.
    ajax(MIRROR_ENDPOINT, { type: "POST", data })
      .then(() => {
        this.diagnostics.mirrored++;
      })
      .catch(() => {
        this.diagnostics.mirrorFailures++;
      });
  }

  /**
   * Fire the Pixel half of an event whose id the **server** already chose.
   *
   * Used only for `CompleteRegistration`. The server dispatched the
   * Conversions API copy during this page's render, using a deterministic id
   * derived from the account; firing the Pixel with that same id gives Meta a
   * browser copy to deduplicate against, and with it the browser identity
   * signals (`_fbp`, `_fbc`, the real user agent) that a server-only
   * conversion has no way to carry.
   *
   * Deliberately does **not** mirror to the endpoint: the server half exists
   * already, and posting it again would just be refused as a duplicate.
   */
  trackServerPairedEvent(eventName, eventId, { customData = {} } = {}) {
    try {
      if (!this.enabled || !isValidEventId32Plus(eventId)) {
        this.diagnostics.suppressed++;
        return false;
      }
      if (!this.pixelEnabled || !this.fbqAvailable) {
        this.diagnostics.suppressed++;
        return false;
      }

      window.fbq(fbqMethodFor(eventName), eventName, customData, {
        eventID: eventId,
      });

      this.diagnostics.pixelEvents++;
      this.diagnostics.lastEvent = eventName;
      this.#log("tracked (server-paired)", { eventName, eventId });

      return true;
    } catch (error) {
      this.diagnostics.pixelFailed = String(error?.message ?? error);
      return false;
    }
  }

  #log(message, context) {
    if (!this.debug || isTesting()) {
      return;
    }
    // eslint-disable-next-line no-console
    console.debug(`[discourse-meta-pixel] ${message}`, context ?? "");
  }

  diagnosticsSnapshot() {
    return {
      enabled: this.enabled,
      excludedByGroup: this.excludedByGroup,
      pixelEnabled: this.pixelEnabled,
      fbqAvailable: this.fbqAvailable,
      respectingDoNotTrack: this.respectingDoNotTrack,
      ...this.diagnostics,
    };
  }
}

/**
 * Event name to site setting, for the events the browser can originate.
 *
 * The server-authoritative events (CompleteRegistration, TopicCreated,
 * ReplyCreated) are absent on purpose: the browser has no business firing
 * them, and their settings are consulted server-side.
 */
export const EVENT_SETTINGS = Object.freeze({
  PageView: "meta_pixel_track_page_view",
  ViewContent: "meta_pixel_track_view_content",
  Search: "meta_pixel_track_search",
  TopicEngaged: "meta_pixel_track_topic_engaged",
});

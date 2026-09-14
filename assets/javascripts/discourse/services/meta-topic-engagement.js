import Service, { service } from "@ember/service";
import { bind } from "discourse/lib/decorators";
import { isTesting } from "discourse/lib/environment";
import userPresent from "discourse/lib/user-presence";
import { EXCLUSION, topicExclusion } from "../lib/meta-eligibility";

const TICK_INTERVAL_MS = 1000;

// `userPresent` rejects a `userUnseenTime` below one minute, and a minute of
// no interaction is a fair definition of "stopped reading".
// `browserHiddenTime: 0` stops the clock the moment the tab is hidden.
const PRESENCE_OPTIONS = Object.freeze({
  userUnseenTime: 60000,
  browserHiddenTime: 0,
});

/**
 * Fires `TopicEngaged` once per topic visit, after enough *attentive* reading.
 *
 * Meta is an attribution and optimisation surface, not a telemetry sink, so
 * this deliberately sends one event with a meaningful threshold rather than the
 * 25/50/75/100 progress ladder the GA plugin reports. Thirty seconds of a tab
 * left open in the background is not engagement, which is why the clock is
 * gated on `userPresent()` rather than on wall time.
 *
 * At most one interval timer exists, and only while a topic is open.
 */
export default class MetaTopicEngagementService extends Service {
  @service metaPixel;
  @service site;
  @service siteSettings;

  topic = null;
  engagedMs = 0;
  fired = false;

  #interval = null;
  #pagehideAttached = false;

  willDestroy() {
    super.willDestroy(...arguments);
    this.#stopTimer();
    this.#detachPagehide();
    this.topic = null;
  }

  get thresholdSeconds() {
    return this.siteSettings.meta_pixel_topic_engaged_seconds || 30;
  }

  get engagedSeconds() {
    return Math.floor(this.engagedMs / 1000);
  }

  exclusionFor(topic) {
    return topicExclusion(topic, {
      loginRequired: !!this.siteSettings.login_required,
      publicContentOnly: !!this.siteSettings.meta_pixel_public_content_only,
      findCategoryById: (id) => this.site?.categories?.find((c) => c.id === id),
    });
  }

  /**
   * Enter a topic.
   *
   * An excluded topic — a private message above all — never becomes the
   * tracked topic, so no timer starts and there is no state that could later
   * produce an event for it.
   */
  startVisit(topic) {
    this.endVisit();

    if (!this.metaPixel.enabled || !topic?.id) {
      return;
    }

    if (this.exclusionFor(topic) !== EXCLUSION.NONE) {
      return;
    }

    this.topic = topic;
    this.engagedMs = 0;
    this.fired = false;
    this._lastTickAt = Date.now();

    this.#startTimer();
    this.#attachPagehide();
  }

  endVisit() {
    this.topic = null;
    this.engagedMs = 0;
    this.fired = false;
    this.#stopTimer();
  }

  /**
   * One second of the reading clock.
   *
   * Exposed rather than private so tests can advance it deterministically
   * instead of waiting on a real timer.
   */
  tick(present = userPresent(PRESENCE_OPTIONS), now = Date.now()) {
    if (!this.topic || this.fired) {
      return;
    }

    const elapsed = now - this._lastTickAt;
    this._lastTickAt = now;

    if (!present || elapsed <= 0) {
      return;
    }

    // A tab restored from sleep reports a huge delta; cap it so background
    // time cannot be banked as reading time.
    this.engagedMs += Math.min(elapsed, 2000);

    if (this.engagedSeconds < this.thresholdSeconds) {
      return;
    }

    this.fired = true;

    this.metaPixel.track("TopicEngaged", {
      customData: {
        content_type: "topic",
        content_ids: [String(this.topic.id)],
      },
      topicId: this.topic.id,
    });

    // The event is once per visit, so the timer has nothing left to do.
    this.#stopTimer();
  }

  #startTimer() {
    if (this.#interval || isTesting()) {
      return;
    }
    this.#interval = setInterval(() => this.tick(), TICK_INTERVAL_MS);
  }

  #stopTimer() {
    if (this.#interval) {
      clearInterval(this.#interval);
      this.#interval = null;
    }
  }

  #attachPagehide() {
    if (this.#pagehideAttached || typeof window === "undefined") {
      return;
    }
    window.addEventListener("pagehide", this.onPagehide);
    this.#pagehideAttached = true;
  }

  #detachPagehide() {
    if (!this.#pagehideAttached || typeof window === "undefined") {
      return;
    }
    window.removeEventListener("pagehide", this.onPagehide);
    this.#pagehideAttached = false;
  }

  @bind
  onPagehide() {
    this.endVisit();
  }
}

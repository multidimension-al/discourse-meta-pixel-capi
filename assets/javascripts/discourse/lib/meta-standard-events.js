/**
 * Choosing between `fbq('track')` and `fbq('trackCustom')`.
 *
 * Meta's base code has two entry points for events. `track` is for the events
 * Meta itself defines and reports on; `trackCustom` is for everything else.
 * Passing a name Meta does not know to `track` still records the event, but
 * `fbevents.js` logs:
 *
 *   [Meta Pixel] - You are sending a non-standard event 'TopicEngaged'. The
 *   preferred way to send these events is using trackCustom.
 *
 * — and, more to the point, an event sent the wrong way is not a first-class
 * custom conversion in Events Manager. The Conversions API makes no such
 * distinction, so only the browser half needs this: the server keeps sending
 * `event_name` verbatim, and the pair still deduplicates.
 *
 * Dependency-free on purpose, so the standalone Node suite can cover it.
 */

/**
 * Meta's standard events, as documented at
 * https://developers.facebook.com/docs/meta-pixel/reference#standard-events
 *
 * Anything absent here is a custom event by definition — including this
 * plugin's own `TopicEngaged`, `TopicCreated` and `ReplyCreated`.
 */
export const STANDARD_EVENTS = Object.freeze([
  "AddPaymentInfo",
  "AddToCart",
  "AddToWishlist",
  "CompleteRegistration",
  "Contact",
  "CustomizeProduct",
  "Donate",
  "FindLocation",
  "InitiateCheckout",
  "Lead",
  "PageView",
  "Purchase",
  "Schedule",
  "Search",
  "StartTrial",
  "SubmitApplication",
  "Subscribe",
  "ViewContent",
]);

const STANDARD_EVENT_SET = new Set(STANDARD_EVENTS);

export function isStandardEvent(eventName) {
  return STANDARD_EVENT_SET.has(eventName);
}

/**
 * The `fbq` method an event name should be sent through.
 *
 * @param {string} eventName
 * @returns {"track"|"trackCustom"}
 */
export function fbqMethodFor(eventName) {
  return isStandardEvent(eventName) ? "track" : "trackCustom";
}

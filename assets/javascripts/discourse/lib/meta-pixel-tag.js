/**
 * Loading and initialising the Meta Pixel.
 *
 * The plugin owns the base code outright: it is injected once, initialised
 * once, and survives SPA navigation because Discourse never reloads the
 * document. There is no theme component involved, no core template is
 * replaced, and no inline snippet is rendered server-side.
 *
 * The standard Meta base code is reproduced faithfully — the `fbq` stub with
 * its `callMethod`/`queue` shape is what allows events fired before
 * `fbevents.js` finishes downloading to be replayed once it arrives, so
 * simplifying it would silently drop early events.
 *
 * `fbq('init', ...)` is called exactly once. Calling it again re-registers the
 * dataset and produces duplicate automatic events.
 */

export const PIXEL_SCRIPT_URL =
  "https://connect.facebook.net/en_US/fbevents.js";
const PIXEL_SCRIPT_MARKER = "data-discourse-meta-pixel";

/**
 * Install the `fbq` stub, inject the loader and initialise the dataset.
 *
 * Idempotent, and never throws: a failure to load an advertising pixel must
 * not take a forum page with it.
 *
 * @param {object} options
 * @param {string} options.pixelId
 * @param {Window} [options.win]
 * @param {Document} [options.doc]
 * @param {boolean} [options.injectScript] false in tests, where fetching a
 *   real third-party script would be slow and pointless.
 */
export function installPixel({
  pixelId,
  win = typeof window !== "undefined" ? window : undefined,
  doc = typeof document !== "undefined" ? document : undefined,
  injectScript = true,
} = {}) {
  if (!win || !doc) {
    return { ok: false, reason: "no_dom" };
  }
  if (!pixelId) {
    return { ok: false, reason: "missing_pixel_id" };
  }
  if (win.__discourseMetaPixelInstalled) {
    return { ok: true, reason: "already_installed", alreadyInstalled: true };
  }

  try {
    if (!win.fbq) {
      const fbq = function () {
        const args = arguments;
        if (fbq.callMethod) {
          fbq.callMethod.apply(fbq, args);
        } else {
          // Queued until fbevents.js loads and drains it. Dropping this is how
          // early events go missing.
          fbq.queue.push(args);
        }
      };

      win.fbq = fbq;
      win._fbq = win._fbq || fbq;
      fbq.push = fbq;
      fbq.loaded = true;
      fbq.version = "2.0";
      fbq.queue = [];
    }

    if (injectScript && !doc.querySelector(`script[${PIXEL_SCRIPT_MARKER}]`)) {
      const script = doc.createElement("script");
      script.async = true;
      script.src = PIXEL_SCRIPT_URL;
      script.setAttribute(PIXEL_SCRIPT_MARKER, "true");
      doc.head.appendChild(script);
    }

    // Once, and only once.
    win.fbq("init", pixelId);

    win.__discourseMetaPixelInstalled = true;

    return { ok: true, reason: "installed" };
  } catch (error) {
    return { ok: false, reason: "exception", error };
  }
}

export function pixelScriptCount(doc = document) {
  return doc.querySelectorAll(`script[${PIXEL_SCRIPT_MARKER}]`).length;
}

/** Test-only teardown; the Pixel installs once per page load in production. */
export function resetPixelForTesting(win = window, doc = document) {
  delete win.__discourseMetaPixelInstalled;
  delete win.fbq;
  delete win._fbq;
  doc
    .querySelectorAll(`script[${PIXEL_SCRIPT_MARKER}]`)
    .forEach((el) => el.remove());
}

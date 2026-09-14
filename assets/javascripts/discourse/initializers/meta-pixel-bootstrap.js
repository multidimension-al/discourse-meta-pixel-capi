import { isTesting } from "discourse/lib/environment";
import { installPixel } from "../lib/meta-pixel-tag";

/**
 * Installs the Meta Pixel base code, once per page load.
 *
 * Unlike the Google tag in the sibling GA plugin, there is no ordering
 * constraint here: Discourse core has no Meta integration to collide with, so
 * this does not need to run after any particular core initializer. It is a
 * plain initializer rather than an `apiInitializer` only because it needs to
 * run before any event producer can call `fbq`.
 */
export default {
  name: "meta-pixel-bootstrap",

  initialize(owner) {
    const siteSettings = owner.lookup("service:site-settings");

    if (!siteSettings.discourse_meta_pixel_enabled) {
      return;
    }
    if (!siteSettings.meta_pixel_pixel_enabled) {
      return;
    }

    const pixel = owner.lookup("service:meta-pixel");

    // Covers embed mode and the Do Not Track preference, so neither the
    // loader nor the base code is injected for a visitor who is not tracked.
    if (!pixel.enabled) {
      return;
    }

    const pixelId = siteSettings.meta_pixel_dataset_id;
    if (!pixelId) {
      pixel.diagnostics.pixelFailed = "missing_pixel_id";
      return;
    }

    const result = installPixel({ pixelId, injectScript: !isTesting() });

    if (result.ok) {
      pixel.diagnostics.pixelInitialized = true;
      pixel.diagnostics.pixelFailed = null;
    } else {
      pixel.diagnostics.pixelInitialized = false;
      pixel.diagnostics.pixelFailed = result.reason;
    }
  },
};

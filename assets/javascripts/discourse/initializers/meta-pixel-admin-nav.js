import getURL from "discourse/lib/get-url";
import { withPluginApi } from "discourse/lib/plugin-api";

const PLUGIN_ID = "discourse-meta-pixel-capi";
const DIAGNOSTICS_ROUTE = "adminPlugins.show.discourse-meta-pixel-diagnostics";
const DIAGNOSTICS_URL =
  "/admin/plugins/discourse-meta-pixel-capi/meta-pixel-diagnostics";

/**
 * Registers the "Diagnostics" tab, but only once the router confirms the route
 * behind it resolves.
 *
 * Core's adminPlugins.show.index route unconditionally calls replaceWith() on
 * the first non-settings nav entry, so an entry whose route is missing is not
 * a missing tab — it throws "There is no route named ..." on every visit to
 * the plugin's admin page. The route can be absent even when this module has
 * loaded (mapRoutes silently drops a map whose resource is not yet in the
 * tree, and admin routes arrive in a separately loaded chunk), so both edges
 * of a transition are watched until it resolves.
 */
export default {
  name: "meta-pixel-admin-nav",

  initialize(container) {
    const currentUser = container.lookup("service:current-user");
    if (!currentUser?.admin) {
      return;
    }

    const router = container.lookup("service:router");
    if (!router) {
      return;
    }

    const register = () => {
      if (!this.routeExists(router)) {
        return;
      }

      router.off("routeWillChange", register);
      router.off("routeDidChange", register);

      withPluginApi((api) => {
        api.addAdminPluginConfigurationNav(PLUGIN_ID, [
          {
            label: "discourse_meta_pixel.admin.diagnostics",
            route: DIAGNOSTICS_ROUTE,
          },
        ]);
      });
    };

    router.on("routeWillChange", register);
    router.on("routeDidChange", register);
  },

  routeExists(router) {
    try {
      return (
        router.recognize(getURL(DIAGNOSTICS_URL))?.name === DIAGNOSTICS_ROUTE
      );
    } catch {
      return false;
    }
  },
};

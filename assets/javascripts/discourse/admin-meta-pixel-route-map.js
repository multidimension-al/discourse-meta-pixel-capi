// Adds the plugin's Diagnostics page under core's adminPlugins.show route.
//
// The route NAME and the PATH are both plugin-scoped. adminPlugins.show is
// mounted at /plugins/:plugin_id, so every plugin adding a child shares one
// namespace: a child with `path: "diagnostics"` would claim
// /admin/plugins/:plugin_id/diagnostics site-wide, and two plugins claiming
// the same path means one silently loses its whole route map.
//
// Discourse reads only `resource` and `map`; `path` here is inert for a map
// targeting an existing resource, and is kept at the value core and the
// bundled plugins use so it does not read as meaningful configuration.
export default {
  resource: "admin.adminPlugins.show",

  path: "/plugins",

  map() {
    this.route("discourse-meta-pixel-diagnostics", {
      path: "meta-pixel-diagnostics",
    });
  },
};

/**
 * Resolve the topic model for the route currently displayed.
 *
 * `RouterService#currentRoute` exposes each active route's resolved model as
 * `attributes`, but the leaf on a topic route is usually `topic.fromParamsNear`
 * whose attributes are not the topic — so walk up to the first ancestor whose
 * model looks like one.
 *
 * Requiring `archetype` is deliberate: it is the field eligibility depends on,
 * and a model without it would be classified on incomplete data.
 */
export function currentTopicFromRouter(router) {
  let route = router?.currentRoute;

  while (route) {
    const model = route.attributes;
    if (model && model.id && typeof model.archetype === "string") {
      return model;
    }
    route = route.parent;
  }

  return null;
}

export function isTopicRoute(routeName) {
  return typeof routeName === "string" && routeName.split(".")[0] === "topic";
}

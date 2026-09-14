import { ajax } from "discourse/lib/ajax";
import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsShowDiscourseMetaPixelDiagnostics extends DiscourseRoute {
  model() {
    return ajax("/admin/plugins/discourse-meta-pixel-capi/diagnostics.json");
  }

  setupController(controller, model) {
    controller.setProperties({ model, data: model });
    controller.refreshBrowserState();
    controller.loadDeliveries();
  }
}

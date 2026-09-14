import { tracked } from "@glimmer/tracking";
import Controller from "@ember/controller";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";

export default class AdminPluginsShowDiscourseMetaPixelDiagnosticsController extends Controller {
  @service metaPixel;

  @tracked data = null;
  @tracked deliveries = null;
  @tracked browserState = null;
  @tracked loading = false;

  /**
   * The server knows the configuration and the delivery queue; only the
   * browser knows whether the Pixel actually loaded. Both halves are needed to
   * answer "is this working".
   */
  @action
  refreshBrowserState() {
    this.browserState = this.metaPixel.diagnosticsSnapshot();
  }

  get warnings() {
    return (this.data?.warnings || []).map((warning) => ({
      ...warning,
      message: i18n(
        `discourse_meta_pixel.admin.warnings.${warning.key}`,
        warning
      ),
      className:
        warning.severity === "error"
          ? "alert alert-error"
          : "alert alert-warning",
    }));
  }

  get events() {
    return Object.entries(this.data?.enabled_events || {}).map(
      ([name, enabled]) => ({ name, enabled })
    );
  }

  get statusCounts() {
    return Object.entries(this.data?.counts || {}).map(([status, count]) => ({
      status,
      count,
    }));
  }

  @action
  async reload() {
    this.loading = true;
    try {
      this.data = await ajax(
        "/admin/plugins/discourse-meta-pixel-capi/diagnostics.json"
      );
      this.refreshBrowserState();
      await this.loadDeliveries();
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.loading = false;
    }
  }

  @action
  async loadDeliveries() {
    try {
      const result = await ajax(
        "/admin/plugins/discourse-meta-pixel-capi/deliveries.json",
        { data: { page: 1, per_page: 25 } }
      );
      this.deliveries = result.deliveries;
    } catch (error) {
      popupAjaxError(error);
    }
  }
}

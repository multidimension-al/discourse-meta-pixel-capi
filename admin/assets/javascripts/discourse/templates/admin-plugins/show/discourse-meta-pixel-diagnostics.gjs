import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";

const yesNo = (value) =>
  value
    ? i18n("discourse_meta_pixel.admin.yes")
    : i18n("discourse_meta_pixel.admin.no");

export default <template>
  <div class="meta-pixel-admin">
    {{#each @controller.warnings as |warning|}}
      <div class={{warning.className}}>{{warning.message}}</div>
    {{/each}}

    <section class="meta-pixel-admin__section">
      <h3>{{i18n "discourse_meta_pixel.admin.configuration"}}</h3>

      <div class="meta-pixel-admin__row">
        <strong>{{i18n "discourse_meta_pixel.admin.enabled"}}:</strong>
        {{yesNo @controller.data.enabled}}
      </div>

      <div class="meta-pixel-admin__row">
        <strong>{{i18n "discourse_meta_pixel.admin.pixel_enabled"}}:</strong>
        {{yesNo @controller.data.pixel_enabled}}
      </div>

      <div class="meta-pixel-admin__row">
        <strong>{{i18n "discourse_meta_pixel.admin.dataset_id"}}:</strong>
        {{#if @controller.data.dataset_id}}
          <code>{{@controller.data.dataset_id}}</code>
        {{else}}
          <em>{{i18n "discourse_meta_pixel.admin.not_configured"}}</em>
        {{/if}}
      </div>

      <div class="meta-pixel-admin__row">
        <strong>{{i18n "discourse_meta_pixel.admin.capi_enabled"}}:</strong>
        {{yesNo @controller.data.capi_enabled}}
      </div>

      <div class="meta-pixel-admin__row">
        <strong>{{i18n "discourse_meta_pixel.admin.access_token"}}:</strong>
        {{yesNo @controller.data.access_token_configured}}
        <span class="meta-pixel-admin__hint">{{i18n
            "discourse_meta_pixel.admin.access_token_hint"
          }}</span>
      </div>

      <div class="meta-pixel-admin__row">
        <strong>{{i18n "discourse_meta_pixel.admin.graph_version"}}:</strong>
        <code>{{@controller.data.graph_api_version}}</code>
      </div>

      <div class="meta-pixel-admin__row">
        <strong>{{i18n "discourse_meta_pixel.admin.test_mode"}}:</strong>
        {{yesNo @controller.data.test_event_code_configured}}
      </div>

      <div class="meta-pixel-admin__row">
        <strong>{{i18n "discourse_meta_pixel.admin.matching"}}:</strong>
        {{i18n "discourse_meta_pixel.admin.email_matching"}}
        {{yesNo @controller.data.enhanced_email_matching}}
        &middot;
        {{i18n "discourse_meta_pixel.admin.external_id_matching"}}
        {{yesNo @controller.data.external_id_matching}}
      </div>
    </section>

    <section class="meta-pixel-admin__section">
      <h3>{{i18n "discourse_meta_pixel.admin.browser_state"}}</h3>

      {{#if @controller.browserState.excludedByGroup}}
        <div class="meta-pixel-admin__row">
          <strong>{{i18n
              "discourse_meta_pixel.admin.excluded_by_group"
            }}</strong>
        </div>
      {{/if}}

      <div class="meta-pixel-admin__row">
        <strong>{{i18n
            "discourse_meta_pixel.admin.pixel_initialized"
          }}:</strong>
        {{yesNo @controller.browserState.pixelInitialized}}
        {{#if @controller.browserState.pixelFailed}}
          <span
            class="meta-pixel-admin__error"
          >({{@controller.browserState.pixelFailed}})</span>
        {{/if}}
      </div>

      <div class="meta-pixel-admin__row">
        <strong>{{i18n "discourse_meta_pixel.admin.fbq_available"}}:</strong>
        {{yesNo @controller.browserState.fbqAvailable}}
      </div>

      <div class="meta-pixel-admin__row">
        <strong>{{i18n "discourse_meta_pixel.admin.pixel_events"}}:</strong>
        {{@controller.browserState.pixelEvents}}
        &middot;
        {{i18n "discourse_meta_pixel.admin.mirrored"}}
        {{@controller.browserState.mirrored}}
        &middot;
        {{i18n "discourse_meta_pixel.admin.mirror_failures"}}
        {{@controller.browserState.mirrorFailures}}
      </div>
    </section>

    <section class="meta-pixel-admin__section">
      <h3>{{i18n "discourse_meta_pixel.admin.delivery"}}</h3>

      {{#each @controller.statusCounts as |entry|}}
        <div class="meta-pixel-admin__row">
          <strong>{{entry.status}}:</strong>
          {{entry.count}}
        </div>
      {{/each}}

      <div class="meta-pixel-admin__row">
        <strong>{{i18n "discourse_meta_pixel.admin.retention"}}:</strong>
        {{@controller.data.retention_days}}
      </div>

      {{#if @controller.data.last_success}}
        <div class="meta-pixel-admin__row">
          <strong>{{i18n "discourse_meta_pixel.admin.last_success"}}:</strong>
          {{@controller.data.last_success.event_name}}
          <code>{{@controller.data.last_success.event_id}}</code>
          {{@controller.data.last_success.last_attempted_at}}
        </div>
      {{/if}}

      {{#if @controller.data.last_failure}}
        <div class="meta-pixel-admin__row">
          <strong>{{i18n "discourse_meta_pixel.admin.last_failure"}}:</strong>
          {{@controller.data.last_failure.event_name}}
          <code>{{@controller.data.last_failure.event_id}}</code>
          <span
            class="meta-pixel-admin__error"
          >{{@controller.data.last_failure.last_error}}</span>
        </div>
      {{/if}}
    </section>

    {{#if @controller.deliveries}}
      <section class="meta-pixel-admin__section">
        <h3>{{i18n "discourse_meta_pixel.admin.recent"}}</h3>
        <table class="meta-pixel-admin__deliveries">
          <thead>
            <tr>
              <th>{{i18n "discourse_meta_pixel.admin.event"}}</th>
              <th>{{i18n "discourse_meta_pixel.admin.event_id"}}</th>
              <th>{{i18n "discourse_meta_pixel.admin.source"}}</th>
              <th>{{i18n "discourse_meta_pixel.admin.status"}}</th>
              <th>{{i18n "discourse_meta_pixel.admin.attempts"}}</th>
              <th>{{i18n "discourse_meta_pixel.admin.error"}}</th>
            </tr>
          </thead>
          <tbody>
            {{#each @controller.deliveries as |delivery|}}
              <tr>
                <td>{{delivery.event_name}}</td>
                <td><code>{{delivery.event_id}}</code></td>
                <td>{{delivery.source}}</td>
                <td>{{delivery.status}}</td>
                <td>{{delivery.attempts}}</td>
                <td>{{delivery.last_error}}</td>
              </tr>
            {{/each}}
          </tbody>
        </table>
      </section>
    {{/if}}

    <section class="meta-pixel-admin__section">
      <h3>{{i18n "discourse_meta_pixel.admin.events"}}</h3>
      <table class="meta-pixel-admin__deliveries">
        <tbody>
          {{#each @controller.events as |event|}}
            <tr>
              <td><code>{{event.name}}</code></td>
              <td>{{yesNo event.enabled}}</td>
            </tr>
          {{/each}}
        </tbody>
      </table>
    </section>

    <section class="meta-pixel-admin__section">
      <DButton
        @label="discourse_meta_pixel.admin.reload"
        @action={{@controller.reload}}
        @disabled={{@controller.loading}}
      />
    </section>
  </div>
</template>

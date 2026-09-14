# frozen_string_literal: true

module DiscourseMetaPixel
  class AdminDiagnosticsController < ::Admin::AdminController
    requires_plugin DiscourseMetaPixel::PLUGIN_NAME

    def index
      render json: Diagnostics.payload
    end

    # Recent delivery rows, for finding a specific conversion in Events
    # Manager. Only the fields Diagnostics#summarize permits — never a payload,
    # never matching data, and never the access token.
    def deliveries
      page = [params[:page].to_i, 1].max
      per_page = [[params[:per_page].to_i, 1].max, 50].min

      scope = Delivery.order(created_at: :desc)
      scope = scope.where(status: Delivery.statuses[params[:status]]) if Delivery.statuses.key?(
        params[:status],
      )

      total = scope.count
      rows = scope.limit(per_page).offset((page - 1) * per_page)

      render json: {
               deliveries: rows.map { |d| Diagnostics.summarize(d).merge(status: d.status) },
               meta: {
                 page: page,
                 per_page: per_page,
                 total_count: total,
               },
             }
    end
  end
end

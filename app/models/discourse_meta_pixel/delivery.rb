# frozen_string_literal: true

module DiscourseMetaPixel
  # One logical Conversions API conversion.
  #
  # ## What this table is for
  #
  # Two things, and deliberately nothing else:
  #
  # 1. **Idempotency.** A unique index on `(event_name, event_id)` means the
  #    same logical event cannot become two conversions in Meta, however many
  #    times a lifecycle hook fires or a job is replayed.
  # 2. **Observability.** An administrator can see what is queued, what
  #    succeeded, what is retrying and what gave up, without reading Sidekiq.
  #
  # ## What this table deliberately does not hold
  #
  # No payload blob. No email, hashed or otherwise. No IP address, user agent,
  # `_fbp` or `_fbc`.
  #
  # For server-authoritative events the payload is *reconstructed* from the
  # authoritative record (the user, topic or post) when the job runs, so there
  # is nothing personal to store in the first place. For browser-mirrored
  # events the transient matching data travels as job arguments in Redis and
  # never reaches Postgres, so it ages out with the job rather than living in a
  # table until someone remembers to prune it.
  #
  # `subject_type` and `subject_id` are how a server event finds its record
  # again. They are a foreign key, not personal data.
  class Delivery < ActiveRecord::Base
    self.table_name = "meta_pixel_deliveries"

    enum :status, { pending: 0, succeeded: 1, retrying: 2, failed: 3 }

    enum :source, { server: 0, browser: 1 }, prefix: :from

    validates :event_name, presence: true
    validates :event_id, presence: true
    validates :event_id, uniqueness: { scope: :event_name }

    # Claim this logical event, or discover that it is already claimed.
    #
    # Returns the record and whether this call created it. A caller that gets
    # `created: false` must not enqueue anything: the conversion already
    # exists, and sending it again is exactly the duplicate this table is here
    # to prevent.
    def self.claim(event_name:, event_id:, source:, subject_type: nil, subject_id: nil)
      record =
        create!(
          event_name: event_name,
          event_id: event_id,
          source: sources[source.to_s] || sources["server"],
          subject_type: subject_type,
          subject_id: subject_id,
          status: statuses[:pending],
          attempts: 0,
        )
      [record, true]
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      [find_by(event_name: event_name, event_id: event_id), false]
    end

    def record_attempt!(status:, error: nil)
      update!(
        status: status,
        attempts: attempts + 1,
        last_attempted_at: Time.zone.now,
        # A short classification, not Meta's prose. Long provider messages can
        # quote the payload back, and this column is shown to administrators.
        last_error: error&.to_s&.slice(0, 120),
      )
    end
  end
end

# == Schema Information
#
# Table name: meta_pixel_deliveries
#
#  id                :bigint           not null, primary key
#  attempts          :integer          default(0), not null
#  event_id          :string           not null
#  event_name        :string           not null
#  last_attempted_at :datetime
#  last_error        :string(120)
#  source            :integer          default("server"), not null
#  status            :integer          default("pending"), not null
#  subject_id        :bigint
#  subject_type      :string
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#
# Indexes
#
#  index_meta_pixel_deliveries_on_created_at            (created_at)
#  index_meta_pixel_deliveries_on_name_and_event_id     (event_name,event_id) UNIQUE
#  index_meta_pixel_deliveries_on_status                (status)
#

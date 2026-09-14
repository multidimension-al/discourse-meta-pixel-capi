# frozen_string_literal: true

class CreateMetaPixelDeliveries < ActiveRecord::Migration[7.2]
  def change
    create_table :meta_pixel_deliveries do |t|
      t.string :event_name, null: false
      t.string :event_id, null: false
      t.integer :status, null: false, default: 0
      t.integer :source, null: false, default: 0
      t.integer :attempts, null: false, default: 0
      t.datetime :last_attempted_at
      t.string :last_error, limit: 120
      # How a server-authoritative event finds its record again at delivery
      # time, so no payload needs to be stored.
      t.string :subject_type
      t.bigint :subject_id
      t.timestamps
    end

    # The idempotency boundary. Meta deduplicates on (event name, event id), so
    # this index makes the database enforce the same rule: one logical event
    # can only ever be enqueued once, no matter how often a lifecycle hook
    # fires or a job is replayed.
    add_index :meta_pixel_deliveries,
              %i[event_name event_id],
              unique: true,
              name: "index_meta_pixel_deliveries_on_name_and_event_id"

    add_index :meta_pixel_deliveries, :status
    add_index :meta_pixel_deliveries, :created_at
  end
end

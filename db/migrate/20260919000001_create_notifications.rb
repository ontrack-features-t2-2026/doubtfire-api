class CreateNotifications < ActiveRecord::Migration[8.0]
  def change
    create_table :notifications do |t|
      t.references :user, foreign_key: true, null: false

      # The category the user's preferences switch on, and the specific event
      # within it, so every notification can be traced back to its source.
      t.string :notification_type, null: false
      t.string :event, null: false

      # Text, not string. The model allows 500 characters and MariaDB stores a
      # string as VARCHAR(255).
      t.text :message, null: false
      t.string :link
      t.datetime :read_at

      # The record the event happened to. Optional, a general notification has
      # no target.
      t.references :notifiable, polymorphic: true, null: true, index: false

      # A non-null key identifies one event for one user, so a retried job
      # cannot raise it twice. 191 keeps the unique index inside utf8mb4 limits.
      t.string :dedupe_key, limit: 191
      t.datetime :delivered_at

      t.timestamps
    end

    add_index :notifications, [:user_id, :read_at]
    add_index :notifications, [:user_id, :event]
    add_index :notifications, [:notifiable_type, :notifiable_id]
    add_index :notifications, [:user_id, :dedupe_key], unique: true, name: 'index_notifications_on_user_and_dedupe_key'
  end
end

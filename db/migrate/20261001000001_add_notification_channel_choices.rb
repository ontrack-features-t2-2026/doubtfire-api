# frozen_string_literal: true

class AddNotificationChannelChoices < ActiveRecord::Migration[8.0]
  def up
    %w[task feedback portfolio].each do |category|
      %w[email push].each do |channel|
        column = "receive_#{category}_#{channel}_notifications"
        add_column :users, column, :boolean, default: true, null: false
      end
    end
    backfill_notification_choices
    add_column :users, :staff_digest_frequency, :string, default: 'off', null: false
  end

  def backfill_notification_choices
    %w[task feedback portfolio].each do |category|
      %w[email push].each do |channel|
        execute "UPDATE users SET receive_#{category}_#{channel}_notifications = COALESCE(receive_#{category}_notifications, FALSE)"
      end
    end
    # The old feedback switch also stopped digests. Preserve that existing
    # opt-out before making the cadence an independent user choice.
    execute "UPDATE users SET digest_frequency = 'off' WHERE receive_feedback_notifications = FALSE OR receive_feedback_notifications IS NULL"
  end

  def down
    remove_column :users, :staff_digest_frequency
    %w[task feedback portfolio].each do |category|
      execute "UPDATE users SET receive_#{category}_notifications = (receive_#{category}_email_notifications AND receive_#{category}_push_notifications)"
      %w[email push].each { |channel| remove_column :users, "receive_#{category}_#{channel}_notifications" }
    end
    # Deliberately retain digest opt-outs; a rollback must never opt users in.
  end
end

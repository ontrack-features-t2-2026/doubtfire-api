class CreateAdditionalNotificationEmails < ActiveRecord::Migration[8.0]
  def change
    create_table :additional_notification_emails do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string :email, null: false, limit: 254
      t.integer :verification_version, null: false, default: 0
      t.datetime :verification_sent_at
      t.datetime :verification_expires_at
      t.datetime :verified_at

      t.timestamps
    end

    create_table :additional_notification_email_audits do |t|
      t.references :user, null: false, foreign_key: true
      t.string :event, null: false, limit: 64

      t.timestamps
    end

    add_index :additional_notification_email_audits,
              %i[user_id event created_at],
              name: 'idx_additional_email_audits_user_event_time'
  end
end

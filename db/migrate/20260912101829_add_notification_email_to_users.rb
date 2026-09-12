# frozen_string_literal: true

class AddNotificationEmailToUsers < ActiveRecord::Migration[8.0]
  def change
    # Optional student-owned address for email notifications. When blank, delivery
    # falls back to the university-managed :email. Nullable, no default.
    add_column :users, :notification_email, :string
  end
end

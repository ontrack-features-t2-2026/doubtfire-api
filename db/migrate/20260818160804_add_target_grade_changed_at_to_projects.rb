# frozen_string_literal: true

class AddTargetGradeChangedAtToProjects < ActiveRecord::Migration[8.0]
  def up
    add_column :projects, :target_grade_changed_at, :datetime

    # Existing projects have no trustworthy record of when their current
    # target grade was selected. Backfill to now so existing snapshots fail
    # closed until the next successful aggregation run.
    execute <<~SQL
      UPDATE projects
      SET target_grade_changed_at = UTC_TIMESTAMP()
      WHERE target_grade_changed_at IS NULL
    SQL

    change_column_null :projects, :target_grade_changed_at, false
  end

  def down
    remove_column :projects, :target_grade_changed_at
  end
end

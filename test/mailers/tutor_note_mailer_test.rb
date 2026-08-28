require 'test_helper'

class TutorNoteMailerTest < ActionMailer::TestCase
  # BGW-21: a tutor note email must send staff to the marking inbox for the
  # student it is about, not the student-facing project dashboard with a
  # `?tutor=true` flag no web component reads.
  def test_notify_tutor_note_links_to_the_marking_inbox
    unit = FactoryBot.create :unit
    convenor = FactoryBot.create :user, :convenor

    ur = unit.employ_staff convenor, Role.convenor
    unit.update main_convenor: ur

    tutor = FactoryBot.create :user, :tutor
    tutor_role = unit.employ_staff tutor, Role.tutor

    project = unit.active_projects.first
    task = project.task_for_task_definition(unit.task_definitions.first)

    tutor_note = TutorNote.create!(
      unit_role: tutor_role,
      user: tutor,
      task: task,
      note: 'Please take a look at this submission.',
      read_by_unit_role: false
    )

    mail = TutorNoteMailer.notify_tutor_note(tutor_note, convenor)

    host = Doubtfire::Application.config.institution[:host]
    expected = "#{host}/units/#{unit.id}/tasks/inbox/#{project.user.id}/#{task.task_definition.abbreviation}"

    assert mail.html_part.body.to_s.include?(expected), "html link should point at the marking inbox"
    assert mail.text_part.body.to_s.include?(expected), "text link should point at the marking inbox"
    refute mail.html_part.body.to_s.include?('?tutor=true'), "the dead tutor flag should be gone"

    unit.destroy!
  end
end

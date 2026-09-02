require 'test_helper'

class CommunicationsMailerTest < ActionMailer::TestCase
  def test_communication_email_has_greeting_sign_off_and_unsubscribe
    recipient = FactoryBot.create :user, :student
    sender = FactoryBot.create :user, :convenor

    mail = CommunicationsMailer.communication_email(
      to: recipient.email,
      from: sender.email,
      subject: 'A message from your convenor',
      body: "First paragraph.\nSecond paragraph.",
      recipient: recipient,
      sender: sender,
      unit: nil,
      rule: nil
    )

    html = mail.html_part.body.to_s
    expected_name = recipient.nickname.presence || recipient.first_name

    assert_includes html, "Hi #{ERB::Util.html_escape(expected_name)},"
    assert_includes html, "on behalf of #{ERB::Util.html_escape(sender.name)}"
    assert_includes html, 'Unsubscribe'
    assert_includes html, 'First paragraph.'
    assert_includes html, 'Second paragraph.'
  end

  def test_communication_email_html_escapes_apostrophes_in_names
    recipient = FactoryBot.create :user, :student, first_name: "Sha'Carri", nickname: nil
    sender = FactoryBot.create :user, :convenor, first_name: 'Antonio', last_name: "D'Amore"

    mail = CommunicationsMailer.communication_email(
      to: recipient.email,
      from: sender.email,
      subject: 'A message from your convenor',
      body: 'A message.',
      recipient: recipient,
      sender: sender,
      unit: nil,
      rule: nil
    )

    html = mail.html_part.body.to_s

    assert_includes html, 'Hi Sha&#39;Carri,'
    assert_includes html, 'on behalf of Antonio D&#39;Amore'
  end
end

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

    assert_includes html, "Hi #{expected_name},"
    assert_includes html, "on behalf of #{sender.name}"
    assert_includes html, 'Unsubscribe'
    assert_includes html, 'First paragraph.'
    assert_includes html, 'Second paragraph.'
  end
end

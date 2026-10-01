# frozen_string_literal: true

require 'test_helper'

class DigestDeliveryTest < ActiveSupport::TestCase
  test 'student digest retries failed recipients without repeating successful recipients' do
    unit = create(:unit, student_count: 2, task_count: 0)
    students = unit.active_projects.limit(2).map(&:student)
    students.each { |student| student.update!(digest_frequency: 'daily') }
    claims = Set.new
    deliveries = Hash.new(0)
    should_fail = true
    mailer = lambda do |user, _cadence|
      Object.new.tap do |message|
        message.define_singleton_method(:deliver_now) do
          deliveries[user.id] += 1
          raise IOError, 'Synthetic transport failure' if user.id == students.last.id && should_fail
        end
      end
    end
    job = SendDigestEmailsJob.new
    job.stub(:recipients, User.where(id: students.map(&:id))) do
      DigestDeliveryGuard.stub(:claim, ->(user, period) { claims.add?([user.id, period]) }) do
        DigestDeliveryGuard.stub(:release, ->(user, period) { claims.delete([user.id, period]) }) do
          NotificationsMailer.stub(:student_digest, mailer) do
            assert_raises(RuntimeError) { job.perform('daily') }
            should_fail = false
            job.perform('daily')
          end
        end
      end
    end
    assert_equal 1, deliveries[students.first.id]
    assert_equal 2, deliveries[students.last.id]
  end

  test 'cadence opt out is rechecked immediately before delivery' do
    student = create(:user, :student, digest_frequency: 'daily')
    User.find(student.id).update!(digest_frequency: 'off')
    DigestDeliveryGuard.stub(:claim, ->(*) { flunk 'An opted-out recipient must not reserve a send' }) do
      assert_nil SendDigestEmailsJob.new.send(:deliver, student, 'daily', 'daily:2026-10-01')
    end
  end
end

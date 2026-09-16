class NotificationsMailer < ApplicationMailer
  layout "notification_mail"

  # Project#top_tasks slices its result to five. The number is not exposed by the
  # model, so it is named here rather than written into the copy of two templates
  # where nobody would find it again.
  TOP_TASK_LIMIT = 5

  def add_general
    @doubtfire_host = Doubtfire::Application.config.institution[:host]
    @doubtfire_product_name = Doubtfire::Application.config.institution[:product_name]
    @unsubscribe_url = "#{@doubtfire_host}/edit_profile"
  end

  # Sends a single in-system notification as an email. Called by
  # NotificationEmailJob, which lets delivery failures reach Sidekiq so they can
  # be retried without blocking the request that created the notification.
  def single_notification(notification)
    add_general

    @notification = notification
    @user = notification.user

    # Use the deployment's SMTP-authorised sender, with a development-safe
    # fallback for older installations that have not configured one yet.
    from_address = Doubtfire::Application.config.institution[:email_sender].presence || 'noreply@doubtfire.local'

    email_with_name = address_with_name(@user)
    subject = "#{@doubtfire_product_name}: New notification"

    # An event may ship its own pair of templates named after it, for example
    # task_comment_created.html.erb and task_comment_created.text.erb. Events
    # without them fall back to the generic single_notification pair.
    #
    # This is why a new event ticket only ever adds files and never edits this
    # method: eight event tickets can run in parallel without touching each
    # other's work.
    mail(
      to: email_with_name,
      subject: subject,
      template_name: event_template_name(notification.event),
      **outbound_sender_headers(development_from: from_address)
    )
  end

  # Delivers a second, independent message to a verified additional address.
  # It is intentionally not a CC: neither destination learns the other address,
  # and a failure here can be isolated from the primary institutional delivery.
  def additional_notification_copy(notification, address)
    add_general

    @notification = notification
    @user = notification.user

    from_address = Doubtfire::Application.config.institution[:email_sender].presence || 'noreply@doubtfire.local'
    subject = "#{@doubtfire_product_name}: New notification"

    mail(
      to: address,
      subject: subject,
      template_name: event_template_name(notification.event),
      **outbound_sender_headers(development_from: from_address)
    )
  end

  # The event's own template if it exists, otherwise the generic one.
  def event_template_name(event)
    return 'single_notification' if event.blank?
    return 'single_notification' unless lookup_context.exists?(event, [self.class.mailer_name], false)

    event
  end

  def weekly_staff_summary(unit_role, summary_stats)
    return nil if unit_role.nil?

    add_general

    @staff = unit_role.user
    @unit_role = unit_role
    @unit = summary_stats[:unit]

    @received_comments = @unit.comments
                              .where("task_comments.recipient_id = :uid AND task_comments.created_at > :start", uid: @staff.id, start: 7.days.ago)
                              .where(content_type: [:text, :assessment, :audio, :image, :pdf, :discussion, :extension])
                              .count

    @sent_comments = @unit.comments
                          .where("task_comments.user_id = :uid AND task_comments.created_at > :start", uid: @staff.id, start: 7.days.ago)
                          .where(content_type: [:text, :assessment, :audio, :image, :pdf, :discussion, :extension])
                          .count

    @data = {
      sent_comments: @sent_comments, # Sent by tutor
      received_comments: @received_comments, # Received by tutor
      tasks_awaiting_feedback_count: summary_stats[:staff][unit_role.user][:tasks_awaiting_feedback_count], # For the tutor
      weekly_engagements_count: summary_stats[:staff][unit_role.user][:weekly_engagements_count], # Engagements from the student?
      staff_engagements: summary_stats[:staff][unit_role.user][:staff_engagements], # Engagements by the tutor
      oldest_task_days: summary_stats[:staff][unit_role.user][:oldest_task_days],
      weekly_total_tasks_discussed: summary_stats[:staff][unit_role.user][:weekly_total_tasks_discussed] # Total for the tutor for the week for the tutor
    }

    @convenor = @unit.main_convenor_user
    @summary_stats = summary_stats

    email_with_name = address_with_name(@staff)
    convenor_email = address_with_name(@convenor)

    # A distinct shape from the student subject, so the two never look like the
    # same mail in the inbox of someone who is both.
    waiting = @data[:tasks_awaiting_feedback_count].to_i
    subject =
      if waiting.positive?
        "#{@unit.name} teaching: #{waiting} task#{'s' unless waiting == 1} waiting for your feedback"
      else
        "#{@unit.name} teaching: weekly summary"
      end

    mail(
      { to: email_with_name, subject: subject }.merge(bulk_list_headers).merge(
        outbound_sender_headers(development_from: convenor_email, reply_to: convenor_email)
      )
    )
  end

  def weekly_student_summary(project, summary_stats, did_revert_to_pass)
    return nil if project.nil?

    add_general

    @student = project.student
    @project = project
    @tutor = project.main_convenor_user
    @summary_stats = summary_stats
    @did_revert_to_pass = did_revert_to_pass

    @engagements = @project.task_engagements.where("task_engagements.engagement_time >= :start AND task_engagements.engagement_time < :end", start: summary_stats[:week_start], end: summary_stats[:week_end])

    @engagements_count = @engagements.count

    @student_engagements = @engagements.select { |e| [TaskStatus.not_started.name, TaskStatus.need_help.name, TaskStatus.working_on_it.name, TaskStatus.ready_for_feedback.name].include? e.engagement }.count

    @staff_engagements = @engagements.select { |e| [TaskStatus.complete.name, TaskStatus.feedback_exceeded.name, TaskStatus.redo.name, TaskStatus.discuss.name, TaskStatus.rediscuss.name, TaskStatus.attention_required.name, TaskStatus.demonstrate.name, TaskStatus.fail.name].include? e.engagement }.count

    @task_states = project.tasks.joins(:task_status).select("count(tasks.id) as number, task_statuses.name as status").group("task_statuses.name")

    @received_comments = project.comments.where("recipient_id = :student_id AND task_comments.created_at > :start", student_id: @student.id, start: Time.zone.now - 7.days).count
    @sent_comments = project.comments.where("user_id = :student_id AND task_comments.created_at > :start", student_id: @student.id, start: Time.zone.now - 7.days).count

    @top_tasks = project.top_tasks
    @top_tasks_truncated = @top_tasks.count >= TOP_TASK_LIMIT

    # What the student can actually act on. Two cheap reads and one grouped
    # count, no query per task: the definitions the target grade asks for, the
    # target date of each task the student already has, and how those tasks are
    # spread across the statuses. top_tasks drops the date it sorted on, so the
    # dates are looked up here and matched back by task definition.
    assigned_defs = project.assigned_task_defs.select(:id, :target_date).to_a
    @grade_task_total = assigned_defs.count
    @task_due_dates = {}
    status_by_definition = {}
    project.tasks.each do |task|
      @task_due_dates[task.task_definition_id] = task.due_date
      status_by_definition[task.task_definition_id] = task.task_status_id
    end
    status_counts = project.assigned_tasks.group(:task_status_id).count

    # top_tasks orders by target grade band and then by where the definition sits
    # in the unit, never by date, because that is the order the dashboard wants.
    # An email that says "your oldest" has to sort by date itself, and the list,
    # the lead and the subject all have to read the same order.
    target_date_for = lambda do |entry|
      @task_due_dates[entry[:task_definition].id] || entry[:task_definition].target_date
    end
    by_date = ->(entries) { entries.sort_by { |entry| target_date_for.call(entry) || Date.new(9999, 1, 1) } }

    @overdue_top = by_date.call(@top_tasks.select { |tt| tt[:reason] == :overdue })
    @soon_top = by_date.call(@top_tasks.select { |tt| tt[:reason] == :soon })
    @ahead_top = by_date.call(@top_tasks.select { |tt| tt[:reason] == :ahead })

    # Ready for feedback is the one status that is not the student's move. Every
    # other incomplete status is, which is the split the dashboard makes too.
    @waiting_on_tutor = status_counts.fetch(TaskStatus.ready_for_feedback.id, 0)
    @tasks_complete = status_counts.fetch(TaskStatus.complete.id, 0)
    @waiting_on_student = [@grade_task_total - @tasks_complete - @waiting_on_tutor, 0].max

    # Work the tutor has already handed back. It is not the same as a task never
    # opened, and it is the pile most worth clearing, so it gets counted apart.
    returned_statuses = [
      TaskStatus.fix_and_resubmit, TaskStatus.redo, TaskStatus.discuss,
      TaskStatus.rediscuss, TaskStatus.demonstrate, TaskStatus.feedback_exceeded,
      TaskStatus.attention_required
    ]
    @needs_your_response = returned_statuses.sum { |status| status_counts.fetch(status.id, 0) }

    # Every status the student's own tasks are in, in the order they matter,
    # dropping the ones nobody is sitting on. A task definition with no task row
    # has never been opened, so it joins the not started pile rather than
    # vanishing from the total.
    ordered_statuses = [
      [TaskStatus.complete, 'complete'],
      [TaskStatus.ready_for_feedback, 'with your tutor to mark'],
      [TaskStatus.fix_and_resubmit, 'to fix and resubmit'],
      [TaskStatus.redo, 'to redo'],
      [TaskStatus.discuss, 'to talk through with your tutor'],
      [TaskStatus.rediscuss, 'to talk through again'],
      [TaskStatus.demonstrate, 'to demonstrate'],
      [TaskStatus.feedback_exceeded, 'out of feedback attempts'],
      [TaskStatus.attention_required, 'needing attention'],
      [TaskStatus.time_exceeded, 'past the deadline'],
      [TaskStatus.assess_in_portfolio, 'to carry into your portfolio'],
      [TaskStatus.fail, 'marked fail'],
      [TaskStatus.need_help, 'where you asked for help'],
      [TaskStatus.working_on_it, 'you are working on']
    ]
    @status_summary = ordered_statuses.filter_map do |status, label|
      count = status_counts.fetch(status.id, 0)
      [status.status_key, label, count] if count.positive?
    end
    never_opened = @grade_task_total - status_counts.values.sum
    not_started = status_counts.fetch(TaskStatus.not_started.id, 0) + [never_opened, 0].max
    @status_summary << [:not_started, 'not opened yet', not_started] if not_started.positive?

    # Pace, against the target schedule rather than against the hard deadline.
    # The date on a task is its target date, adjusted for any extension, which is
    # not the same thing as TaskDefinition#due_date, the date after which work
    # stops being accepted. The copy has to say target wherever this is the
    # number behind it.
    #
    # The comparison is strictly before today, matching top_tasks, so a task
    # whose target date is today is not counted as having slipped.
    complete_id = TaskStatus.complete.id
    passed, behind = 0, 0
    assigned_defs.each do |definition|
      target = @task_due_dates[definition.id] || definition.target_date
      next if target.blank? || target.to_date >= Time.zone.today

      passed += 1
      behind += 1 unless status_by_definition[definition.id] == complete_id
    end
    @targets_passed = passed

    # Tasks past their target date and still not complete. This is the honest
    # total, and it is not the same as the overdue list above: task_definitions_
    # and_status keeps only seven statuses, so a task sitting in time_exceeded,
    # feedback_exceeded, attention_required, rediscuss or assess_in_portfolio is
    # never eligible for that list however far past its date it is, and neither
    # is one whose target grade is not among the unit's grade values. Without
    # this number the email can say nothing is overdue and then draw a chart
    # that disagrees.
    @behind_target = behind
    @on_target = passed - behind

    unit_end = project.unit.end_date
    @weeks_left = unit_end.present? ? ((unit_end.to_date - Time.zone.today).to_f / 7).ceil : nil
    @portfolio_due = project.unit.portfolio_auto_generation_date
    @portfolio_days_left = @portfolio_due.present? ? (@portfolio_due.to_date - Time.zone.today).to_i : nil

    email_with_name = address_with_name(@student)
    tutor_email = address_with_name(@tutor)

    # Every state used to send the same subject, so a student who filtered the
    # quiet weeks lost the week they fell behind along with them. The subject now
    # leads on whatever is worst, and only says "Weekly summary" when there is
    # genuinely nothing outstanding.
    subject =
      if @behind_target.positive?
        "#{project.unit.name}: #{@behind_target} task#{'s' unless @behind_target == 1} behind target"
      elsif @needs_your_response.positive?
        "#{project.unit.name}: #{@needs_your_response} task#{'s' unless @needs_your_response == 1} waiting on you"
      elsif @soon_top.present?
        "#{project.unit.name}: #{@soon_top.first[:task_definition].abbreviation} due this week"
      else
        "#{project.unit.name}: Weekly summary"
      end

    mail(
      { to: email_with_name, subject: subject }.merge(bulk_list_headers).merge(
        outbound_sender_headers(development_from: tutor_email, reply_to: tutor_email)
      )
    )
  end

  def top_task_desc(tt)
    "#{tt[:task_definition].abbreviation} - #{tt[:task_definition].name} #{"- which you need to discuss with your tutor" if tt[:status] == :discuss}"
  end

  def were_was(num)
    if num == 1
      "was"
    else
      "were"
    end
  end

  def are_is(num)
    if num == 1
      "is"
    else
      "are"
    end
  end

  def this_these(num)
    if num == 1
      "this"
    else
      "these"
    end
  end

  helper_method :top_task_desc
  helper_method :were_was
  helper_method :are_is
  helper_method :this_these

  private

  # The weekly summaries go to every student and every staff member of every
  # active unit on a schedule, which is bulk mail whatever it is about. Without
  # List-Unsubscribe the only way out is a body link behind a login, and Gmail
  # offers "report spam" where it would otherwise offer "unsubscribe".
  #
  # List-Unsubscribe-Post is deliberately not set. One-Click promises a URL that
  # accepts an unauthenticated POST and acts on it, and the preferences page this
  # points at is a logged-in page; advertising One-Click against it would have
  # Gmail POST to something that cannot honour it, which is worse than not
  # claiming it. It can be added the day a one-click endpoint exists.
  def bulk_list_headers
    return {} if @unsubscribe_url.blank?

    { 'List-Unsubscribe' => "<#{@unsubscribe_url}>" }
  end
end

class NotificationsMailer < ApplicationMailer
  layout "notification_mail"

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
    subject = "#{@unit.name}: Weekly Summary"

    mail(
      { to: email_with_name, subject: subject }.merge(
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
    @overdue_top = @top_tasks.select { |tt| tt[:reason] == :overdue }
    @soon_top = @top_tasks.select { |tt| tt[:reason] == :soon }
    @ahead_top = @top_tasks.select { |tt| tt[:reason] == :ahead }

    # What the student can actually act on. Two cheap reads and one grouped
    # count, no query per task: the definitions the target grade asks for, the
    # due date of each task the student already has, and how those tasks are
    # spread across the statuses. top_tasks drops the date it sorted on, so the
    # dates are looked up here and matched back by task definition.
    assigned_defs = project.assigned_task_defs.select(:id, :target_date).to_a
    @grade_task_total = assigned_defs.count
    @task_due_dates = project.tasks.each_with_object({}) do |task, dates|
      dates[task.task_definition_id] = task.due_date
    end
    status_counts = project.assigned_tasks.group(:task_status_id).count

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

    # Pace. How much of the grade was meant to be done by today, against how much
    # is. Both come from rows already in memory.
    @tasks_due_by_now = assigned_defs.count do |definition|
      due = @task_due_dates[definition.id] || definition.target_date
      due.present? && due.to_date <= Time.zone.today
    end

    unit_end = project.unit.end_date
    @weeks_left = unit_end.present? ? ((unit_end.to_date - Time.zone.today).to_f / 7).ceil : nil
    @portfolio_due = project.unit.portfolio_auto_generation_date
    @portfolio_days_left = @portfolio_due.present? ? (@portfolio_due.to_date - Time.zone.today).to_i : nil

    email_with_name = address_with_name(@student)
    tutor_email = address_with_name(@tutor)
    subject = "#{project.unit.name}: Weekly Summary"

    mail(
      { to: email_with_name, subject: subject }.merge(
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

  # Build the recipient or sender address through Mail so a display name that
  # contains a quote or a comma cannot break out of the name and inject a second
  # address, and strip control characters so a name cannot fold an extra header
  # into the message. User#name comes from first_name/last_name, which are
  # user-editable and validated for presence only, so the raw
  # %("#{name}" <#{email}>) interpolation this replaces was header-injectable.
  def address_with_name(user)
    safe_name = user.name.to_s.gsub(/[[:cntrl:]]/, ' ').strip
    address = Mail::Address.new(user.email.to_s)
    address.display_name = safe_name
    address.format
  end
end

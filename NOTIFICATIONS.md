# Notifications

This explains how notifications work in OnTrack after the unification.

## The idea

Before, each type of message did its own thing. Emails were sent from many
places. There was no single system.

Now there is one system. You send a notification once. It goes out on all the
channels the user has turned on. Today those channels are in-app and email. Push
is planned next.

## The flow

    something happens in the app
        -> you call NotificationService.notify(...)
            -> saves an in-app notification (the bell)
            -> sends an email
            -> sends a push (later, off for now)

You only call one thing. The system handles the rest.

## How to send one

Call this from anywhere in the API code:

    NotificationService.notify(
      user: project.student,
      type: 'feedback',
      message: "New feedback is ready for #{task_definition.name}.",
      link: "/#/projects/#{project.id}"
    )

- user: who gets it.
- type: the category. One of task, feedback, portfolio, extension, general.
- message: the text the user sees. Keep it short.
- link: where clicking it should take them. Optional.

## Types and preferences

Each user already has three on/off settings in their profile:

- receive_task_notifications
- receive_feedback_notifications
- receive_portfolio_notifications

The type you pass maps to one of these settings.

- task uses receive_task_notifications
- feedback uses receive_feedback_notifications
- portfolio uses receive_portfolio_notifications
- extension and general are always sent

If the matching setting is off, nothing is sent. Not the bell, not the email,
not the push. One switch controls all channels. This keeps it simple. We can add
per-channel switches later if we want.

## The pieces

- app/models/notification.rb: the notification record. Has the type, message,
  link, and whether it has been read.
- app/services/notification_service.rb: the one entry point. Checks the setting,
  saves the record, sends the email, calls push.
- app/services/push_notification_service.rb: the push channel. It is a safe
  placeholder for now. It does nothing until push keys are set up.
- app/mailers/notifications_mailer.rb: the email. New method single_notification
  with templates in app/views/notifications_mailer.
- app/api/notifications_api.rb: the endpoints the web app calls.
- app/api/entities/notification_entity.rb: the shape of the data sent back.

## The endpoints

    GET    /api/notifications                 list my notifications
    GET    /api/notifications/unread_count     how many I have not read
    PUT    /api/notifications/:id/read         mark one as read
    PUT    /api/notifications/read_all          mark all as read
    DELETE /api/notifications/:id              delete one

Every endpoint only ever touches the current user's own notifications.

## What is on now

- In-app: working. The record is saved and the endpoints return it.
- Email: working. Best effort. If email fails, the in-app notification is still
  saved.
- Push: not on yet. The code path is there but does nothing until push keys are
  set up.

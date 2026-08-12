# Event: extension_assessed

## What it does

A tutor assesses a student's extension request.

- If the extension is granted, the student is notified and the message includes the new due date.
- If the extension is denied, the student is notified that the request was rejected.
- Failed assessment paths do not send a notification.

## Where it is raised

`app/models/comments/extension_comment.rb`, inside `assess_extension`, after the extension assessment has successfully saved.

```ruby
NotificationService.notify(
  user: project.student,
  type: 'extension',
  event: 'extension_assessed',
  message: extension_response,
  link: "/projects/#{project.id}/dashboard/#{task.task_definition.abbreviation}"
)
# Web push setup

How the push channel works, how to turn it on, and how to check it is working.

## What push needs

Three things, and push is a no-op until all three are true:

1. **VAPID keys on the api.** Without them `PushNotificationService.configured?`
   is false and `deliver` returns immediately. The app behaves exactly as it did
   before push existed.
2. **A row in `push_subscriptions`.** A browser has to register itself first.
   MN-F01 added the table and the API.
3. **A service worker in the browser.** MN-F03 turns it on for development.
   Without it, the browser has nothing to receive a push with. Setup,
   caching side effects and how to clear a stuck worker are in the web repo:
   `doubtfire-web/docs/service-worker.md`.

Miss any one and nothing arrives, with no error anywhere. Check them in order.

## The keys

VAPID is how a push service knows the push came from us and not from anyone else
who happens to know a browser's endpoint URL. It is one key pair for the whole
server, not one per user.

Generate a pair:

    docker exec doubtfire-api bundle exec ruby -e \
      "require 'web_push'; k = WebPush.generate_key; puts k.public_key; puts k.private_key"

Then set three environment variables on the api:

| Variable | What it is |
|---|---|
| `DOUBTFIRE_VAPID_PUBLIC_KEY` | Public half. The browser needs this to subscribe. |
| `DOUBTFIRE_VAPID_PRIVATE_KEY` | **Secret.** Signs every push. Never commit a real one. |
| `DOUBTFIRE_VAPID_SUBJECT` | A `mailto:` or URL the push service can contact. Optional; falls back to the institution host. |

`development/docker-compose.yml` in the deploy repo already carries a throwaway
pair so the local stack works out of the box, on the same footing as
`DF_SECRET_KEY_BASE`. That pair is development only. **A production deployment
sets its own through real secrets, and if the private key ever leaks, generate a
new pair — every existing subscription becomes useless and users have to
re-subscribe.**

Changing the keys does not migrate anything. The `push_subscriptions` rows stay,
but pushes signed with the new key are rejected for browsers that subscribed
under the old one, and those rows get cleaned up as 403s arrive.

## How a notification becomes a push

`NotificationService.notify` already calls `PushNotificationService.deliver`, so
**every event that sends an email sends a push, with no per-event work**. Nothing
in an event ticket has to know push exists.

`deliver` loops over `notification.user.push_subscriptions` and sends this
payload to each:

```json
{
  "notification": {
    "title": "OnTrack",
    "body": "Andrew Cain commented on 1.1P in COS10001.",
    "data": { "notification_id": 12, "link": "/projects/2/dashboard/1.1P" }
  }
}
```

The top level `notification` key matters. Angular's own `ngsw-worker.js` looks
for exactly that and displays the notification itself. **Change the shape and
somebody has to write a service worker by hand.**

`data.link` is what MN-C03 reads to decide where to send the user on click.

## Failure handling

- **404 or 410** means the browser threw the registration away. The row is
  deleted, because nothing will ever reach it again.
- **Anything else** (429 rate limit, the push service being down, a rejected
  payload) is logged and skipped. The subscription is kept, because those are
  temporary and deleting on them would silently unsubscribe people the first time
  a push service had a bad day.
- Nothing propagates to the caller. A push failure must never block the in-app
  notification or the email.

## Checking it works

**Are the keys loaded?**

    docker exec doubtfire-api bundle exec rails runner \
      'puts PushNotificationService.configured?'

`false` means the api container was started before the variables were added.
`restart` does not pick up new environment variables. Recreate it:

    docker compose -f docker-compose.yml -f docker-compose.local-paths.yml up -d doubtfire-api

**Is a browser registered?**

    docker exec doubtfire-api bundle exec rails runner \
      'puts PushSubscription.all.map { |s| "#{s.user.username} #{s.endpoint[0, 60]}" }'

Empty means nothing has subscribed yet. That is the usual reason a push does not
arrive, and it looks identical to push being broken.

**Subscribe this browser by hand.** Until MN-C01 adds the opt-in button, paste
this into the dev tools console on a page where you are signed in. It needs
MN-F03 done first, or `navigator.serviceWorker.ready` never resolves.

```js
const VAPID = '<the public key>'
const b64 = s => Uint8Array.from(atob(s.replace(/-/g,'+').replace(/_/g,'/')), c => c.charCodeAt(0))

const reg = await navigator.serviceWorker.ready
const sub = await reg.pushManager.subscribe({
  userVisibleOnly: true,
  applicationServerKey: b64(VAPID)
})
const j = sub.toJSON()

await fetch('/api/push_subscriptions', {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    'Username': localStorage.getItem('username'),
    'Auth-Token': localStorage.getItem('authToken')
  },
  body: JSON.stringify({ endpoint: j.endpoint, p256dh: j.keys.p256dh, auth: j.keys.auth })
})
```

Then raise a notification (post a task comment) and a desktop notification
should appear.

**Nothing appeared?** Check in this order, because each step is invisible when it
fails:

1. Browser notification permission. `Notification.permission` must be `granted`.
   macOS also has to allow notifications from the browser, in System Settings.
2. `PushNotificationService.configured?` is true.
3. A `push_subscriptions` row exists for the user the notification went to. It is
   easy to subscribe as one account and then trigger a notification for another.
4. `docker logs doubtfire-api | grep -i "push"`. Delivery failures are logged and
   swallowed, so this is the only place they show up.

## Why the gem is pinned

`Gemfile` pins `web-push` to exactly `3.0.0`. Versions from 3.0.1 require
`jwt ~> 3.0`, and taking that forces `jwt` to a new major version and drags
`oauth2` from 2.0.9 to 2.0.25 with it, because the older `oauth2` caps `jwt`
below 3. That would put LTI (`app/helpers/lti_helper.rb` calls `JWT.decode`) and
the D2L OAuth integration inside the blast radius of a push change. Unpinning is
a separate piece of work with its own testing.

# PWA offline behaviour

What a user sees if they lose connection while using OnTrack, and why.

## What is cached, and what is not

`ngsw-config.json` (doubtfire-web) has two kinds of cache group. The `app` and
`assets` asset groups cache the static shell — `index.html`, the compiled JS
and CSS bundles, and images — with `installMode: prefetch`, so the shell
downloads up front. That part of the PWA is designed to work offline.

The `api` data group is deliberately excluded:

```json
{
  "name": "api",
  "urls": ["/api"],
  "cacheConfig": {
    "maxSize": 0,
    "maxAge": "0u",
    "strategy": "freshness"
  }
}
```

`maxSize: 0` means the cache holds zero entries, so there is never anything
to fall back to. `strategy: freshness` is network-first, and with nothing
cached, a failed network request has no cached response behind it — it just
fails. In practice: **no API response is ever served from the service
worker's cache, under any condition.**

### The maxSize 0 choice

This traces back to commit `ab5a30a`, "FIX: Ensure api/ data is not cached"
(2020). The commit message does not elaborate further than that, but the
reasoning is not hard to infer: API responses here are grades, task status,
submissions and extension state — exactly the data where showing something
stale would be actively misleading, not just inconvenient. A short-TTL cache
would still risk a tutor or student acting on an out-of-date number. Opting
API traffic out of the cache entirely avoids that risk, at the cost of any
offline API access at all. If a more specific justification than this exists,
it hasn't been written down anywhere in the codebase — worth confirming with
the lead if it matters for a future decision.

No caching behaviour was changed to investigate this ticket. The above is a
description of the existing config, not a proposal.

## What actually happens offline

Tested in Chrome DevTools (Network tab → Offline), against the dev stack with
the service worker confirmed active and controlling the page (`Application` →
`Service Workers` showed `ngsw-worker.js` "activated and running" before each
test below).

### Scenario 1: reloading a page while offline

Navigating to `localhost:4200/projects/28/dashboard/A15` and reloading while
offline does not show any OnTrack UI. Chrome shows its own native offline
page — "This page isn't working, localhost took too long to respond, HTTP
ERROR 504." The network log confirms the top-level document request itself
failed outright rather than being served from the service worker's cached
shell.

So despite the service worker being registered and running, a hard reload
while offline does not fall back to a cached app shell. The user gets a
generic browser error with no indication it's OnTrack-specific, and no way
to retry from within the app.

### Scenario 2: losing connection mid-session

More realistic: the app is already loaded and the user goes offline without
reloading, then navigates to a task they haven't opened yet in that session
(client-side routing, no full page load).

Here the shell and anything already in memory stay up — the task list
sidebar, and top-level task fields (title, due date, status) that were part
of an earlier list fetch, render fine. But the secondary fetches that page
needs (`prerequisites`, `submission_details`, `comments`) mostly fail. Some
of the same-looking requests returned `200`/`304` and some returned `504` or
failed outright — the successes are ordinary browser HTTP cache hits for
URLs already fetched earlier in the session, not the service worker's own
data cache, which is disabled by `maxSize: 0`. Anything not already fetched
before going offline has nothing to fall back to and fails.

When a fetch fails, the app does not degrade gracefully. It surfaced this to
the user as a toast:

> Failed to fetch prerequisites for task definition: TypeError: Cannot read
> properties of null (reading 'error')

That's an unhandled null dereference, not an offline message — the error
handling path assumes a response body is always present and throws when
there isn't one. A user sees a confusing technical error rather than
anything telling them they're offline.

## Summary

The `api` group's no-cache config guarantees a user is never shown stale
academic data, which is clearly the intent. The tradeoff is that there is no
designed offline mode at all: depending on whether they reload or just keep
navigating, a disconnected user gets either a browser-level 504 page or a
raw JS error toast. Neither tells them they're offline, and neither offers a
retry.

## Recommendation

Out of scope here — this ticket is documentation only, no caching behaviour
was changed. If the team wants an actual offline UX (a banner, a clear
"you're offline, reconnect to continue" state, or handling the null response
case without throwing), that belongs in a separate ticket.

## How to check it by hand

1. Open the app, sign in, and confirm the service worker is active:
   DevTools → `Application` → `Service Workers` → status should read
   "activated and is running."
2. **Reload case:** DevTools → `Network` → set throttling to `Offline`,
   then reload the page. Expect Chrome's native offline error page, not
   OnTrack.
3. **Mid-session case:** with the app already loaded, switch to `Offline`
   without reloading, then click into a task not yet opened this session.
   Expect the shell to stay up, task list data already in memory to render,
   and any new data fetch (prerequisites, submission details, comments) to
   fail — watch for an unhandled error toast rather than an offline message.
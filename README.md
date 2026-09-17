# Discourse Meta Pixel & Conversions API

Meta Pixel and Conversions API in one plugin, SPA-aware and deduplicated.

Every event can be sent twice — once from the browser Pixel, once server-side
through the Conversions API — sharing a single event ID so Meta counts it once.
The server copy survives ad blockers and Safari's cookie limits; the browser
copy carries the identity signals a server-only event cannot.

Personal messages, restricted categories and admin routes produce no event at
all. Not a redacted one.

## Why not just paste the Pixel into a theme component?

That is the usual approach and it works, for a narrow definition of works. The
standard Meta base code ends with:

```js
fbq('init', 'YOUR_PIXEL_ID');
fbq('track', 'PageView');
```

Both lines run once, when the document loads. Discourse is a single-page
application and never reloads the document, so **that is one `PageView` per
visit** — not per topic, not per navigation. Someone who arrives from an ad and
reads thirty topics looks identical to someone who bounced off the landing
page.

Three more things follow from a theme component being browser-only:

**Ad blockers and Safari delete a large share of it.** `connect.facebook.net`
is on every major blocklist, and Safari's ITP caps `_fbp` lifetime regardless.
Whatever share of your audience that is, those conversions simply never arrive,
and you cannot tell they are missing.

**It cannot do the Conversions API at all.** CAPI needs an access token, and an
access token is a server-side secret. There is nowhere in a theme component to
put one that is not also somewhere a visitor can read it. This is an
architectural limit, not a missing feature.

**It cannot filter.** The snippet fires wherever it is injected, which is
everywhere — personal messages, `/admin`, password reset, account activation.

| | Theme component | This plugin |
|---|---|---|
| `PageView` | Once per full page load | Once per navigation |
| `ViewContent`, engagement | — | Per topic, attentive time |
| Conversions (register, post, reply) | — | Server-authoritative |
| Conversions API | Impossible — token would be public | Yes, token stays server-side |
| Blocked or ITP-limited browsers | Event lost | Server copy still arrives |
| Deduplication | n/a | Shared event ID, both copies |
| Personal messages, admin routes | Fires | No event |
| Retries, idempotency | — | Durable queue, unique on event ID |

To be fair to the theme-component approach: if all you want is a `PageView` for
a retargeting audience and you are not running conversion-optimised campaigns,
it is genuinely enough, and it takes two minutes. The case for this plugin is
conversion quality — events Meta can attribute and optimise against, that
survive a blocker, and that are not counted twice when you add the server half.

## Installation

Add to your `app.yml`, then rebuild:

```yml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/multidimension-al/discourse-meta-pixel-capi.git
```

```sh
cd /var/discourse
./launcher rebuild app
```

The rebuild runs the migration that creates the delivery table. See
[Install a plugin](https://meta.discourse.org/t/install-a-plugin/19157) for
other setups.

## Setup

### Pixel

1. Set `meta pixel dataset id` to your Pixel ID from Events Manager. Meta calls
   it the Pixel ID there and the dataset ID in the Conversions API docs — same
   number. It is not secret; it ships in the page.
2. Turn on `discourse meta pixel enabled`.

`meta pixel pixel enabled` is already on. That is a working Pixel-only setup;
the Conversions API is optional.

### Conversions API

1. Generate a token in Events Manager → your dataset → Settings → Conversions
   API, and put it in `meta pixel capi access token`. The setting is marked
   secret: it never reaches the browser and never appears in diagnostics.
2. Turn on `meta pixel capi enabled`.

The setting refuses to turn on without a token and dataset ID, so a
misconfiguration fails at the setting rather than silently in the queue.

### Verify

Put a code from Events Manager → Test Events into `meta pixel test event code`
and browse the forum. Each event should arrive **once**, not twice — that is
deduplication working.

Clear the field when you are done. Events sent with a test code do not count as
conversions, and forgetting looks exactly like a working integration. The admin
dashboard warns if you leave it set.

## How the two halves fit together

| Event | Fired by | Why |
|---|---|---|
| `PageView` | browser, mirrored to server | |
| `ViewContent` | browser, mirrored to server | |
| `Search` | browser, mirrored to server | The query itself is never sent |
| `TopicEngaged` | browser, mirrored to server | |
| `TopicCreated` | server only | |
| `ReplyCreated` | server only | |
| `CompleteRegistration` | server, paired to browser | |

`TopicEngaged` is the one event Meta does not define, so the Pixel sends it
with `fbq('trackCustom')` rather than `fbq('track')`; the rest are standard
events. The Conversions API treats both the same, so this only affects the
browser half.

Browser events POST a minimal body to `/meta-pixel/events`, which the server
re-validates and re-derives everything from. That endpoint is not a Conversions
API proxy: it accepts four event names, an event ID, and optionally a topic ID
and path. It will not accept a URL, arbitrary `user_data`, or an event name it
does not know.

Topic and reply creation are server-only because the browser copy would add
nothing — there is no additional identity signal at that moment, and a client
that could assert "a topic was created" could assert it falsely.

Registration is the one pair. At `:user_created` there is no request, so a
conversion sent then would carry no IP, no user agent and no `_fbp`/`_fbc` —
the worst-matched event in the plugin, for the most valuable conversion.
Instead a marker is recorded and the next authenticated render fires both
halves with the same ID.

`event_time` is always when the thing happened, not when the queue drained.
Meta uses it for attribution and accepts it up to seven days old.

## Settings

Admin → Settings → Meta Pixel & Conversions API.

| Setting | Default |
|---|---|
| `meta pixel track page view` | on |
| `meta pixel track view content` | on |
| `meta pixel track search` | **off** |
| `meta pixel track topic engaged` | on |
| `meta pixel topic engaged seconds` | 30 |
| `meta pixel track complete registration` | on |
| `meta pixel track topic created` | on |
| `meta pixel track reply created` | on |

### Privacy and matching

| Setting | Default | Notes |
|---|---|---|
| `meta pixel enhanced email matching` | **off** | SHA-256 of the member's email |
| `meta pixel external id matching` | on | Opaque HMAC of the user ID |
| `meta pixel respect do not track` | on | |
| `meta pixel public content only` | on | |

`external_id` is an HMAC keyed on Discourse's own secret key base, so it is
stable for matching across events but tells Meta nothing about the account and
cannot be reversed into a user ID.

### Excluded groups

`meta pixel excluded groups` (default: admins, moderators) suppresses **all**
Meta events for those members.

Suppression rather than tagging, because Meta has no equivalent of GA4's
internal-traffic filter: an event that arrives has already been counted and can
already train a campaign. Enforced on every server dispatch path as well as in
the browser — `TopicCreated`, `ReplyCreated` and `CompleteRegistration` never
involve a browser, so a client-side check alone would leak exactly the
conversions that matter most.

### Delivery

| Setting | Default |
|---|---|
| `meta pixel graph api version` | `v26.0` |
| `meta pixel batch size` | 100 (max 1000) |
| `meta pixel batch max wait seconds` | 300 |
| `meta pixel delivery retention days` | 30 (minimum 7) |

Deliveries are **batched**. A topic visit produces two or three of them, so
sending each in its own job and its own request is wasteful; Meta accepts up to
1,000 events per request. Events are buffered and flushed when the batch fills
or when the oldest has waited long enough, turning thousands of requests a day
into dozens.

What bounds the wait is not Meta's seven-day `event_time` window but its
**48-hour deduplication window**: the browser Pixel fires immediately, and past
48 hours the server copy stops being matched to it and starts being a second
conversion. The default five-minute wait leaves a wide margin.

Meta accepts or rejects a request as a whole, so one malformed event would
reject its ninety-nine healthy neighbours. A rejected batch is therefore
retried event by event, over one held-open connection, so only the offender is
marked failed.

Failures are classified: a bad token or a malformed payload is permanent and
not retried, a timeout or a 5xx is retried with backoff. A 429 stands *every*
flush down for the `Retry-After` Meta asks for — Sidekiq's own backoff is per
job, which would leave every other flush hammering a limit already hit. A
scheduled sweep re-enqueues deliveries that were claimed in the database but
never made it onto the queue.

The buffer lives in Redis rather than the deliveries table, because a
browser-mirrored event carries transient matching data — IP, user agent,
`_fbp`, `_fbc` — that deliberately never reaches Postgres. Losing the buffer is
survivable: every entry has a `pending` row behind it, and the recovery sweep
picks those up.

The delivery table is unique on `event_name + event_id`, which is what makes a
replayed `DiscourseEvent` or a retried job a no-op rather than a second
conversion. Rows are purged on the retention schedule; the transient matching
data (IP, user agent, `_fbp`, `_fbc`) lives only in the job payload and is
never written to the database.

## Events

See [docs/events.md](docs/events.md) for the full reference.

Topic titles are never sent. `custom_data` carries a topic ID and category
slug, and only for topics that are visible to an anonymous visitor.
`event_source_url` is canonicalised and stripped of every query parameter that
is not on a short allowlist.

## Verifying it works

Admin → Plugins → Meta Pixel → **Diagnostics** shows configuration, live
browser state, delivery counts and the last 25 deliveries with their status and
any error.

If it says "Pixel initialised: no", check whether you are in a group named by
`meta pixel excluded groups` — the page tells you when you are. View the forum
logged out to see the Pixel as a visitor does.

## Troubleshooting

**Events in Test Events but no conversions.** A test code is still set. Clear
`meta pixel test event code`.

**Deliveries failing with a permanent error.** Check the Diagnostics page for
the message. An invalid OAuth token means the access token is wrong or expired.

**Browser events but no server events.** `meta pixel capi enabled` is off, or
the token is missing. The admin dashboard warns about this.

**Nothing at all for you specifically.** You are probably in an excluded group.

## Development

```sh
pnpm install
pnpm lint
pnpm test:standalone
ruby spec/standalone/standalone_test.rb
```

Against a Discourse checkout:

```sh
ln -s /path/to/discourse-meta-pixel-capi discourse/plugins/
cd discourse
RAILS_ENV=test bundle exec rake db:create db:migrate
bundle exec rspec plugins/discourse-meta-pixel-capi/spec
bundle exec rake "plugin:qunit[discourse-meta-pixel-capi]"
```

`plugin:qunit` needs Chrome or Chromium on `PATH`. In a container, run as a
non-root user or set `DISCOURSE_DISABLE_BROWSER_SANDBOX=1`.

## License

MIT

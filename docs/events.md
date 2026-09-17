# Events

Every event the plugin can send. Exclusions are absolute: where the table says
`none`, no event is sent, not a redacted one.

## Reference

| Event | Fired by | Setting | Public | Restricted | PM |
|---|---|---|---|---|---|
| `PageView` | Browser + mirror | `meta pixel track page view` | sent | sent | none |
| `ViewContent` | Browser + mirror | `meta pixel track view content` | sent | none | none |
| `Search` | Browser + mirror | `meta pixel track search` (off) | sent | sent | n/a |
| `TopicEngaged` | Browser + mirror | `meta pixel track topic engaged` | sent | none | none |
| `CompleteRegistration` | Server, paired to browser | `meta pixel track complete registration` | sent | — | — |
| `TopicCreated` | Server only | `meta pixel track topic created` | sent | none | none |
| `ReplyCreated` | Server only | `meta pixel track reply created` | sent | none | none |

"Browser + mirror" means the Pixel fires it and the browser POSTs a minimal
body to `/meta-pixel/events`, which the server re-validates before sending its
own copy with the same event ID.

`PageView`, `ViewContent`, `Search` and `CompleteRegistration` are Meta's own
standard events and go through `fbq('track')`. `TopicEngaged` is not, so it
goes through `fbq('trackCustom')` — sent the other way `fbevents.js` logs a
non-standard event warning and Events Manager does not treat it as a custom
conversion. The Conversions API draws no such distinction, so the server half
is unchanged either way and the two copies still deduplicate.

## Payload

Every event carries:

| Field | Source |
|---|---|
| `event_name` | Fixed list above |
| `event_id` | Shared between the browser and server copies |
| `event_time` | When it happened, not when the queue drained |
| `action_source` | Always `website` |
| `event_source_url` | Canonicalised, query reduced to an allowlist |

### `user_data`

Derived on the server. The browser never contributes to it.

| Field | Sent when |
|---|---|
| `client_ip_address` | Always — from the request, not the client |
| `client_user_agent` | Always — from the request |
| `fbp` / `fbc` | When Meta's cookies are present |
| `external_id` | `meta pixel external id matching` on (default). HMAC of the user ID keyed on Discourse's secret key base |
| `em` | `meta pixel enhanced email matching` on (**off** by default). SHA-256 of the normalised address |

Hashed values are arrays, as Meta expects. Nothing here is reversible into an
account.

### `custom_data`

Only on `ViewContent`, `TopicEngaged`, `TopicCreated` and `ReplyCreated`, and
only for topics an anonymous visitor could read:

| Field | Value |
|---|---|
| `content_type` | `topic` |
| `content_ids` | `[topic id]` |
| `content_category` | Category slug |

Topic titles are never included.

## Deduplication

Meta deduplicates on `event_name` + `event_id` within a 48-hour window. The
browser generates a 32-character hex ID and sends the same one to both Meta and
the mirror endpoint.

Server-authoritative events derive their ID from the object instead —
`TopicCreated` from the topic, `ReplyCreated` from the post,
`CompleteRegistration` from the account — so a replayed `DiscourseEvent`, a
re-run job or a restored backup produces the same ID and is rejected by the
delivery table's uniqueness constraint rather than counted twice.

## Not sent

Topic titles, post content, search queries, usernames, real names, raw email
addresses, personal message metadata of any kind, and anything from a category
an anonymous visitor cannot read.

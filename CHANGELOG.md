# Changelog

## Unreleased

Initial release.

- Send `TopicEngaged` with `fbq('trackCustom')` instead of `fbq('track')`. It
  is not one of Meta's standard events, so `track` logged a non-standard event
  warning in the console and the event was not recorded as a custom conversion.

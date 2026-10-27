# Chiboard telemetry schema v2

The canonical executable definition is `Collector/schema.py`. All envelope and
event objects use exact field sets; extra or missing fields are invalid.

Version 2 adds one event and changes no other. Clients from version 2 on send
`"schema_version": "2"` in every event; the collector still accepts the four
version 1 events from earlier releases (`Fixtures/v1`). The signed envelope is
unchanged and keeps its own `schema_version` 1.

Allowed events:

- `usage_summary`, `model_load_result`, `setup_milestone`, `crash`: as in
  [version 1](schema-v1.md).
- `term_summary` (version 2 only): one finished local day of numeric
  special-term statistics, with `window_seconds` fixed at 86400 and the 62
  integer fields of `TERM_METRICS`:
  - the store: terms by origin (`manual`, `setup`, `learned`) and language
    (`chinese`, `english`); pending, accepted, and dismissed suggestions;
  - the store's shape, as counts per bucket: term length in characters and
    syllables, the key form usually typed (full pinyin, initials, mixed,
    other, unknown), positive examples per term, and example length;
  - lifecycle counts: corrections by signal, suggestions created, accepted,
    and dismissed, manual additions, edits, deletions, and age at deletion;
  - firing counts: key matches, already correct, missed, applied and kept,
    offered and kept, and overridden;
  - the provisional snapshot: entries (0–64), the lower bound of its token
    count's bucket (0, 1, 256, 512, 1024, 2048, 4096, 8192), builds, and
    changes.

  Every value is a non-negative decimal integer string within 2^31−1. No
  field carries a term, key, example, or any hash or other value derived from
  their text.

The envelope includes schema version, batch ID, send time, random
installation ID, Ed25519 key ID/public key, and one to 50 events. Maximum body
size is 64 KiB and accepted clock skew is 24 hours. Clients send one event per
batch.

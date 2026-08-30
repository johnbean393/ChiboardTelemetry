# Chiboard telemetry schema v1

The canonical executable definition is `Collector/schema.py`. All envelope and
event objects use exact field sets; extra fields are invalid.

Allowed events:

- `usage_summary`: a 30-minute window and aggregate conversion, candidate, and
  shortcut counters.
- `model_load_result`: success, backend, bounded duration, and an allowlisted
  numeric failure category.
- `setup_milestone`: an allowlisted setup step and result.
- `crash`: a random crash ID, signal category, stable signature, and at most 64
  image UUID/offset frames.

The signed envelope includes schema version, batch ID, send time, random
installation ID, Ed25519 key ID/public key, and one to 50 events. Maximum body
size is 64 KiB and accepted clock skew is 24 hours.

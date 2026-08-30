# Privacy contract

Schema version 1 permits four record types: aggregated usage totals, model-load
results, setup milestones, and sanitized crash frames. Every field is defined
in `Collector/schema.py`; the collector rejects every unknown field instead of
attempting to clean it. Versioned examples live in `Contract/Fixtures` and are
exercised by both client and collector tests.

Uploads contain a random installation UUID and an installation-scoped Ed25519
public key. They do not contain an account identifier. Crash records contain
image UUIDs and offsets only, not memory, local paths, exception text, or user
content.

Sharing is disabled unless both the host's public runtime configuration and the
user's explicit consent are enabled. Turning sharing off removes the local
identifier, signing key, and queued reports. Production records expire within
30 days.

For privacy questions, contact johnbean393@gmail.com.

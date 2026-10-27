# Privacy contract

Schema version 2 permits five record types: aggregated usage totals, model-load
results, setup milestones, sanitized crash frames, and a daily summary of
special-term counts. Every field is defined in `Collector/schema.py`; the
collector rejects every unknown field instead of attempting to clean it.
Versioned examples live in `Contract/Fixtures` (and `Contract/Fixtures/v1` for
earlier releases) and are exercised by both client and collector tests.

The special-term summary contains only integers: how many terms and
suggestions there are, how many fall in fixed length, syllable, key-form, and
example buckets, and how often terms were suggested, accepted, dismissed,
added, edited, deleted, typed, and already right. It never contains a term,
the keys typed for it, an example sentence, or a hash of any of them.

Uploads contain a random installation UUID and an installation-scoped Ed25519
public key. They do not contain an account identifier. Crash records contain
image UUIDs and offsets only, not memory, local paths, exception text, or user
content.

Sharing is disabled unless both the host's public runtime configuration and the
user's explicit consent are enabled. Turning sharing off removes the local
identifier, signing key, and queued reports. Production records expire within
30 days.

For privacy questions, contact johnbean393@gmail.com.

# ChiboardTelemetry

ChiboardTelemetry is the source-available, audit-only telemetry subsystem used
by Chiboard. It is published so users and security researchers can inspect the
complete client data path and the collector's closed schema.

The audit license is all-rights-reserved and is not an OSI-approved license.
The source may be inspected and issues or security reports may be submitted,
but copying, modification, redistribution, production use, and pull-request
contributions require a separate written license from the copyright holder.

## Privacy properties

- Collection is optional and off by default.
- The client exposes only typed, allowlisted events. It has no arbitrary event,
  property, log, text, or dictionary API.
- Disabling collection stops the backend and removes the local installation ID,
  signing key, and queued reports.
- The collector rejects unknown schemas, events, and fields.
- Neither the client nor collector records typed text, Pinyin, conversions,
  custom terms, files, applications, screenshots, diagnostic logs, or source
  IP addresses.

See [PRIVACY.md](PRIVACY.md) for the wire contract and retention policy.

## Development

```sh
swift test
python3 -m unittest discover -s Collector -p 'test_*.py'
python3 Scripts/validate_audit_repository.py
```

The package supports macOS 14 and later and pins PLCrashReporter 1.12.2.
The files under `Contract/Fixtures` are golden client payloads validated by
both the Swift encoder tests and the Python collector tests.

## Publication controls

The package is released from a clean repository rather than transplanted Git
history. Before a public `0.1.0` tag, the audit repository scan, legal review,
dependency review, macOS Swift tests, Python collector tests, privacy-manifest
validation, and golden-fixture parity must all pass. Release tags are signed
and immutable, and `main` is protected. Issues and private vulnerability
reports are accepted; external code and pull requests are not merged.

"""Closed telemetry schema and validation for the Chiboard collector.

The collector intentionally rejects unknown fields instead of attempting to
clean them. This makes a client-side privacy regression fail closed.
"""

from __future__ import annotations

import base64
import hashlib
import json
import re
import time
import uuid
from dataclasses import dataclass
from typing import Any

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey


MAX_BODY_BYTES = 64 * 1024
MAX_EVENTS_PER_BATCH = 50
MAX_CLOCK_SKEW_SECONDS = 24 * 60 * 60

# Version 2 added term_summary; the other events are unchanged from version 1.
SCHEMA_VERSIONS = {"1", "2"}
EVENT_SCHEMA_VERSIONS = {"term_summary": {"2"}}

# The daily special-term summary: numeric store, shape, lifecycle, firing,
# and snapshot counts. No field names or carries a term, key, or example.
TERM_METRICS = (
    "terms_manual_chinese",
    "terms_manual_english",
    "terms_setup_chinese",
    "terms_setup_english",
    "terms_learned_chinese",
    "terms_learned_english",
    "suggestions_pending",
    "suggestions_accepted",
    "suggestions_dismissed",
    "term_length_1",
    "term_length_2",
    "term_length_3",
    "term_length_4",
    "term_length_5_6",
    "term_length_7_10",
    "term_length_11_plus",
    "term_syllables_1",
    "term_syllables_2",
    "term_syllables_3",
    "term_syllables_4",
    "term_syllables_5_6",
    "term_syllables_7_plus",
    "key_form_full_pinyin",
    "key_form_initials",
    "key_form_mixed",
    "key_form_other",
    "key_form_unknown",
    "examples_per_term_0",
    "examples_per_term_1",
    "examples_per_term_2",
    "examples_per_term_3",
    "examples_per_term_4_plus",
    "example_length_1_10",
    "example_length_11_20",
    "example_length_21_40",
    "example_length_41_80",
    "example_length_81_plus",
    "snapshot_entries",
    "snapshot_tokens_bucket",
    "corrections_candidate_choice",
    "corrections_reconversion",
    "corrections_reconstructed_reconversion",
    "corrections_retype",
    "suggestions_created",
    "suggestion_accepts",
    "suggestion_dismissals",
    "manual_adds",
    "term_edits",
    "term_deletes",
    "delete_age_under_1d",
    "delete_age_1_7d",
    "delete_age_8_30d",
    "delete_age_31_90d",
    "delete_age_91d_plus",
    "fire_key_matches",
    "fire_already_correct",
    "fire_missed",
    "fire_applied_kept",
    "fire_offered_kept",
    "fire_overridden",
    "snapshot_builds",
    "snapshot_changes",
)
TERM_SNAPSHOT_TOKEN_BUCKETS = {"0", "1", "256", "512", "1024", "2048", "4096", "8192"}
TERM_SNAPSHOT_CAPACITY = 64

COMMON_FIELDS = {
    "schema_version",
    "event",
    "process_role",
    "release",
    "macos_version",
    "environment",
}
EVENT_FIELDS = {
    "usage_summary": COMMON_FIELDS
    | {
        "window_seconds",
        "conversions_started",
        "conversions_applied",
        "conversions_failed",
        "conversions_rejected",
        "conversions_stale",
        "candidate_requests",
        "candidate_applies",
        "shortcut_attempts",
        "shortcut_successes",
    },
    "model_load_result": COMMON_FIELDS
    | {"success", "backend", "load_milliseconds", "error_code"},
    "setup_milestone": COMMON_FIELDS | {"milestone", "result"},
    "term_summary": COMMON_FIELDS | {"window_seconds"} | set(TERM_METRICS),
    "crash": COMMON_FIELDS
    | {"crash_id", "signal_name", "signal_code", "raw_signature", "frame_count", "frames"},
}
ENVELOPE_FIELDS = {
    "schema_version",
    "batch_id",
    "sent_at",
    "installation_id",
    "key_id",
    "public_key",
    "events",
}

ROLES = {"input_method", "setup", "shortcuts"}
ENVIRONMENTS = {"prod", "test"}
BACKENDS = {"metal", "cpu", "none"}
MILESTONES = {
    "privacy_preference_saved",
    "model_ready",
    "benchmark_complete",
    "restart_complete",
    "input_source_enabled",
    "shortcuts_complete",
    "special_terms_complete",
    "tutorial_complete",
}
RESULTS = {"success", "failed", "skipped"}
SAFE_RELEASE = re.compile(r"^[A-Za-z0-9._+\-]{1,64}$")
SAFE_OS = re.compile(r"^[0-9.]{1,16}$")
SAFE_UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")


class ValidationError(ValueError):
    """Stable, non-sensitive validation failure."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


@dataclass(frozen=True)
class ValidatedBatch:
    batch_id: str
    installation_id: str
    key_id: str
    sent_at: int
    events: list[dict[str, str]]


def _b64url_decode(value: str) -> bytes:
    if not isinstance(value, str) or len(value) > 256:
        raise ValidationError("invalid_encoding")
    try:
        return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
    except Exception as exc:
        raise ValidationError("invalid_encoding") from exc


def _require_exact_fields(value: dict[str, Any], allowed: set[str], reason: str) -> None:
    if set(value) != allowed:
        raise ValidationError(reason)


def _integer_string(value: Any, maximum: int = 2_147_483_647) -> str:
    if not isinstance(value, str) or not value.isascii() or not value.isdigit():
        raise ValidationError("invalid_event_value")
    number = int(value)
    if number < 0 or number > maximum:
        raise ValidationError("invalid_event_value")
    return value


def _validate_event(event: Any) -> dict[str, str]:
    if not isinstance(event, dict):
        raise ValidationError("invalid_event")
    name = event.get("event")
    if name not in EVENT_FIELDS:
        raise ValidationError("unknown_event")
    _require_exact_fields(event, EVENT_FIELDS[name], "unknown_event_field")
    if not all(isinstance(key, str) and isinstance(value, str) for key, value in event.items()):
        raise ValidationError("invalid_event_value")
    if event["schema_version"] not in EVENT_SCHEMA_VERSIONS.get(name, SCHEMA_VERSIONS):
        raise ValidationError("unknown_schema")
    if event["process_role"] not in ROLES or event["environment"] not in ENVIRONMENTS:
        raise ValidationError("invalid_event_value")
    if not SAFE_RELEASE.fullmatch(event["release"]) or not SAFE_OS.fullmatch(event["macos_version"]):
        raise ValidationError("invalid_event_value")

    if name == "usage_summary":
        for key in EVENT_FIELDS[name] - COMMON_FIELDS:
            _integer_string(event[key])
    elif name == "model_load_result":
        if event["success"] not in {"true", "false"} or event["backend"] not in BACKENDS:
            raise ValidationError("invalid_event_value")
        _integer_string(event["load_milliseconds"], 3_600_000)
        _integer_string(event["error_code"], 100)
    elif name == "setup_milestone":
        if event["milestone"] not in MILESTONES or event["result"] not in RESULTS:
            raise ValidationError("invalid_event_value")
    elif name == "term_summary":
        if event["window_seconds"] != "86400":
            raise ValidationError("invalid_event_value")
        for key in TERM_METRICS:
            _integer_string(event[key])
        if event["snapshot_tokens_bucket"] not in TERM_SNAPSHOT_TOKEN_BUCKETS:
            raise ValidationError("invalid_event_value")
        _integer_string(event["snapshot_entries"], TERM_SNAPSHOT_CAPACITY)
    elif name == "crash":
        try:
            crash_id = str(uuid.UUID(event["crash_id"])).lower()
            frames = json.loads(event["frames"])
        except Exception as exc:
            raise ValidationError("invalid_event_value") from exc
        if crash_id != event["crash_id"] or not re.fullmatch(r"[0-9a-f]{64}", event["raw_signature"]):
            raise ValidationError("invalid_event_value")
        if not isinstance(frames, list) or len(frames) != int(_integer_string(event["frame_count"], 64)):
            raise ValidationError("invalid_event_value")
        for frame in frames:
            if not isinstance(frame, dict) or set(frame) != {"image_kind", "image_uuid", "image_offset"}:
                raise ValidationError("invalid_event_value")
            if frame["image_kind"] not in {"app", "system"}:
                raise ValidationError("invalid_event_value")
            if not isinstance(frame["image_uuid"], str) or not re.fullmatch(r"[0-9a-f-]{32,36}", frame["image_uuid"]):
                raise ValidationError("invalid_event_value")
            if not isinstance(frame["image_offset"], int) or not 0 <= frame["image_offset"] <= 2**63 - 1:
                raise ValidationError("invalid_event_value")
    return event


def validate_signed_batch(raw_body: bytes, signature_header: str | None, now: int | None = None) -> ValidatedBatch:
    if not raw_body or len(raw_body) > MAX_BODY_BYTES:
        raise ValidationError("invalid_body_size")
    try:
        body = json.loads(raw_body)
    except Exception as exc:
        raise ValidationError("invalid_json") from exc
    if not isinstance(body, dict):
        raise ValidationError("invalid_envelope")
    _require_exact_fields(body, ENVELOPE_FIELDS, "unknown_envelope_field")
    if body["schema_version"] != 1:
        raise ValidationError("unknown_schema")

    try:
        batch_id = str(uuid.UUID(body["batch_id"])).lower()
        installation_id = str(uuid.UUID(body["installation_id"])).lower()
    except Exception as exc:
        raise ValidationError("invalid_identifier") from exc
    if batch_id != body["batch_id"] or installation_id != body["installation_id"]:
        raise ValidationError("invalid_identifier")
    if not SAFE_UUID.fullmatch(installation_id):
        raise ValidationError("invalid_identifier")

    sent_at = body["sent_at"]
    if not isinstance(sent_at, int):
        raise ValidationError("invalid_timestamp")
    current = int(time.time()) if now is None else now
    if abs(current - sent_at) > MAX_CLOCK_SKEW_SECONDS:
        raise ValidationError("expired_batch")

    public_key = _b64url_decode(body["public_key"])
    signature = _b64url_decode(signature_header or "")
    if len(public_key) != 32 or len(signature) != 64:
        raise ValidationError("invalid_signature")
    key_id = hashlib.sha256(public_key).hexdigest()
    if body["key_id"] != key_id:
        raise ValidationError("invalid_key_id")
    try:
        Ed25519PublicKey.from_public_bytes(public_key).verify(signature, raw_body)
    except (ValueError, InvalidSignature) as exc:
        raise ValidationError("invalid_signature") from exc

    events = body["events"]
    if not isinstance(events, list) or not (1 <= len(events) <= MAX_EVENTS_PER_BATCH):
        raise ValidationError("invalid_event_count")
    return ValidatedBatch(
        batch_id=batch_id,
        installation_id=installation_id,
        key_id=key_id,
        sent_at=sent_at,
        events=[_validate_event(event) for event in events],
    )

import base64
import json
import os
import sys
import time
import unittest
import uuid

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

sys.path.insert(0, os.path.dirname(__file__))
import index
from sls_sink import SLSSink


class FakeSink:
    def __init__(self):
        self.rows = []

    def put(self, rows):
        self.rows.extend(rows)


class FakeLogClient:
    def __init__(self):
        self.request = None

    def put_logs(self, request):
        self.request = request


def b64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


def fixture_event(name, version=None):
    root = os.path.dirname(os.path.dirname(__file__))
    parts = [root, "Contract", "Fixtures"] + ([version] if version else []) + [name + ".json"]
    with open(os.path.join(*parts), encoding="utf-8") as handle:
        return json.load(handle)


def signed_request(extra_event=None, event=None, events=None):
    private = Ed25519PrivateKey.generate()
    public = private.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    import hashlib

    event = dict(event or fixture_event("usage-summary"))
    event.update(extra_event or {})
    body = {
        "schema_version": 1,
        "batch_id": str(uuid.uuid4()),
        "sent_at": int(time.time()),
        "installation_id": str(uuid.uuid4()),
        "key_id": hashlib.sha256(public).hexdigest(),
        "public_key": b64url(public),
        "events": events if events is not None else [event],
    }
    raw = json.dumps(body, separators=(",", ":"), sort_keys=True).encode()
    return {
        "rawPath": "/events",
        "body": raw.decode(),
        "isBase64Encoded": False,
        "headers": {"x-chiboard-signature": b64url(private.sign(raw))},
        "requestContext": {"http": {"method": "POST"}},
    }


class CollectorTests(unittest.TestCase):
    def setUp(self):
        index.reset_test_state()
        self.sink = FakeSink()
        index._sink = self.sink

    def call(self, request):
        return index.handler(json.dumps(request).encode(), None)

    def test_accepts_only_allowlisted_event_and_flattens_metadata(self):
        response = self.call(signed_request())
        self.assertEqual(response["statusCode"], 202)
        self.assertEqual(len(self.sink.rows), 1)
        row = self.sink.rows[0]
        self.assertEqual(row["region_group"], "Unknown")
        self.assertNotIn("public_key", row)
        self.assertNotIn("ip", row)

    def test_accepts_every_versioned_golden_fixture(self):
        for name in ("usage-summary", "model-load-result", "setup-milestone", "crash", "term-summary"):
            response = self.call(signed_request(event=fixture_event(name)))
            self.assertEqual(response["statusCode"], 202, name)

    def test_still_accepts_version_1_events_from_earlier_releases(self):
        for name in ("usage-summary", "model-load-result", "setup-milestone", "crash"):
            event = fixture_event(name, version="v1")
            self.assertEqual(event["schema_version"], "1")
            response = self.call(signed_request(event=event))
            self.assertEqual(response["statusCode"], 202, name)

    def test_rejects_unknown_schema_version(self):
        response = self.call(signed_request({"schema_version": "3"}))
        self.assertEqual(response["statusCode"], 400)
        self.assertIn("unknown_schema", response["body"])

    def test_term_summary_requires_version_2(self):
        event = fixture_event("term-summary")
        event["schema_version"] = "1"
        response = self.call(signed_request(event=event))
        self.assertEqual(response["statusCode"], 400)
        self.assertIn("unknown_schema", response["body"])

    def test_term_summary_rejects_unknown_or_missing_fields(self):
        for extra in ({"term": "SENTINEL"}, {"term_keys": "chibi"}, {"term_hash": "0" * 64}, {"example_text": "x"}):
            response = self.call(signed_request(extra, event=fixture_event("term-summary")))
            self.assertEqual(response["statusCode"], 400, extra)
            self.assertIn("unknown_event_field", response["body"])
        event = fixture_event("term-summary")
        del event["fire_missed"]
        response = self.call(signed_request(event=event))
        self.assertEqual(response["statusCode"], 400)
        self.assertIn("unknown_event_field", response["body"])
        self.assertEqual(self.sink.rows, [])

    def test_term_summary_values_are_bounded_integers(self):
        for field, value in (
            ("fire_key_matches", "驰笔"),
            ("fire_key_matches", "-1"),
            ("fire_key_matches", "1.5"),
            ("fire_key_matches", "2147483648"),
            ("snapshot_tokens_bucket", "300"),
            ("snapshot_entries", "65"),
            ("window_seconds", "1800"),
        ):
            response = self.call(signed_request({field: value}, event=fixture_event("term-summary")))
            self.assertEqual(response["statusCode"], 400, (field, value))
            self.assertIn("invalid_event_value", response["body"])
        self.assertEqual(self.sink.rows, [])

    def test_rejects_oversized_body_and_batch(self):
        oversized = signed_request()
        oversized["body"] = "x" * (64 * 1024 + 1)
        response = self.call(oversized)
        self.assertEqual(response["statusCode"], 400)
        self.assertIn("invalid_body_size", response["body"])

        event = fixture_event("usage-summary")
        response = self.call(signed_request(events=[event] * 51))
        self.assertEqual(response["statusCode"], 400)
        self.assertIn("invalid_event_count", response["body"])

    def test_rejects_unsafe_crash_frame(self):
        crash = fixture_event("crash")
        frames = json.loads(crash["frames"])
        frames[0]["path"] = "/Users/example/private"
        crash["frames"] = json.dumps(frames, separators=(",", ":"), sort_keys=True)
        response = self.call(signed_request(event=crash))
        self.assertEqual(response["statusCode"], 400)
        self.assertIn("invalid_event_value", response["body"])

    def test_rejects_sensitive_or_unknown_field(self):
        response = self.call(signed_request({"typed_text": "SENTINEL"}))
        self.assertEqual(response["statusCode"], 400)
        self.assertEqual(self.sink.rows, [])
        self.assertIn("unknown_event_field", response["body"])

    def test_rejects_modified_body(self):
        request = signed_request()
        request["body"] += " "
        response = self.call(request)
        self.assertEqual(response["statusCode"], 400)
        self.assertIn("invalid_signature", response["body"])

    def test_health_contains_no_runtime_detail(self):
        response = self.call({"rawPath": "/health", "requestContext": {"http": {"method": "GET"}}})
        self.assertEqual(response["statusCode"], 200)
        self.assertEqual(json.loads(response["body"]), {"status": "ok", "schema_version": 1})

    def test_sls_rows_are_encoded_as_log_contents(self):
        sink = SLSSink.__new__(SLSSink)
        sink.project = "project"
        sink.logstore = "events"
        sink.client = FakeLogClient()
        sink.put([{"event": "usage_summary", "window_seconds": "1800"}])
        items = sink.client.request.get_log_items()
        self.assertEqual(sink.client.request.get_source(), "chiboard_collector")
        self.assertEqual(
            items[0].get_contents(),
            [("event", "usage_summary"), ("window_seconds", "1800")],
        )


if __name__ == "__main__":
    unittest.main()

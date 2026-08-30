"""Alibaba Function Compute HTTP handler for Chiboard telemetry."""

from __future__ import annotations

import base64
import json
import os
import threading
import time
from collections import defaultdict, deque
from typing import Any

from aliyun.log import LogException

from schema import ValidationError, validate_signed_batch
from sls_sink import SLSSink, TemporaryCredentials


_sink: SLSSink | None = None
_lock = threading.Lock()
_recent_batches: dict[str, float] = {}
_key_requests: dict[str, deque[float]] = defaultdict(deque)
RATE_WINDOW_SECONDS = 60
RATE_LIMIT_BATCHES = 12


def _response(status: int, payload: dict[str, Any]) -> dict[str, Any]:
    return {
        "statusCode": status,
        "headers": {
            "content-type": "application/json; charset=utf-8",
            "cache-control": "no-store",
            "x-content-type-options": "nosniff",
        },
        "isBase64Encoded": False,
        "body": json.dumps(payload, separators=(",", ":")),
    }


def _header(headers: dict[str, Any], name: str) -> str | None:
    lowered = name.lower()
    for key, value in headers.items():
        if key.lower() == lowered and isinstance(value, str):
            return value
    return None


def _allow(key_id: str, batch_id: str, now: float) -> bool:
    with _lock:
        for key, seen_at in list(_recent_batches.items()):
            if now - seen_at > 24 * 60 * 60:
                del _recent_batches[key]
        if batch_id in _recent_batches:
            return False
        requests = _key_requests[key_id]
        while requests and now - requests[0] > RATE_WINDOW_SECONDS:
            requests.popleft()
        if len(requests) >= RATE_LIMIT_BATCHES:
            return False
        requests.append(now)
        _recent_batches[batch_id] = now
        return True


def _get_sink(context: Any) -> SLSSink:
    global _sink
    if _sink is not None and not hasattr(_sink, "credential_key"):
        return _sink
    credentials = TemporaryCredentials.from_context(context)
    credential_key = (credentials.access_key_id, credentials.security_token)
    if _sink is None or _sink.credential_key != credential_key:
        _sink = SLSSink(credentials)
    return _sink


def handler(event: bytes, context: Any) -> dict[str, Any]:
    """Handle only /health and signed POST /events requests.

    Raw bodies, headers, source addresses, and validation values are never
    logged. Function Compute request logging must also remain disabled.
    """
    try:
        request = json.loads(event)
    except Exception:
        return _response(400, {"accepted": False, "reason": "invalid_request"})

    path = request.get("rawPath", "")
    method = request.get("requestContext", {}).get("http", {}).get("method", "")
    if path == "/health" and method == "GET":
        return _response(200, {"status": "ok", "schema_version": 1})
    if path != "/events" or method != "POST":
        return _response(404, {"accepted": False, "reason": "not_found"})

    body_value = request.get("body", "")
    try:
        raw_body = (
            base64.b64decode(body_value, validate=True)
            if request.get("isBase64Encoded")
            else body_value.encode("utf-8")
        )
    except Exception:
        return _response(400, {"accepted": False, "reason": "invalid_body"})

    try:
        batch = validate_signed_batch(
            raw_body,
            _header(request.get("headers", {}), "x-chiboard-signature"),
        )
        if not _allow(batch.key_id, batch.batch_id, time.time()):
            return _response(429, {"accepted": False, "reason": "rate_or_replay"})

        received_at = str(int(time.time()))
        rows = []
        for event_row in batch.events:
            row = dict(event_row)
            row.update(
                {
                    "batch_id": batch.batch_id,
                    "installation_id": batch.installation_id,
                    "key_id": batch.key_id,
                    "sent_at": str(batch.sent_at),
                    "received_at": received_at,
                    # IP-derived geography is intentionally not collected.
                    "region_group": "Unknown",
                }
            )
            rows.append(row)
        _get_sink(context).put(rows)
        return _response(202, {"accepted": True, "batch_id": batch.batch_id})
    except ValidationError as exc:
        return _response(400, {"accepted": False, "reason": exc.reason})
    except RuntimeError as exc:
        reason = "function_role_unavailable" if str(exc) == "missing_function_role" else "storage_unavailable"
        return _response(503, {"accepted": False, "reason": reason})
    except KeyError:
        return _response(503, {"accepted": False, "reason": "storage_configuration_unavailable"})
    except LogException as exc:
        code = exc.get_error_code().lower()
        if any(value in code for value in ("unauthorized", "signature", "securitytoken", "accessdenied", "forbidden")):
            reason = "storage_permission_denied"
        elif "project" in code or "logstore" in code:
            reason = "storage_target_unavailable"
        elif "request" in code or "timeout" in code:
            reason = "storage_endpoint_unavailable"
        else:
            reason = "storage_rejected"
        return _response(503, {"accepted": False, "reason": reason})
    except Exception:
        # Do not echo provider errors or request values to the client/logs.
        return _response(503, {"accepted": False, "reason": "temporarily_unavailable"})


def reset_test_state() -> None:
    global _sink
    with _lock:
        _sink = None
        _recent_batches.clear()
        _key_requests.clear()

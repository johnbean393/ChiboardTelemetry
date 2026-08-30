"""Minimal SLS writer using Function Compute's temporary role credentials."""

from __future__ import annotations

import os
import time
from dataclasses import dataclass
from typing import Any, Iterable

from aliyun.log import LogClient, LogItem, PutLogsRequest


@dataclass(frozen=True)
class TemporaryCredentials:
    access_key_id: str
    access_key_secret: str
    security_token: str

    @classmethod
    def from_context(cls, context: Any) -> "TemporaryCredentials":
        # Python 3.12 injects assumed-role credentials as environment variables;
        # older runtimes expose the same temporary values on context.credentials.
        environment_values = (
            os.environ.get("ALIBABA_CLOUD_ACCESS_KEY_ID"),
            os.environ.get("ALIBABA_CLOUD_ACCESS_KEY_SECRET"),
            os.environ.get("ALIBABA_CLOUD_SECURITY_TOKEN"),
        )
        if all(isinstance(value, str) and value for value in environment_values):
            return cls(*environment_values)  # type: ignore[arg-type]

        value = getattr(context, "credentials", None)
        if value is None:
            raise RuntimeError("missing_function_role")

        def field(*names: str) -> str:
            for name in names:
                candidate = value.get(name) if isinstance(value, dict) else getattr(value, name, None)
                if isinstance(candidate, str) and candidate:
                    return candidate
            raise RuntimeError("missing_function_role")

        return cls(
            access_key_id=field("access_key_id", "accessKeyId"),
            access_key_secret=field("access_key_secret", "accessKeySecret"),
            security_token=field("security_token", "securityToken"),
        )


class SLSSink:
    def __init__(self, credentials: TemporaryCredentials) -> None:
        endpoint = os.environ.get("CHIBOARD_SLS_ENDPOINT", "cn-hongkong-intranet.log.aliyuncs.com")
        self.project = os.environ["CHIBOARD_SLS_PROJECT"]
        self.logstore = os.environ.get("CHIBOARD_SLS_LOGSTORE", "events")
        self.credential_key = (credentials.access_key_id, credentials.security_token)
        self.client = LogClient(
            endpoint,
            credentials.access_key_id,
            credentials.access_key_secret,
            securityToken=credentials.security_token,
        )

    def put(self, rows: Iterable[dict[str, str]]) -> None:
        items = [
            LogItem(
                timestamp=int(time.time()),
                contents=[(key, value) for key, value in sorted(row.items())],
            )
            for row in rows
        ]
        if items:
            # Set a fixed source so the SDK never substitutes an IP-like value.
            self.client.put_logs(
                PutLogsRequest(
                    project=self.project,
                    logstore=self.logstore,
                    topic="",
                    source="chiboard_collector",
                    logitems=items,
                )
            )

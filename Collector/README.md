# Chiboard telemetry collector

This Python 3.12 Function Compute service accepts signed `POST /events`
batches, rejects every unknown event or field, and writes the allowlisted flat
records to the Hong Kong SLS `events` logstore. `GET /health` is unauthenticated
and contains no deployment details.

Privacy constraints:

- Function Compute request/access logging is disabled.
- The service never stores request bodies, headers, source IP addresses, or
  provider error text.
- IP geography is not derived; `region_group` is always `Unknown`.
- The function uses temporary execution-role credentials injected by Function
  Compute. No Alibaba credential is stored in the application or repository.
- Unknown schema versions, event names, or fields fail closed.

Deploy the directory as a Python 3.12 code package with handler
`index.handler`. Configure `CHIBOARD_SLS_PROJECT`, `CHIBOARD_SLS_LOGSTORE`, and
`CHIBOARD_SLS_ENDPOINT`; assign the scoped execution role in `../ram`.


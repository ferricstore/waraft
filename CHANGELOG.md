# Changelog

## 0.1.1 - 2026-10-01

- Preserve the absolute deadline of a pending commit batch when follower
  acknowledgements reschedule the leader heartbeat timer. This prevents a short
  batching window from being postponed to the periodic heartbeat interval.
- Keep idle, handover, and in-flight async-append timers from spinning on an
  expired batching deadline. Quorum, persistence, and application semantics are
  unchanged.
- Add deadline regressions and run EUnit checks in CI.

## 0.1.0 - 2026-06-02

Initial FerricStore-maintained WARaft distribution.

- Extracted `wa_raft` into its own public repository.
- Preserved Apache-2.0 license and original copyright notices.
- Preserved OTP app name `wa_raft`, module names, headers, and public API shape.
- Added package metadata for Apache-2.0 distribution.

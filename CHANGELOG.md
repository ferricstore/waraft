# Changelog

## 0.1.1 - 2026-10-16

- Fixed durability of the persisted term/vote state: the state file is now
  fsynced before being renamed into place and its directory is fsynced after
  the rename, a replica no longer grants a vote (or acknowledges an enable
  request) when persisting that state fails, and a disabled replica retries
  persisting its disable reason until it is durable instead of coming back
  enabled after a restart.
- Preserve the absolute deadline of a pending commit batch when follower
  acknowledgements reschedule the leader heartbeat timer. This prevents a short
  batching window from being postponed to the periodic heartbeat interval.
- Keep idle, handover, and in-flight async-append timers from spinning on an
  expired batching deadline. Quorum, persistence, and application semantics are
  unchanged.
- Adaptive commit batching is now in the tagged source: the first idle leader
  commit flushes immediately, while existing pending batches keep using the
  configured batch window and max-count policy. The 0.1.0 Hex package already
  shipped it; the `v0.1.0` Git tag did not.
- Add deadline, adaptive batching and persistence regressions, and run EUnit
  checks in CI.

## 0.1.0 - 2026-06-02

Initial FerricStore-maintained WARaft distribution.

- Extracted `wa_raft` into its own public repository.
- Preserved Apache-2.0 license and original copyright notices.
- Preserved OTP app name `wa_raft`, module names, headers, and public API shape.
- Added package metadata for Apache-2.0 distribution.

# Changelog

## 0.1.3 - 2026-10-24

- With async log append on (`raft_async_log_append`), a membership change made
  while a batch of commands was still being written could give its
  configuration entry the same log index as that batch, and whichever finished
  last overwrote the other. The leader now waits for the write in flight,
  commits it under the current configuration, and only then appends the
  change. If the write is still running after 5 seconds, the change fails with
  `{error, async_append_in_flight}` and the configuration is unchanged.
- A server that crashed rolling back a failed async append was restarted 5
  seconds late: shutting down waited for the append's worker, which had already
  exited, on a monitor that no longer existed. It now restarts at once.

## 0.1.2 - 2026-10-23

- With pre-vote on (`raft_election_pre_vote`), the only member of a cluster
  that lost leadership, for example when its server restarted, stayed a
  candidate and never took writes again: it waited for pre-votes from peers it
  does not have. A candidate whose own pre-vote is a majority now starts the
  election at once; members of larger clusters still wait for their peers.

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

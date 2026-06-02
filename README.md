# WARaft

WARaft is an Erlang implementation of the Raft consensus protocol.

This repository is a FerricStore-maintained distribution of Meta Platforms'
Apache-2.0 licensed WARaft code. It preserves the original copyright notices,
license, OTP application name, module names, and public API surface.

FerricStore uses WARaft as its durable consensus engine dependency.

## Status

- Package name: `wa_raft`
- OTP application: `wa_raft`
- Current release: `v0.1.0`
- License: Apache-2.0
- Runtime dependencies: none beyond Erlang/OTP `kernel` and `stdlib`

This repository is intended to be a stable, packageable WARaft dependency for
FerricStore and other Erlang/Elixir systems that need a pluggable Raft engine.

## Features

- Raft consensus implementation for replicated state machines.
- Pluggable storage, log, state machine, and transport behavior interfaces.
- Single-node bootstrap and multi-node membership support.
- Erlang/OTP supervision integration.
- No NIFs and no Rust code in this repository.

FerricStore's high-performance log/storage adapters live in the FerricStore
repository, not in this `wa_raft` package.

## Installation

### Git dependency

Until the Hex package is published, use the Git tag:

```erlang
{deps, [
    {wa_raft, {git, "https://github.com/ferricstore/waraft.git", {tag, "v0.1.0"}}}
]}.
```

For Elixir/Mix projects:

```elixir
{:wa_raft, github: "ferricstore/waraft", tag: "v0.1.0", manager: :rebar3}
```

### Hex dependency

After the Hex package is published:

```erlang
{deps, [
    {wa_raft, "0.1.0"}
]}.
```

For Elixir/Mix projects:

```elixir
{:wa_raft, "~> 0.1", manager: :rebar3}
```

## Quick start

The following example starts a single-node Raft partition and performs one write
and one read. It uses the built-in ETS log/storage path for demonstration.
Production systems should provide storage and log modules appropriate for their
durability and recovery requirements.

```erlang
rr(wa_raft_server).
application:ensure_all_started(wa_raft).
application:set_env(test_app, raft_database, ".").

Spec = wa_raft_sup:child_spec(test_app, [#{table => test, partition => 1}]).
supervisor:start_child(kernel_sup, Spec).

Config = wa_raft_server:make_config([
    #raft_identity{name = raft_server_test_1, node = node()}
]).

wa_raft_server:bootstrap(
    raft_server_test_1,
    #raft_log_pos{index = 1, term = 1},
    Config,
    #{}
).

wa_raft_server:status(raft_server_test_1).
wa_raft_acceptor:commit(raft_acceptor_test_1, {make_ref(), {write, test, key, 1000}}).
wa_raft_acceptor:read(raft_acceptor_test_1, {read, test, key}).
```

Expected read result:

```erlang
{ok, 1000}
```

## Public API orientation

The main modules are:

- `wa_raft_sup`: builds supervisor child specs for Raft tables/partitions.
- `wa_raft_server`: bootstrap, membership, status, promotion, and Raft server operations.
- `wa_raft_acceptor`: commit/read entry point used by clients.
- `wa_raft_storage`: behavior/API for state machine storage.
- `wa_raft_log`: behavior/API for Raft log implementations.
- `wa_raft_transport`: behavior/API for network transport.

Headers are included with:

```erlang
-include_lib("wa_raft/include/wa_raft.hrl").
```

That include path works for both Git and Hex dependencies because the OTP app is
named `wa_raft`.

## Development

```bash
rebar3 compile
rebar3 xref
rebar3 dialyzer
rebar3 edoc
```

Common local check:

```bash
rebar3 do compile,xref
```

## Versioning

This repository starts at `0.1.0` because it is a maintained distribution used by
FerricStore. The original upstream app version was not used as the package
release version here.

## License and attribution

WARaft is licensed under Apache-2.0. See [LICENSE](./LICENSE) and
[NOTICE](./NOTICE).

This repository preserves Meta Platforms' original copyright notices. FerricStore
maintains this distribution but does not claim Meta endorsement.

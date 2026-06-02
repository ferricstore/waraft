# Contributing to WARaft

Contributions are welcome when they keep the repository stable, dependency-safe,
and compatible with the existing `wa_raft` OTP application/API.

## Ground rules

- Keep the OTP application name as `wa_raft`.
- Keep the module prefix `wa_raft_*` unless there is a deliberate major-version plan.
- Preserve Apache-2.0 license and copyright notices.
- Avoid adding runtime dependencies unless there is a strong reason.
- Prefer small, focused pull requests.
- Include tests or a clear manual verification note for behavior changes.

## Local checks

Run at least:

```bash
rebar3 compile
rebar3 xref
```

For deeper checks:

```bash
rebar3 dialyzer
rebar3 edoc
```

If common-test suites are added later, run:

```bash
rebar3 ct
```

## Pull requests

A useful pull request includes:

- What changed.
- Why it changed.
- Compatibility impact.
- How it was tested.
- Whether the change affects FerricStore integration.

## License

By contributing, you agree that your contribution is licensed under Apache-2.0,
the same license as this repository.

## Security issues

Do not open public issues for vulnerabilities. See [SECURITY.md](./SECURITY.md).

## Outcome

What independently useful behavior does this pull request add or correct?

## Why this slice

Link the issue or roadmap item and explain what intentionally remains for later.
Draft pull requests are welcome.

## Contract and failure cases

- Authority or state this change can mutate:
- New success path:
- Malformed, stale, unsupported, or fault-injected inputs that reject:
- Compatibility or migration impact:

## Verification

List exact commands and results. Mark unsupported checks as **not run** and say
why.

```text
command
result
```

## Evidence boundary

What does the retained evidence prove, and what does it not prove? Distinguish
logical accounting from physical machine/device measurements.

## Checklist

- [ ] The change is focused and can be reverted independently.
- [ ] Tests cover the success path and named rejection paths.
- [ ] Public format or wire changes include versioning, golden fixtures, and mutation coverage.
- [ ] User-facing behavior and roadmap status are documented.
- [ ] No credentials, private prompts, large model files, local binaries, or unrelated workspace files are included.
- [ ] Performance wording follows `docs/EVIDENCE_POLICY.md` and retains raw artifacts when applicable.

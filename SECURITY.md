# Security Policy

Glacier Engine is experimental and has not received an independent security
audit. Do not use it as the sole boundary protecting secrets, untrusted model
files, or production billing.

## Supported versions

Security fixes target the latest commit on `main`. No released version currently
receives a long-term support guarantee.

## Report a vulnerability

Do not open a public issue for a vulnerability that could expose credentials,
corrupt evidence, escape a resource boundary, or cause unsafe parsing of
untrusted files.

Use GitHub's private vulnerability reporting for this repository. If that option
is unavailable, contact the repository owner through the private contact method
on their GitHub profile. Include:

- affected commit and platform;
- the smallest reproduction you can safely share;
- expected and observed behavior;
- likely impact and any known mitigations.

You should receive an acknowledgement within seven days. We will coordinate a
fix and disclosure timeline based on severity. Please avoid accessing data that
is not yours and stop testing once impact is demonstrated.

## Security boundaries

- Provider demos are credential-free and must stay that way.
- Core evidence records intentionally avoid storing prompt text, but callers are
  responsible for surrounding logs and transport payloads.
- Advisory file locks coordinate cooperating processes only.
- File digests and replay verification establish integrity, not trust in the
  original producer.
- Logical resource receipts do not prove operating-system or device isolation.

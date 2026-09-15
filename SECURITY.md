# Security policy

Arveil is an experimental implementation: a Go relay, Rust core and CLI,
plus a Flutter client foundation. Automated tests cover the documented
protocol and recovery scenarios. The project has not received an independent
security audit and does not claim production readiness.

## Reporting

- **Vulnerabilities, suspected exploits or exposed credentials:** use
  [private vulnerability reporting](https://github.com/Ulzuhan/arveil/security/advisories/new).
  Include the affected revision, impact and a minimal reproduction using
  disposable data. Do not include working credentials, backups or private
  deployment details in a public issue or pull request.
- **General design questions without an exploit or sensitive information:**
  open a public issue against the relevant ADR or threat-model section.

## Supported versions

Fixes target the current `main` branch. Older revisions have no separate
security-maintenance commitment. Check the release notes before upgrading;
database migrations can affect rollback.

## What counts

Anything that contradicts a stated guarantee in [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md), especially the verifiable invariants I-01 to I-13, or that shows an intermediary, the relay or the operator learning more than [section 3 of the threat model](docs/THREAT_MODEL.md#3-what-the-server-actually-knows) admits.

## What not to expect

No bug bounty or guaranteed response time. No claims of security beyond what
the documents state with their conditions. Public test vectors and disposable
demo identities are examples, never credentials for a shared deployment.

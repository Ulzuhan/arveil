# Security policy

Arveil is in its design phase. There is no release, no deployed instance and no audit. Even so, findings against the design are welcome and are the most useful contribution right now.

## Reporting

- **Design or protocol issues** (a flaw in an ADR, the threat model or the protocol draft): open a public GitHub issue. There is nothing to exploit yet, and public discussion improves the design.
- **Issues in code**, once code exists: use GitHub's private vulnerability reporting on this repository. Do not open a public issue for anything exploitable in a tagged release.

## What counts

Anything that contradicts a stated guarantee in [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md), especially the verifiable invariants I-01 to I-13, or that shows an intermediary, the relay or the operator learning more than [section 3 of the threat model](docs/THREAT_MODEL.md#3-what-the-server-actually-knows) admits.

## What not to expect

No bug bounty. No guaranteed response time during the design phase. No claims of security beyond what the documents state with their conditions.

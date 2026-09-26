# Contributing

Arveil is an experimental messenger with an implemented relay and CLI, and a
Flutter client under development. Start with the [README](README.md),
[architecture](docs/ARCHITECTURE.md) and [client milestones](docs/PHASE3B.md).
Use an issue to discuss changes to the protocol or a major feature first.
Report vulnerabilities through [SECURITY.md](SECURITY.md).

## Development and checks

Use the Go and Rust versions pinned in `relay/go.mod` and
`core/rust-toolchain.toml`. Flutter setup is in
[the client README](clients/flutter/README.md).

```sh
make build
make test
make lint
make docs-build
```

Run the acceptance script for the behavior you changed (`scripts/phase*.sh`),
and `flutter analyze` / `flutter test` from `clients/flutter` for Dart changes.
Keep dependency lockfiles and generated Rust/Dart bridge bindings committed.
Regenerate bindings when changing their API; do not edit generated code by hand.
In workflows, pin every action to a full commit SHA with its version as a
comment (`uses: owner/action@<sha> # v1.2.3`); Dependabot keeps the pins
current.

## Installation is part of a feature

Keep the [installation guide](docs/INSTALLATION.md) and its Spanish version
aligned with changes to setup, packaging or first use. State prerequisites,
expected success, known blockers and how to update without losing profile
access. A release must be installable from its published artifacts and guide
on a clean supported system; end users should not install a development
stack to run the app. Record actual installation/update acceptance and keep
unverified platforms explicit. Never include private deployment settings or
signing keys in examples or packages.

## Before publishing

Install [Gitleaks 8.30.1](https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1).
Stage only the intended files, then run:

```sh
git diff --cached --stat
git diff --cached --check
make hygiene-staged
```

`make hygiene` scans the current branch's complete history. CI runs this scan
on pull requests and `main`, with detected values redacted. Rules cover common
credentials, personal home paths, tailnet addresses and local-only artifacts.
The exceptions are limited to identified public test vectors and lockfile
dependency names; test directories are still scanned. A clean scan is one
check, not proof that a change contains no sensitive information.

- Keep passwords, keys, invites, `.env` files, SSH configuration, server
  inventories, backups, databases and logs outside Git. `.gitignore` also
  excludes local assistant notes and build output.
- Use shell variables or placeholders for deployments. Use `example.com`,
  loopback, or documentation IPs for public examples. Never paste a real
  tailnet address, machine name or personal absolute path into a PR or issue.
- Review command output and screenshots before attaching them. Even successful
  deployment logs can reveal infrastructure details.
- Use GitHub's private commit email if you do not want your email in public
  commit metadata. This is configured separately from the code scanner.
- If a credential has already been published, revoke or rotate it, then follow
  [GitHub's history cleanup procedure](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository).
  Deleting a line in a later commit does not remove prior copies.

## Pull requests

Describe the problem, the resulting behavior and the checks you ran. State
what remains unverified. Use disposable local data for reproductions and
keep changes small enough to review. The PR template is a starting point.

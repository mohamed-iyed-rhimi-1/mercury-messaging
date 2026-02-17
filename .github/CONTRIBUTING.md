# Contributing to Mercury Messaging

Thank you for your interest in contributing to Mercury. This document explains how to get started.

## Code of Conduct

By participating in this project, you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md).

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/<your-username>/mercury-messaging.git`
3. Install prerequisites (see [README](../README.md#prerequisites))
4. Start dev dependencies: `make dev`
5. Initialize databases: `make db-init`
6. Build Rust NIFs: `make nif`
7. Run tests: `make test`

## Development Workflow

```bash
# Create a feature branch
git checkout -b feat/your-feature

# Make changes, then verify
make lint
make test

# Commit with a clear message
git commit -m "feat: add channel archiving support"

# Push and open a PR
git push origin feat/your-feature
```

## Commit Messages

We follow [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` — New feature
- `fix:` — Bug fix
- `docs:` — Documentation only
- `refactor:` — Code change that neither fixes a bug nor adds a feature
- `test:` — Adding or updating tests
- `chore:` — Build process, CI, or tooling changes
- `perf:` — Performance improvement

## Coding Standards

### Rust

- `#![deny(warnings)]` on all production modules
- `clippy::pedantic` enabled — zero warnings
- Format with `rustfmt` (enforced in CI)
- All public functions must have doc comments and `# Errors` / `# Panics` sections where applicable
- Follow [Tiger Style](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md): simplest code that works, optimize for deletion
- Follow NASA safety-critical rules: bounded loops, assertions on invariants, no unbounded allocations in hot paths

### Elixir

- `mix format` enforced
- `mix credo --strict` — zero issues
- Dialyzer `@spec` on all public functions
- Use supervision trees and OTP patterns correctly
- Prefer pattern matching over conditionals

### TypeScript (JS SDK)

- `tsc --noEmit` must pass with zero errors
- All exports must have TypeScript types

## Pull Request Process

1. Ensure `make lint && make test` passes locally
2. Update documentation if you changed public APIs
3. Add an entry to the relevant ADR if you made an architectural decision
4. Fill out the PR template
5. Request review from a maintainer

## What to Work On

- Check [open issues](https://github.com/iyed/mercury-messaging/issues) for `good first issue` or `help wanted` labels
- See the [implementation status](../architecture.md#implementation-status) for remaining work
- Review the [phase plans](../docs/) for upcoming features

## Architecture Decision Records

If your change involves a significant technical decision, write an ADR in `docs/adr/`. Use the existing ADRs as a template:

```markdown
# ADR-NNN: Title

## Status: Proposed

## Context
What problem are we solving?

## Decision
What did we decide?

## Consequences
What are the trade-offs?
```

## Questions?

Open a [discussion](https://github.com/iyed/mercury-messaging/discussions) or file an [issue](https://github.com/iyed/mercury-messaging/issues).

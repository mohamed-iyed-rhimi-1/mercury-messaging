# ADR-001: Monorepo over Polyrepo

## Status: Accepted

## Context
Mercury has Rust crates, Elixir apps, Cap'n Proto schemas, SDK code, and
infrastructure config. We need to decide whether to use a single repository
or multiple repositories.

## Decision
Use a monorepo. All code lives in one repository.

## Consequences
- **Easier:** Atomic commits across Rust + Elixir + schemas. Single CI pipeline.
  Shared tooling. No version matrix between repos.
- **Harder:** Larger repo size over time. CI must be smart about what to rebuild
  (path-based triggers). Need clear directory boundaries to avoid coupling.

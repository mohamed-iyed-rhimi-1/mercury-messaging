# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 0.1.x   | ✅ Current |

## Reporting a Vulnerability

**Do not open a public issue for security vulnerabilities.**

Instead, please report security vulnerabilities via [GitHub Security Advisories](https://github.com/iyed/mercury-messaging/security/advisories/new).

You should receive an acknowledgment within 48 hours. We will work with you to understand the issue and coordinate a fix before any public disclosure.

## What Qualifies

- Authentication or authorization bypasses
- MLS encryption implementation flaws
- CRDT merge logic that causes data corruption
- Denial of service vulnerabilities in the gateway
- Dependency vulnerabilities with a known exploit
- Information disclosure (metadata leaks, sealed sender bypasses)

## What Does Not Qualify

- Vulnerabilities in dependencies without a known exploit path in Mercury
- Issues requiring physical access to the server
- Social engineering attacks
- Denial of service via rate-limited endpoints (by design)

## Disclosure Policy

- We aim to release a fix within 7 days of confirming a vulnerability
- We will credit reporters in the release notes (unless anonymity is requested)
- We follow coordinated disclosure — please allow us time to fix before publishing

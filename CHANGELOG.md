# Changelog

All notable changes to `my_nitter` are documented here.

## [v1.0] - 2026-09-07

Initial release of the deployment wrapper for a private, authenticated Nitter instance. This release covers the implementation history from `cf0f49a` through `37cd298`.

### Added

- Reproducible, multi-stage Docker builds of upstream Nitter at the exact pinned commit `1428b4c2b4246f92a7e5b2673438e5fb39fcc4a3`.
- Non-root Nitter runtime with generated configuration and an ephemeral Valkey cache.
- Local bootstrap tooling, HMAC key generation, Docker Compose lifecycle scripts, and a local Nitter + Valkey stack.
- Browser-based session provisioning through upstream Nitter tooling, including JSONL validation, restrictive permissions, and atomic replacement of the one-account session file.
- Idempotent GCP initialization, Secret Manager lifecycle management, and authenticated Cloud Run deployment.
- Cloud Run smoke tests covering service readiness, sidecars, secret mounts, scaling, billing mode, and authenticated HTTP requests.
- A pinned upstream-reference inspection/update helper.
- Documentation for local setup, GCP deployment, session refresh, security, troubleshooting, and the verified live Cloud Run hostname.

### Security and operations

- X username, password, and TOTP remain local; only `sessions.jsonl` and the Nitter HMAC key are sent to Secret Manager.
- Cloud Run remains authenticated by default and is configured for request-based billing, scale-to-zero, a maximum of one instance, and conservative concurrency.
- Stable, distinct secret mounts prevent Cloud Run Compose mount collisions and keep transient bootstrap secrets out of the final revision.
- Deployment and smoke-test output avoids exposing credentials, session tokens, or HMAC material.

### Fixes and hardening

- Improved browser-login element detection across visible containers, evaluated visibility states, and localized X login buttons.
- Added guards around browser input focus and session validation paths.
- Hardened Cloud Run deployment against changing service-update flags, localized scaling metadata, secret access permissions, and transient Compose secret cleanup.

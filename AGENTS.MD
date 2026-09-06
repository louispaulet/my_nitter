# Agent instructions

## Source of truth

Read `PLAN.MD` before making project changes. It defines the intended architecture, security model, implementation order, and acceptance criteria for this repository.

The project is a deployment wrapper around upstream [Nitter](https://github.com/zedeus/nitter). Keep upstream application code out of this repository; changes should normally be limited to deployment files, local tooling, configuration templates, tests, and documentation.

## Security rules

- Treat all X/Twitter credentials and session material as highly sensitive.
- Keep `X_USERNAME`, `X_PASSWORD`, and `X_TOTP_SECRET` on the local machine only, in an ignored `.env` file.
- Never print, commit, upload, or bake X credentials into Docker images, Docker build arguments, Cloud Build inputs, Cloud Run environment variables, or logs.
- Generate `sessions.jsonl` locally with upstream's browser-based session helper. Do not implement a replacement login flow and do not perform X login during Docker or Cloud Run startup.
- Treat `auth_token` and `ct0` in `sessions.jsonl` like passwords. Never display their values.
- Upload only the generated session file and the Nitter HMAC key to GCP Secret Manager. Do not upload the username, password, or TOTP seed.
- Never enable anonymous Cloud Run access by default.
- Do not use `set -x`, dump environments, or log full command lines when handling secrets.

If a secret is needed for a command, prefer passing it through a protected file or Secret Manager integration. Avoid command-line arguments when they could expose a secret through process listings.

## Architecture constraints

- Build upstream Nitter from an exact commit SHA stored in `NITTER_REF`; never build production images from an unpinned branch such as `master`.
- Keep the upstream checkout temporary and ignored under `.cache/nitter`; do not vendor it as `nitter/` in the repository.
- Run Nitter in Docker as a non-root user.
- Run Valkey beside Nitter as an ephemeral cache with no persistent volume.
- Use Cloud Run with one service containing Nitter and Valkey, minimum instances `0`, maximum instances `1`, request-based billing/CPU throttling, and conservative concurrency.
- Prefer authenticated Cloud Run deployment for the first release. Public access is an explicit later decision.
- Do not add Memorystore, VMs, GKE, Cloud SQL, VPC connectors, load balancers, Cloud Functions, Vercel, or rate-limit bypass mechanisms for the MVP.

## Required implementation order

Follow the sequence in `PLAN.MD`:

1. Inspect the repository and pin the current upstream Nitter commit.
2. Add `.gitignore`, `.dockerignore`, `.env.example`, and the planned directory structure.
3. Add and validate the pinned multi-stage Docker build.
4. Add bootstrap tooling, local HMAC generation, and the browser-based session wrapper.
5. Add the Nitter configuration template, entrypoint, local Compose file, and local convenience scripts.
6. Validate a real local Nitter homepage, profile, post, search, and media request before touching GCP.
7. Add deployment configuration, GCP initialization, Secret Manager lifecycle, Cloud Run deployment, and smoke tests.
8. Validate the authenticated Cloud Run service, cold start, scale-to-zero behavior, and one-instance limit.
9. Run the final secret audit and update documentation.

Never use GCP debugging to investigate a local X-session or Nitter authentication failure. Fix the local milestone first.

## File and script expectations

- Shell scripts must fail clearly on missing prerequisites and use robust error handling. Bash scripts should use `set -euo pipefail`; the POSIX entrypoint should use `set -eu`.
- Session and HMAC files must be written with restrictive permissions (`600`) and session updates must be atomic.
- `create_session.py` must validate every JSONL record without printing token values, and should replace a one-account session file only after the new file passes validation.
- `deploy.sh` must read deployment configuration separately from local X credentials, update Secret Manager versions idempotently, and report only non-sensitive deployment metadata.
- Tests must cover session validation without real credentials. Do not add brittle tests around the live X login flow.
- Keep generated files, `.cache/`, `.venv/`, `.env`, `deploy.env`, and secret material ignored by Git and Docker.

## Verification before handing off

At minimum, inspect `git status`, verify the upstream reference is an exact SHA, run available shell/Python checks, and confirm that no credential values or session tokens appear in repository files, Docker build context, image layers, or command output. Report any unverified local, Docker, or GCP milestone explicitly rather than implying that it passed.

## Git workflow

After every repository change, create a commit and push it to the current branch immediately, including when the current branch is `main`. Do not accumulate unrelated changes between commits. Before each push, review the staged diff and run the relevant checks; never commit credentials, session tokens, generated environments, or other ignored secret material.

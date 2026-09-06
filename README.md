# my_nitter

A small, cost-conscious deployment wrapper for a personal, self-hosted [Nitter](https://github.com/zedeus/nitter) instance.

This repository is intentionally designed around upstream Nitter rather than a fork. The local X/Twitter login is used once to produce a session file; only that session and Nitter's HMAC key are sent to GCP Secret Manager. The X password and TOTP seed never leave the local machine.

The deployment wrapper, Docker build, local Compose stack, session validator, GCP scripts, and smoke tests are implemented. The local X session and authenticated Cloud Run deployment have been validated against the configured project.

## What this is

The target deployment runs:

- Nitter in a pinned, reproducible Docker build.
- Valkey beside Nitter as an ephemeral cache.
- Both containers in one Cloud Run service.
- Cloud Run configured to scale to zero and to use at most one instance.
- Authenticated Cloud Run access by default.

The design is for occasional personal usage, not for a public, high-traffic service.

## Architecture

```text
Local machine
  .env (X username/password/optional TOTP)
      │ browser-based upstream session helper
      ▼
  secrets/sessions.jsonl + secrets/hmac_key
      │ session and HMAC key only
      ▼
GCP Secret Manager
      │ mounted at runtime
      ▼
Cloud Run service (min 0, max 1)
  ├── Nitter :8080
  └── Valkey :6379 (ephemeral cache)
      │
      ▼
  X/Twitter
```

The upstream Nitter commit is pinned through `NITTER_REF`. Do not use `master` as a production build reference. The initial upstream `master` SHA observed for this plan is `1428b4c2b4246f92a7e5b2673438e5fb39fcc4a3`; verify it again before placing it in local configuration.

## Security model

Create `.env` locally from `.env.example` and keep these values local:

```dotenv
X_USERNAME=
X_PASSWORD=
X_TOTP_SECRET=
NITTER_REF=
```

The browser-based upstream helper converts the local credentials into `secrets/sessions.jsonl`, containing authenticated session material such as `auth_token` and `ct0`. Those values are equivalent to credentials and must never be printed, committed, emailed, pasted into issues, or baked into an image.

Production receives only:

- `sessions.jsonl`, stored as a Secret Manager secret.
- Nitter's generated HMAC key, stored as a separate Secret Manager secret.

Cloud Run must not receive `X_USERNAME`, `X_PASSWORD`, or `X_TOTP_SECRET` as environment variables or secrets. The deployment is authenticated initially; anonymous public access is deliberately opt-in because every visitor would consume the single X session's capacity.

## Requirements

Install or configure these tools before using the corresponding workflow:

- Git
- Python 3
- Docker with Compose support
- OpenSSL
- `gcloud` CLI authenticated to a GCP project for deployment, with the `run-compose` component (`gcloud components install run-compose`)

The plan uses `europe-west1` by default and expects an existing GCP project.

## First-time setup

Clone the repository and create local configuration:

```bash
git clone https://github.com/louispaulet/my_nitter.git
cd my_nitter

cp .env.example .env
chmod 600 .env
```

Fill `.env` with the local X account values and an exact upstream commit SHA. Do not commit `.env`.

Then bootstrap the ignored upstream checkout and Python environment:

```bash
./scripts/bootstrap.sh
```

The bootstrap process should keep upstream Nitter under `.cache/nitter`, create `.venv`, install the versions specified by upstream's `tools/requirements.txt`, and create `secrets/hmac_key` once if it does not already exist.

## Create X session

Generate a fresh session locally with the upstream browser-based helper:

```bash
./scripts/create_session.py
```

The wrapper should validate and atomically replace `secrets/sessions.jsonl` only after successful JSONL validation. It must not use the deprecated HTTP-only login helper, reimplement X authentication, or print credential/session values.

Before local startup, confirm that the session file exists and is protected:

```bash
ls -l secrets/sessions.jsonl secrets/hmac_key
```

Both files should be readable only by the current user. Never include their contents in diagnostic output.

## Run locally

Start Nitter and Valkey with the local Compose configuration:

```bash
./scripts/local-up.sh
```

Open [http://localhost:8080](http://localhost:8080), then test a homepage, a profile, an individual post, search, and media proxying. Also check the basic HTTP response:

```bash
curl -I http://localhost:8080/
```

Inspect logs for startup and Valkey connectivity, but never log `sessions.jsonl`, `.env`, the HMAC key, or the full environment. Stop the local service with:

```bash
./scripts/local-down.sh
```

Do not begin GCP work until local Nitter can fetch a real profile and post successfully.

## Configure GCP

Create deployment configuration separately from the local X credentials:

```bash
cp deploy.env.example deploy.env
```

Fill it with non-secret deployment values:

```dotenv
GCP_PROJECT_ID=my-project
GCP_REGION=europe-west1
CLOUD_RUN_SERVICE=my-nitter
```

Authenticate and initialize the project:

```bash
gcloud auth login
./scripts/gcp-init.sh
```

Initialization should validate the active account/project and enable only the required APIs: Cloud Resource Manager, Cloud Run, Cloud Build, Artifact Registry, and Secret Manager. It should be safe to run more than once.

## Deploy

After local validation and GCP initialization:

```bash
./scripts/deploy.sh
```

The deployment should:

1. Read `deploy.env` and the pinned `NITTER_REF` without uploading local X credentials.
2. Validate `secrets/sessions.jsonl` and `secrets/hmac_key`.
3. Create or add versions to the `my-nitter-sessions` and `my-nitter-hmac` Secret Manager secrets.
4. Grant the default Cloud Run runtime identity read access to those two secrets.
5. Deploy Nitter and Valkey as one Cloud Run service.
6. Configure minimum instances `0`, maximum instances `1`, request-based billing/CPU throttling, and modest concurrency.
7. Keep Cloud Run authenticated unless public access was explicitly requested later.

Cloud Run Compose currently gives each Compose secret the default `/run/secrets` mount directory. Mounting both secrets there is rejected by Cloud Run, so `compose.cloudrun.yaml` uses the session secret only for the initial Compose revision. `deploy.sh` then replaces that transient mount with two stable Secret Manager mounts at `/run/secrets/sessions/nitter_sessions` and `/run/secrets/hmac/nitter_hmac`, disables the temporary bootstrap HMAC, and removes the transient Compose-created session secret.

The script should print only non-sensitive metadata such as service, region, URL, pinned reference, access mode, and scaling settings. It must explicitly confirm that the X password and TOTP seed were not uploaded.

## Test deployment

The initial service is authenticated. Run:

```bash
./scripts/smoke-test.sh
```

The smoke test should verify the Cloud Run service and ready revision, Nitter and Valkey containers, the `:8080` ingress, Secret Manager mounts, min/max instance settings, and request-based billing. It should make only a few authenticated requests, including the homepage and one real profile.

For a manual request:

```bash
SERVICE_URL="$(gcloud run services describe my-nitter \
  --region europe-west1 \
  --format='value(status.url)')"

curl --fail --show-error \
  -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
  "$SERVICE_URL/"
```

After deployment, verify the cold-start path: the service reaches zero instances, Valkey starts, Nitter waits for Valkey, Nitter loads the mounted session, and the first profile request succeeds. A warm request should then work normally.

## Refresh X session

Session refresh is manual and local. If X invalidates the current session:

```bash
rm secrets/sessions.jsonl
./scripts/create_session.py
./scripts/deploy.sh
```

The deployment should add a new Secret Manager version rather than destroying the secret or keeping dead sessions in the active file. Do not perform X login in Cloud Run or Cloud Build.

## Upgrade Nitter

Check the latest upstream commit without changing or deploying anything:

```bash
./scripts/update-nitter-ref.sh
```

For an upgrade:

1. Record the new exact SHA in `.env`.
2. Rebuild the image locally.
3. Run the full local validation.
4. Commit the reference change.
5. Deploy and run the smoke test.

Do not set `NITTER_REF=master` in production and do not vendor the upstream checkout.

## Make Cloud Run public

Anonymous access is not enabled by default. Only after authenticated deployment and testing are complete should you consider:

```bash
gcloud run services add-iam-policy-binding my-nitter \
  --region europe-west1 \
  --member="allUsers" \
  --role="roles/run.invoker"
```

Public access means arbitrary visitors and automated scanners can consume the X account session and its rate limits. Consider an access layer such as Cloudflare Access before exposing a personal instance publicly.

## Troubleshooting

### Missing local configuration

Create `.env` and `deploy.env` from their example files. Do not solve missing configuration by putting credentials in scripts or command-line arguments.

### Session or authentication errors

Stop GCP debugging and regenerate the session locally. Check that the JSONL file contains valid records with the required fields (`kind`, `username`, `id`, `auth_token`, and `ct0`) without printing their values. Confirm the file path is mounted as `/run/secrets/nitter_sessions`.

### Valkey startup errors

Check that the Valkey sidecar is named/addressed as expected and that Nitter's entrypoint waits for port `6379` before launching Nitter. The cache is intentionally ephemeral and must not require a persistent volume.

### Cloud Run failures

Check the service description and revision status, then inspect logs for configuration or startup errors. Confirm that only the session and HMAC secrets are mounted and that no `X_PASSWORD`, `X_TOTP_SECRET`, or credential values appear in the service configuration or logs.

### Stale or changed upstream behavior

Re-check upstream's current configuration, session helper, and dependency requirements at the pinned commit. Adapt the wrapper to upstream behavior while preserving the architecture and security constraints in `PLAN.MD`.

## Security notes

- Use a dedicated X account where possible; do not use a primary personal account for an automated backend session.
- Treat `secrets/sessions.jsonl` and `secrets/hmac_key` as passwords.
- Keep `.env`, `deploy.env`, `secrets/*`, and generated local environments ignored by both Git and Docker.
- Never put secrets in Docker `ARG` or `ENV`, shell history, logs, issue trackers, or documentation.
- Do not add account farms, proxy rotation, IP rotation, or rate-limit evasion.
- Do not register the instance in public Nitter instance lists.
- Review `git status`, staged diffs, Docker history, and Cloud Run configuration before the first commit and after deployment.

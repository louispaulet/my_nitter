# Project Plan: Self-Hosted Nitter on GCP Cloud Run

## Goal

Create a new project in the already-cloned repository:

```bash
https://github.com/louispaulet/my_nitter.git
```

The repository is currently empty.

The goal is to build a small deployment wrapper around:

```bash
https://github.com/zedeus/nitter
```

We want to:

1. Use upstream Nitter rather than modifying or forking its application code.
2. Run Nitter inside Docker.
3. Run Valkey/Redis alongside Nitter as an ephemeral cache.
4. Use a dedicated X/Twitter account as the authenticated backend identity.
5. Keep the X username/password/TOTP secret only on the local development machine in `.env`.
6. Locally generate the `sessions.jsonl` file required by modern Nitter.
7. Never send the actual X password or TOTP seed to GCP.
8. Store the resulting Nitter X session securely in GCP Secret Manager.
9. Deploy Nitter + Valkey to GCP Cloud Run.
10. Configure Cloud Run to scale to zero when unused.
11. Limit Cloud Run to a maximum of one instance because this is a personal Nitter instance using a small X session pool.
12. Use `gcloud` for GCP initialization and deployment.
13. Make the whole setup reproducible from the Git repository.
14. Keep the deployment simple, cheap, and appropriate for very occasional usage.

---

# Important architectural decision

Do NOT design this as:

```text
.env
  ↓
Cloud Run
  ↓
X username/password/TOTP
  ↓
login on every cold start
```

That would be a bad design.

Modern Nitter does not directly consume the X username/password.

It consumes an authenticated X session stored in:

```text
sessions.jsonl
```

The maintained upstream Nitter helper:

```text
tools/create_session_browser.py
```

performs an actual browser-based X login and produces a cookie session containing fields such as:

```json
{
  "kind": "cookie",
  "username": "...",
  "id": "...",
  "auth_token": "...",
  "ct0": "..."
}
```

The older pure-HTTP login helper is currently deprecated because X requires browser-side JavaScript / instrumentation during login.

Therefore our architecture should instead be:

```text
LOCAL MACHINE
─────────────

.env
 ├── X_USERNAME
 ├── X_PASSWORD
 └── X_TOTP_SECRET
          │
          ▼
Nitter create_session_browser.py
          │
          ▼
secrets/sessions.jsonl
          │
          ▼
GCP Secret Manager


GCP CLOUD RUN
─────────────

Browser
  │
  ▼
Cloud Run
  │
  ├── Nitter container
  │       │
  │       ├── sessions.jsonl ← Secret Manager
  │       ├── generated nitter.conf
  │       └── port 8080
  │
  └── Valkey container
          │
          └── ephemeral cache
          
Nitter
  │
  ▼
X/Twitter
```

The X username/password/TOTP seed must NEVER be uploaded to GCP.

Only the resulting Nitter session should reach GCP.

---

# General implementation philosophy

Treat:

```text
zedeus/nitter
```

as an upstream dependency.

Do NOT:

- fork the Nitter Nim application unnecessarily
- copy the entire Nitter source tree into this repository
- rewrite its routes
- rewrite its API logic
- rewrite its authentication logic
- track upstream `master` blindly
- generate X sessions inside Cloud Run
- perform X login during Cloud Run startup
- send X credentials to Cloud Build
- bake secrets into Docker images

Our repository should contain only:

```text
deployment wrapper
Docker build configuration
local tooling
session provisioning tooling
GCP scripts
configuration templates
documentation
```

---

# Phase 0: Inspect starting state

We are already inside or have already cloned:

```bash
git clone https://github.com/louispaulet/my_nitter.git
cd my_nitter
```

First inspect:

```bash
git status
git remote -v
git branch --show-current
```

Expected remote:

```text
origin  https://github.com/louispaulet/my_nitter.git
```

Expected branch:

```text
main
```

Also inspect the current upstream Nitter commit:

```bash
git ls-remote \
  https://github.com/zedeus/nitter.git \
  refs/heads/master
```

At the time this plan was written, upstream Nitter included commit:

```text
1428b4c2b4246f92a7e5b2673438e5fb39fcc4a3
```

Do NOT assume that is still the latest commit.

Retrieve the current `master` SHA.

Store that SHA as the initially pinned `NITTER_REF`.

We want:

```text
my_nitter commit
       ↓
exact Nitter commit
       ↓
reproducible Docker image
```

and not:

```text
my_nitter commit
       ↓
whatever upstream master happens to contain today
```

---

# Phase 1: Create project structure

Create the following repository structure:

```text
my_nitter/
├── .dockerignore
├── .env.example
├── .gitignore
├── Dockerfile
├── README.md
│
├── docker/
│   ├── entrypoint.sh
│   └── nitter.conf.template
│
├── scripts/
│   ├── bootstrap.sh
│   ├── create_session.py
│   ├── local-up.sh
│   ├── local-down.sh
│   ├── gcp-init.sh
│   ├── deploy.sh
│   ├── smoke-test.sh
│   └── update-nitter-ref.sh
│
├── compose.local.yaml
├── compose.cloudrun.yaml
│
├── secrets/
│   └── .gitkeep
│
└── deploy.env.example
```

Possibly also create:

```text
Makefile
```

later if it improves usability, but shell scripts are sufficient for the first implementation.

Do not vendor upstream Nitter into the repository.

---

# Phase 2: Git secret protection

Create `.gitignore`.

It must at minimum contain:

```gitignore
.env
.env.*
!.env.example

deploy.env

secrets/*
!secrets/.gitkeep

sessions.jsonl

.venv/
.cache/
__pycache__/
*.pyc

.DS_Store
```

The following must NEVER be committed:

```text
.env
deploy.env
sessions.jsonl
secrets/sessions.jsonl
secrets/hmac_key
X passwords
TOTP seeds
auth_token
ct0
```

Create `.dockerignore`.

It must at minimum contain:

```dockerignore
.git
.gitignore

.env
.env.*
deploy.env

secrets
sessions.jsonl

.venv
.cache
__pycache__

README.md
.DS_Store
```

The reason for `.dockerignore` is important:

A file being ignored by Git does NOT prevent Docker from copying it into a build context.

We must therefore independently prevent sensitive local files from reaching Docker/Cloud Build.

---

# Phase 3: Create `.env.example`

Create:

```text
.env.example
```

with placeholders only:

```dotenv
# X account credentials.
# These are ONLY used locally to generate sessions.jsonl.
# They must never be uploaded to GCP or committed to Git.

X_USERNAME=
X_PASSWORD=
X_TOTP_SECRET=

# Exact upstream Nitter Git commit to build.
NITTER_REF=
```

The user will create the real file with:

```bash
cp .env.example .env
```

The real `.env` should contain something like:

```dotenv
X_USERNAME=my_x_username
X_PASSWORD=my_x_password
X_TOTP_SECRET=my_totp_seed
NITTER_REF=abcdef1234567890...
```

Do not include real values in documentation.

TOTP must be optional because an X account may theoretically not use TOTP.

---

# Phase 4: Upstream Nitter strategy

Do not `git clone` Nitter permanently inside the repository.

Use two separate mechanisms:

## Docker build

The Dockerfile fetches upstream Nitter at a pinned commit.

## Local session generation

The session script keeps a temporary ignored clone in:

```text
.cache/nitter
```

This gives us:

```text
repository
    ├── our deployment code
    └── .cache/nitter   # ignored upstream checkout
```

Do not create:

```text
my_nitter/nitter/
```

as committed source code.

---

# Phase 5: Create Dockerfile

Create a multi-stage Dockerfile.

The build should use an exact `NITTER_REF`.

Conceptually:

```dockerfile
ARG NITTER_REF

FROM nimlang/nim:2.2.6-alpine-regular AS builder

RUN apk add --no-cache \
    git \
    libsass-dev \
    pcre

WORKDIR /build

ARG NITTER_REF

RUN test -n "${NITTER_REF}"

RUN git init nitter \
    && cd nitter \
    && git remote add origin https://github.com/zedeus/nitter.git \
    && git fetch --depth=1 origin "${NITTER_REF}" \
    && git checkout --detach FETCH_HEAD

WORKDIR /build/nitter

RUN nimble install -y --depsOnly

RUN nimble build \
      -d:danger \
      -d:lto \
      -d:strip \
      --mm:refc \
    && nimble scss \
    && nimble md
```

Then create the runtime stage:

```dockerfile
FROM alpine:latest

RUN apk add --no-cache \
    pcre \
    ca-certificates \
    openssl \
    gettext \
    busybox-extras

WORKDIR /src

COPY --from=builder /build/nitter/nitter ./nitter
COPY --from=builder /build/nitter/public ./public

COPY docker/nitter.conf.template /etc/nitter/nitter.conf.template
COPY docker/entrypoint.sh /usr/local/bin/nitter-entrypoint

RUN chmod +x /usr/local/bin/nitter-entrypoint \
    && adduser -h /src -D -s /bin/sh nitter

USER nitter

ENV NITTER_CONF_FILE=/tmp/nitter.conf
ENV NITTER_SESSIONS_FILE=/run/secrets/nitter_sessions

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/nitter-entrypoint"]
```

Adjust exact Alpine packages if required after testing.

Important criteria:

The final runtime image should NOT contain:

```text
Git
Nim compiler
build toolchain
X username
X password
X TOTP seed
sessions.jsonl baked into image
HMAC key baked into image
```

---

# Phase 6: Build `nitter.conf.template`

Create:

```text
docker/nitter.conf.template
```

Base it closely on upstream:

```text
nitter.example.conf
```

Do not invent unnecessary configuration.

Recommended initial configuration:

```ini
[Server]
hostname = "${NITTER_HOSTNAME}"
title = "nitter"
address = "0.0.0.0"
port = 8080
https = ${NITTER_HTTPS}
httpMaxConnections = 100
staticDir = "./public"

[Cache]
listMinutes = 240
rssMinutes = 10

redisHost = "${NITTER_REDIS_HOST}"
redisPort = 6379
redisPassword = ""

redisConnections = 5
redisMaxConnections = 10

[Config]
hmacKey = "${NITTER_HMAC_KEY}"

base64Media = false

enableRSS = true
enableRSSUserTweets = true
enableRSSUserReplies = true
enableRSSUserMedia = true
enableRSSUserArticles = true
enableRSSSearch = true
enableRSSList = true

enableDebug = false

proxy = ""
proxyAuth = ""
apiProxy = ""

disableTid = false

maxConcurrentReqs = 2
maxRetries = 1
retryDelayMs = 150

[Preferences]
theme = "Nitter"

replaceTwitter = "${NITTER_HOSTNAME}"

proxyVideos = true
hlsPlayback = false
infiniteScroll = false
```

Stay reasonably close to upstream defaults.

Do not increase:

```ini
maxConcurrentReqs
```

for now.

This is a personal instance using one X account/session.

The objective is reliability, not throughput.

---

# Phase 7: Create Docker entrypoint

Create:

```text
docker/entrypoint.sh
```

Responsibilities:

1. Use `set -eu`.
2. Validate required environment variables.
3. Verify session secret exists.
4. Verify HMAC secret exists.
5. Load HMAC key.
6. Wait until Valkey is listening.
7. Render the Nitter configuration.
8. Never print secrets.
9. Launch Nitter via `exec`.

Example structure:

```sh
#!/bin/sh
set -eu

: "${NITTER_HOSTNAME:?NITTER_HOSTNAME is required}"
: "${NITTER_REDIS_HOST:=valkey}"
: "${NITTER_HTTPS:=true}"

: "${NITTER_CONF_FILE:=/tmp/nitter.conf}"
: "${NITTER_SESSIONS_FILE:=/run/secrets/nitter_sessions}"

if [ ! -f "${NITTER_SESSIONS_FILE}" ]; then
    echo "ERROR: Nitter sessions file is missing." >&2
    exit 1
fi

if [ ! -s "${NITTER_SESSIONS_FILE}" ]; then
    echo "ERROR: Nitter sessions file is empty." >&2
    exit 1
fi

if [ ! -f /run/secrets/nitter_hmac ]; then
    echo "ERROR: Nitter HMAC secret is missing." >&2
    exit 1
fi

export NITTER_HMAC_KEY="$(cat /run/secrets/nitter_hmac)"

echo "Waiting for Valkey at ${NITTER_REDIS_HOST}:6379..."

ready=0

for i in $(seq 1 50); do
    if nc -z "${NITTER_REDIS_HOST}" 6379 >/dev/null 2>&1; then
        ready=1
        break
    fi

    sleep 0.2
done

if [ "${ready}" != "1" ]; then
    echo "ERROR: Valkey did not become available." >&2
    exit 1
fi

envsubst \
    < /etc/nitter/nitter.conf.template \
    > "${NITTER_CONF_FILE}"

echo "Starting Nitter."

exec /src/nitter
```

Check whether `envsubst` behaves correctly for the template.

Do not allow command output to expose:

```text
NITTER_HMAC_KEY
auth_token
ct0
```

---

# Phase 8: Bootstrap local Python environment

Create:

```text
scripts/bootstrap.sh
```

Purpose:

1. Verify Python 3 exists.
2. Verify Git exists.
3. Verify Docker exists.
4. Verify OpenSSL exists.
5. Create `.cache`.
6. Clone/update upstream Nitter into `.cache/nitter`.
7. Checkout exactly `NITTER_REF`.
8. Create `.venv`.
9. Install upstream session-generation dependencies.
10. Generate the HMAC key if missing.

Load `.env` carefully.

Avoid naïvely doing:

```bash
source .env
```

if there is any concern about arbitrary shell content.

For a personal repository it may be acceptable, but a small Python dotenv loader or controlled parsing is preferable.

The session helper dependencies currently include things equivalent to:

```text
zendriver
pyotp
curl_cffi
```

Use the upstream:

```text
tools/requirements.txt
```

rather than duplicating versions where possible.

Pseudo-flow:

```text
read NITTER_REF
        ↓
.cache/nitter exists?
  ├── no → clone
  └── yes → fetch
        ↓
checkout detached NITTER_REF
        ↓
create .venv
        ↓
pip install requirements
        ↓
generate HMAC if missing
```

---

# Phase 9: HMAC key

Nitter should not use the default:

```text
secretkey
```

Generate:

```bash
mkdir -p secrets
openssl rand -hex 32 > secrets/hmac_key
chmod 600 secrets/hmac_key
```

Only generate it if:

```text
secrets/hmac_key
```

does not already exist.

Do NOT regenerate on:

```text
every local startup
every Docker build
every deployment
every Cloud Run cold start
```

A stable secret should be used.

---

# Phase 10: Build session-generation tool

Create:

```text
scripts/create_session.py
```

The goal is to wrap the current upstream:

```text
tools/create_session_browser.py
```

without reimplementing X login.

Responsibilities:

1. Read `.env`.
2. Require:
   - `X_USERNAME`
   - `X_PASSWORD`
   - `NITTER_REF`
3. Treat `X_TOTP_SECRET` as optional.
4. Ensure `.cache/nitter` contains the correct upstream commit.
5. Ensure `.venv` exists.
6. Install requirements if necessary.
7. Delete or rotate an existing `secrets/sessions.jsonl` only with clear behavior.
8. Invoke upstream browser session creation.
9. Write:
   ```text
   secrets/sessions.jsonl
   ```
10. Validate output.
11. Never print credential/session values.

---

# Phase 11: Avoid exposing password in `ps`

The upstream helper accepts something conceptually like:

```bash
python create_session_browser.py \
    username \
    password \
    TOTP \
    --append sessions.jsonl
```

That means process arguments could expose the password temporarily through system process listings.

Prefer not to call it directly as a subprocess with secret command-line arguments.

Investigate whether the upstream helper can safely be imported.

Preferred approach:

```text
scripts/create_session.py
        ↓
import/run upstream helper inside same Python process
        ↓
pass credential variables in Python memory
```

Possible mechanisms:

```python
import importlib.util
```

or:

```python
runpy
```

or a narrowly scoped wrapper around the helper functions.

However:

Do NOT copy/reimplement the login flow.

If the upstream helper's structure makes safe importing extremely cumbersome, prioritize correctness over an elaborate rewrite.

If direct CLI invocation becomes necessary:

- document the temporary `ps` exposure
- avoid printing the command
- never log command arguments
- never store shell history with expanded credentials

But first attempt an in-process invocation.

---

# Phase 12: Session output validation

Expected file:

```text
secrets/sessions.jsonl
```

Each line must be independently valid JSON.

For the modern cookie session, validate presence of:

```text
kind
username
id
auth_token
ct0
```

Expected conceptual shape:

```json
{
  "kind": "cookie",
  "username": "...",
  "id": "...",
  "auth_token": "...",
  "ct0": "..."
}
```

Do NOT print the values.

Safe output:

```text
✓ Session file created
✓ 1 session found
✓ kind=cookie
✓ username present
✓ user id present
✓ auth_token present
✓ ct0 present
```

Never print:

```text
auth_token=...
ct0=...
password=...
TOTP=...
```

---

# Phase 13: Local Docker Compose

Create:

```text
compose.local.yaml
```

Use two services:

```text
nitter
valkey
```

Recommended structure:

```yaml
services:
  nitter:
    build:
      context: .
      args:
        NITTER_REF: ${NITTER_REF}

    ports:
      - "127.0.0.1:8080:8080"

    environment:
      NITTER_HOSTNAME: localhost:8080
      NITTER_HTTPS: "false"
      NITTER_REDIS_HOST: valkey
      NITTER_CONF_FILE: /tmp/nitter.conf
      NITTER_SESSIONS_FILE: /run/secrets/nitter_sessions

    secrets:
      - nitter_sessions
      - nitter_hmac

    depends_on:
      - valkey

  valkey:
    image: valkey/valkey:8-alpine

    command:
      - valkey-server
      - --save
      - ""
      - --appendonly
      - "no"

    expose:
      - "6379"

secrets:
  nitter_sessions:
    file: ./secrets/sessions.jsonl

  nitter_hmac:
    file: ./secrets/hmac_key
```

Adjust syntax if required for local Docker Compose.

Use:

```text
valkey
```

rather than a persistent managed Redis product.

---

# Phase 14: Why Valkey is ephemeral

Do NOT add a Valkey volume initially.

The cache may disappear whenever the containers stop.

This is intentional.

Desired behavior:

```text
start service
   ↓
empty cache
   ↓
Nitter fetches X
   ↓
cache fills
   ↓
service stops
   ↓
cache disappears
```

On the next cold start:

```text
new empty cache
```

For rare personal usage this is fine.

Avoid:

```text
GCP Memorystore
```

because that would create an always-on paid dependency and undermine our scale-to-zero goal.

---

# Phase 15: Local convenience scripts

Create:

```text
scripts/local-up.sh
```

It should:

1. Validate `.env`.
2. Validate `secrets/sessions.jsonl`.
3. Validate `secrets/hmac_key`.
4. Launch local Compose.

Something similar to:

```bash
docker compose \
  --env-file .env \
  -f compose.local.yaml \
  up --build
```

Create:

```text
scripts/local-down.sh
```

with something similar to:

```bash
docker compose \
  --env-file .env \
  -f compose.local.yaml \
  down
```

Possibly support:

```bash
./scripts/local-up.sh -d
```

later.

Keep the initial version simple.

---

# Phase 16: Local validation BEFORE GCP

Do NOT begin Cloud Run work until local Nitter works.

Required test:

```bash
./scripts/bootstrap.sh
./scripts/create_session.py
./scripts/local-up.sh
```

Then open:

```text
http://localhost:8080
```

Test at least:

```text
homepage
profile page
individual post/status
search
image/media proxying
```

Suggested profiles:

```text
http://localhost:8080/jack
http://localhost:8080/OpenAI
```

Do not depend on any one X account being guaranteed to exist forever; these are examples.

Test direct `curl` too:

```bash
curl -I http://localhost:8080/
```

Then inspect Docker logs.

Acceptance criteria:

```text
[ ] Nitter image builds
[ ] Valkey container starts
[ ] Nitter waits for Valkey correctly
[ ] Nitter connects to Valkey
[ ] sessions.jsonl is accepted
[ ] homepage loads
[ ] profile loads
[ ] status/tweet loads
[ ] media proxy works
[ ] no secrets appear in logs
[ ] restart works
```

Then:

```bash
./scripts/local-down.sh
```

Start it again.

Ensure restart does not require regenerating X sessions.

---

# Phase 17: Do not progress if authentication is broken

If local Nitter reports errors like:

```text
Instance has no auth tokens
```

or authentication failures:

Stop the GCP work.

Debug locally first.

Possible causes include:

```text
invalid sessions.jsonl
expired auth_token
invalid ct0
X login failed
incorrect sessions file path
session schema changed upstream
```

Do not mix GCP debugging with X-session debugging.

The local milestone must be solid first.

---

# Phase 18: Deployment config

Create:

```text
deploy.env.example
```

with:

```dotenv
GCP_PROJECT_ID=
GCP_REGION=europe-west1
CLOUD_RUN_SERVICE=my-nitter
```

The real:

```text
deploy.env
```

must be ignored.

Default to:

```text
europe-west1
```

unless there is a clear reason to use another region.

The project has two separate config categories:

```text
.env
    ↓
local X/session generation secrets

deploy.env
    ↓
non-secret GCP deployment configuration
```

Do NOT combine them unnecessarily.

---

# Phase 19: Verify `gcloud`

Create:

```text
scripts/gcp-init.sh
```

Check:

```bash
command -v gcloud
```

If unavailable, stop with clear instructions.

Then inspect:

```bash
gcloud auth list
gcloud config get-value project
```

Load:

```text
deploy.env
```

Determine project:

1. Prefer `GCP_PROJECT_ID` from `deploy.env`.
2. Otherwise optionally use configured `gcloud` project.
3. If neither exists, exit.

Set:

```bash
gcloud config set project "$GCP_PROJECT_ID"
gcloud config set run/region "$GCP_REGION"
```

---

# Phase 20: Enable GCP APIs

Enable only what is necessary:

```bash
gcloud services enable \
    cloudresourcemanager.googleapis.com \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com \
    secretmanager.googleapis.com
```

Possibly additional APIs if `gcloud run compose` explicitly requires them.

Do not preemptively provision unrelated services.

Do NOT provision:

```text
Compute Engine
GKE
Cloud SQL
Memorystore
VPC connector
external load balancer
Cloud Functions
```

for the MVP.

---

# Phase 21: Secret Manager architecture

The only application secrets needed in production should initially be:

```text
nitter sessions.jsonl
Nitter HMAC key
```

Do not store:

```text
X_USERNAME
X_PASSWORD
X_TOTP_SECRET
```

in Secret Manager.

Production flow:

```text
local X credentials
        ↓
local browser authentication
        ↓
sessions.jsonl
        ↓
Secret Manager
        ↓
Cloud Run
```

---

# Phase 22: Secret naming

Use stable GCP secret names.

For example:

```text
my-nitter-sessions
my-nitter-hmac
```

Avoid putting sensitive information into secret names.

Create/update them idempotently.

Desired semantics:

```text
if secret absent:
    create secret
    add version

if secret exists:
    add new version
```

Never destroy the secret simply because a new session is generated.

Secret version history may be useful for rollback.

---

# Phase 23: Cloud Run hostname

Cloud Run's assigned hostname should be used in:

```text
NITTER_HOSTNAME
```

Do not hardcode:

```text
nitter.net
localhost
```

for production.

Determine the actual Cloud Run service URL using `gcloud` after deployment where practical:

```bash
gcloud run services describe "$CLOUD_RUN_SERVICE" \
    --region "$GCP_REGION" \
    --format='value(status.url)'
```

Potential issue:

Nitter needs its hostname in configuration during startup.

Codex should choose one of these robust approaches.

## Preferred approach

If the Cloud Run hostname can be deterministically calculated before deployment, calculate it from:

```text
service name
project number
region
```

and pass it as:

```text
NITTER_HOSTNAME
```

Then verify the actual returned `status.url`.

## Alternative

Perform a first deployment with a temporary hostname and immediately update after obtaining `status.url`.

Prefer the deterministic single-deployment approach if GCP's current hostname scheme supports it reliably.

Do not assume without checking current `gcloud`/Cloud Run behavior.

---

# Phase 24: Cloud Run multi-container strategy

Use a single Cloud Run service containing:

```text
Nitter container
Valkey sidecar
```

Architecture:

```text
Cloud Run instance
├── ingress container: Nitter :8080
└── sidecar: Valkey :6379
```

Valkey does not need public ingress.

Nitter connects internally to:

```text
valkey:6379
```

or whatever hostname/current Cloud Run Compose networking mechanism is supported.

If Cloud Run sidecars instead share localhost under current behavior, use:

```text
localhost:6379
```

Check current platform behavior while implementing.

Do not guess.

The important principle is:

```text
both processes live in the same Cloud Run instance lifecycle
```

When Cloud Run scales to zero:

```text
Nitter stops
Valkey stops
cost approaches zero
```

---

# Phase 25: Create `compose.cloudrun.yaml`

Build an initial Cloud Run Compose deployment.

Conceptually:

```yaml
services:
  nitter:
    build:
      context: .
      args:
        NITTER_REF: ${NITTER_REF}

    ports:
      - "8080:8080"

    environment:
      NITTER_HOSTNAME: ${NITTER_HOSTNAME}
      NITTER_HTTPS: "true"
      NITTER_REDIS_HOST: valkey
      NITTER_CONF_FILE: /tmp/nitter.conf
      NITTER_SESSIONS_FILE: /run/secrets/nitter_sessions

    secrets:
      - nitter_sessions
      - nitter_hmac

    depends_on:
      - valkey

  valkey:
    image: valkey/valkey:8-alpine

    command:
      - valkey-server
      - --save
      - ""
      - --appendonly
      - "no"

secrets:
  nitter_sessions:
    # Map to GCP Secret Manager according to
    # current gcloud run compose syntax.

  nitter_hmac:
    # Map to GCP Secret Manager according to
    # current gcloud run compose syntax.
```

Do not blindly assume local Docker Compose secret syntax translates identically to Cloud Run.

Check:

```bash
gcloud run compose --help
```

and current official Cloud Run Compose behavior.

Adapt accordingly.

Current Cloud Run Compose behavior mounts each Compose secret at the default
`/run/secrets` directory. Cloud Run rejects two secret volumes at the same
mount path. Use the session secret for the initial Compose revision so the
container can become ready, then replace that transient mount with the two
stable Secret Manager secrets using distinct paths:

```text
/run/secrets/sessions/nitter_sessions
/run/secrets/hmac/nitter_hmac
```

The entrypoint may generate a temporary HMAC only for that bootstrap revision.
The deployment script must disable that mode in the final revision and remove
the transient Compose-created session secret after the stable mounts are active.

---

# Phase 26: Prefer Cloud Run, NOT Cloud Functions

Do not convert Nitter into a Cloud Function.

Nitter is already an HTTP server.

It:

```text
starts
connects to Redis/Valkey
initializes session pool
listens on port 8080
handles many routes
```

Cloud Run is a much better abstraction:

```text
here is a container
start it when HTTP traffic arrives
```

Do not introduce:

```text
function wrapper
process spawning per request
custom function runtime
```

---

# Phase 27: Build/deploy path

Prefer:

```bash
gcloud run compose up compose.cloudrun.yaml
```

if current Cloud Run Compose source-build support works correctly.

That should ideally handle:

```text
source build
Cloud Build
Artifact Registry
multi-container Cloud Run deployment
```

Avoid unnecessary manual steps like:

```text
docker build
docker tag
docker push
manual Artifact Registry management
```

unless Cloud Run Compose cannot represent something we require.

Favor the simplest supported GCP-native workflow.

---

# Phase 28: Cloud Run scale-to-zero

Explicitly configure:

```text
minimum instances = 0
```

even if it is already the default.

The service is meant for sporadic personal use.

Desired behavior:

```text
unused
  ↓
0 instances

request arrives
  ↓
Cloud Run starts instance
  ↓
Valkey starts
  ↓
Nitter starts
  ↓
request served

idle afterward
  ↓
Cloud Run eventually scales back to 0
```

This is the central design goal.

---

# Phase 29: Maximum one instance

Explicitly configure:

```text
maximum instances = 1
```

Reason:

We have one small X session pool.

Without this restriction, Cloud Run could theoretically create:

```text
instance A → same X account/session
instance B → same X account/session
instance C → same X account/session
```

That would:

```text
increase rate-limit pressure
duplicate caches
provide no useful benefit
increase complexity
```

For a personal instance:

```text
max instances = 1
```

is preferable.

---

# Phase 30: Request-based billing

Prefer Cloud Run request-based billing / CPU throttling.

We do NOT need CPU permanently allocated while idle.

Explicitly configure the equivalent of:

```text
CPU only allocated when required
minimum instances = 0
```

Use current `gcloud run services update` syntax.

Likely something conceptually similar to:

```bash
gcloud run services update "$CLOUD_RUN_SERVICE" \
    --region "$GCP_REGION" \
    --min 0 \
    --max 1 \
    --cpu-throttling
```

Verify current CLI flags before using.

Do not assume stale syntax.

---

# Phase 31: Resource sizing

Start small.

Nitter is lightweight.

Valkey for one user is tiny.

Suggested starting point:

```text
Nitter:
    CPU: 1
    memory: 512 MiB

Valkey:
    minimal reasonable allocation
```

However, multi-container Cloud Run resource configuration may apply differently.

Check current Cloud Run requirements.

Do not overprovision.

If 512 MiB proves insufficient during cold build/runtime, increase deliberately.

Avoid:

```text
2+ GiB
multiple CPUs
```

without evidence.

---

# Phase 32: Cold-start expectations

Cold start is acceptable.

This instance will be used rarely.

Expected first-request behavior:

```text
HTTP request
    ↓
Cloud Run allocates instance
    ↓
Valkey starts
    ↓
Nitter entrypoint waits for Valkey
    ↓
Nitter starts
    ↓
Nitter initializes X session pool
    ↓
request completes
```

A few seconds of latency on the first request is acceptable.

Do not enable always-on instances merely to remove cold starts.

---

# Phase 33: Health checks

Avoid unnecessary complexity during the MVP.

The Nitter entrypoint already waits for Valkey.

Do not add platform health probes unless required.

If current Cloud Run multi-container behavior requires a startup probe for sidecar dependency ordering, add the minimum necessary probe.

But first try:

```text
entrypoint waits for Valkey
```

This gives us explicit control.

Be careful that certain Cloud Run probe configurations may alter CPU/billing behavior.

Do not accidentally defeat scale-to-zero.

---

# Phase 34: Initial authentication strategy

Do NOT immediately expose the service anonymously to the internet.

First deploy it as:

```text
Cloud Run authenticated
```

This allows safe testing.

Test through an identity token.

Conceptually:

```bash
SERVICE_URL="$(
  gcloud run services describe "$CLOUD_RUN_SERVICE" \
    --region "$GCP_REGION" \
    --format='value(status.url)'
)"

curl \
  -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
  "$SERVICE_URL"
```

This isolates application debugging from public exposure.

---

# Phase 35: Public access is a separate decision

Do not automatically execute:

```text
--allow-unauthenticated
```

during the first deployment.

Once everything is confirmed working, document how to make it public.

If public anonymous access is enabled, understand:

```text
random visitor
      ↓
Cloud Run URL
      ↓
Nitter
      ↓
YOUR X session
      ↓
YOUR rate limits
```

Even if the URL is obscure, bots/scanners may discover it.

Therefore authenticated access is safer.

---

# Phase 36: Future authentication options

Do NOT implement this before the MVP works.

Later options:

```text
Option A:
Cloudflare Access
      ↓
Cloud Run
      ↓
Nitter
```

```text
Option B:
small Basic Auth reverse proxy
      ↓
Nitter
```

```text
Option C:
Cloud Run IAM authentication
```

For casual browser use, Cloudflare Access may eventually be the nicest UX.

But it is not required for initial deployment.

---

# Phase 37: Implement `scripts/deploy.sh`

Create an idempotent deployment script.

Responsibilities in order:

```text
1. Load deploy.env.
2. Read NITTER_REF from .env without unnecessarily loading X credentials.
3. Validate required files.
4. Validate gcloud.
5. Validate active GCP authentication.
6. Determine GCP project.
7. Determine GCP region.
8. Enable required APIs if necessary.
9. Compute or retrieve production hostname.
10. Create/update Secret Manager secret for sessions.jsonl.
11. Create/update Secret Manager secret for HMAC key.
12. Grant the Cloud Run runtime identity Secret Manager accessor on those secrets.
13. Export required Compose substitutions.
14. Deploy Cloud Run Compose service.
15. Set minimum instances = 0.
16. Set maximum instances = 1.
17. Configure request-based billing / CPU throttling.
18. Retrieve deployed URL.
19. Verify expected URL configuration.
20. Print non-sensitive deployment summary.
```

Validate before deployment:

```text
secrets/sessions.jsonl exists
secrets/sessions.jsonl not empty
secrets/hmac_key exists
NITTER_REF exists
GCP project exists
```

---

# Phase 38: Safe deployment output

At the end, print:

```text
Deployment complete

Service:         my-nitter
Region:          europe-west1
URL:             https://...
Nitter ref:      abcdef1234...
Minimum instances: 0
Maximum instances: 1
Access:          authenticated
Billing:         request-based

X session:       configured
X password:      NOT uploaded
X TOTP secret:   NOT uploaded
```

Do not print:

```text
session contents
auth_token
ct0
password
TOTP seed
HMAC key
```

---

# Phase 39: Smoke-test script

Create:

```text
scripts/smoke-test.sh
```

It should perform GCP configuration checks first.

Verify:

```text
Cloud Run service exists
service is Ready
revision is Ready
expected ingress container exists
Valkey sidecar exists
Nitter listens on 8080
min instances = 0
max instances = 1
```

Then perform a small number of HTTP tests.

For authenticated service:

```bash
TOKEN="$(gcloud auth print-identity-token)"
```

Then something conceptually like:

```bash
curl \
  --fail \
  --silent \
  --show-error \
  -H "Authorization: Bearer ${TOKEN}" \
  "${SERVICE_URL}/"
```

Then test one X profile.

Do not issue lots of test requests.

Three or four requests maximum.

---

# Phase 40: Validate actual X functionality in Cloud Run

Do not treat HTTP 200 on `/` as sufficient.

Also verify:

```text
profile fetching from X works
individual status fetching works
images/media proxy correctly
session is recognized
Valkey connection works
```

A static Nitter homepage could work even if X authentication is broken.

Test an actual profile route.

---

# Phase 41: Cold-start test

Once deployment works:

1. Confirm min instances = 0.
2. Leave service idle long enough to scale down.
3. Send request.
4. Observe logs.
5. Confirm:
   - Valkey starts
   - Nitter waits
   - Nitter connects
   - Nitter serves request
6. Send another request immediately.
7. Verify warm request works normally.

Do not attempt to control exact scale-down timing beyond supported Cloud Run settings.

---

# Phase 42: Verify ephemeral cache behavior

A restart / new instance should NOT rely on previous Valkey contents.

Test:

```text
cold instance A
    ↓
profile request
    ↓
cache populated
    ↓
instance destroyed

cold instance B
    ↓
empty cache
    ↓
same profile request
    ↓
still succeeds
```

This ensures there is no accidental dependency on persistent Redis.

---

# Phase 43: Session expiry workflow

Eventually X may invalidate the session.

The recovery workflow should be simple.

Locally:

```bash
rm secrets/sessions.jsonl
./scripts/create_session.py
```

Then:

```bash
./scripts/deploy.sh
```

That should:

```text
generate fresh session
        ↓
add new Secret Manager version
        ↓
deploy/update Cloud Run
```

No production X login automation.

Document that session refresh is manual and intentional.

---

# Phase 44: Upstream Nitter update tooling

Create:

```text
scripts/update-nitter-ref.sh
```

It should inspect:

```bash
git ls-remote \
  https://github.com/zedeus/nitter.git \
  refs/heads/master
```

Compare:

```text
current pinned NITTER_REF
latest upstream master SHA
```

Output example:

```text
Current pinned Nitter:
1428b4c2b4246f92...

Latest upstream:
abc123456789...

Update available.
```

Do not automatically edit or deploy by default.

Optionally support:

```bash
./scripts/update-nitter-ref.sh --write
```

later.

But the safe initial workflow is manual.

---

# Phase 45: Upstream update procedure

Document:

```text
1. Find latest Nitter SHA.
2. Update NITTER_REF.
3. Rebuild locally.
4. Test locally.
5. Commit new NITTER_REF.
6. Deploy.
7. Smoke-test Cloud Run.
```

Do not use:

```text
NITTER_REF=master
```

in production builds.

---

# Phase 46: README structure

Create a clear README with these sections:

```text
# my_nitter

## What this is
## Architecture
## Security model
## Requirements
## First-time setup
## Create X session
## Run locally
## Configure GCP
## Deploy
## Test deployment
## Refresh X session
## Upgrade Nitter
## Make Cloud Run public
## Troubleshooting
## Security notes
```

---

# Phase 47: README first-time local setup

Document:

```bash
git clone https://github.com/louispaulet/my_nitter.git
cd my_nitter

cp .env.example .env
```

Then tell user to fill:

```dotenv
X_USERNAME=
X_PASSWORD=
X_TOTP_SECRET=
NITTER_REF=
```

Then:

```bash
./scripts/bootstrap.sh
```

Then:

```bash
./scripts/create_session.py
```

Then:

```bash
./scripts/local-up.sh
```

Then open:

```text
http://localhost:8080
```

---

# Phase 48: README GCP setup

Document:

```bash
cp deploy.env.example deploy.env
```

Fill:

```dotenv
GCP_PROJECT_ID=my-project
GCP_REGION=europe-west1
CLOUD_RUN_SERVICE=my-nitter
```

Authenticate:

```bash
gcloud auth login
```

If needed:

```bash
gcloud auth application-default login
```

Then:

```bash
./scripts/gcp-init.sh
./scripts/deploy.sh
```

Do not assume ADC is required unless the commands actually use it.

Prefer minimal auth requirements.

---

# Phase 49: README security model

Explicitly explain:

```text
X_USERNAME
X_PASSWORD
X_TOTP_SECRET
```

stay local.

They are used to generate:

```text
auth_token
ct0
```

inside:

```text
sessions.jsonl
```

Only:

```text
sessions.jsonl
```

is uploaded to GCP Secret Manager.

Cloud Run never receives:

```text
X_PASSWORD
X_TOTP_SECRET
```

This is a deliberate design decision.

---

# Phase 50: README warning about sessions

Explain:

`auth_token` and `ct0` are highly sensitive.

Anyone who obtains them may effectively gain authenticated access to the X account session.

Therefore:

```text
sessions.jsonl
```

must be treated like a password.

Do not:

```text
email it
commit it
paste it into GitHub issues
include it in Docker images
print it in logs
```

---

# Phase 51: README warning about public URL

Explain that a public Nitter URL means external users consume the backend X session.

For a personal account:

```text
public anonymous Nitter
        ↓
anyone can make requests
        ↓
requests consume your X account capacity
```

Recommend authenticated deployment.

Public access should be opt-in.

---

# Phase 52: Logging discipline

Review all scripts for accidental secret logging.

Never use:

```bash
set -x
```

in scripts that touch credentials or secrets.

Never print full environment.

Never execute:

```bash
env
```

as debugging.

Never log entire:

```text
sessions.jsonl
```

If debugging JSON validity:

Print only:

```text
number of sessions
presence of required keys
session kind
```

---

# Phase 53: Secret scanning

Before first commit, run checks such as:

```bash
git status
git diff --cached
```

Search repository for suspicious strings:

```bash
grep -R "auth_token" .
grep -R "ct0" .
grep -R "X_PASSWORD" .
```

`X_PASSWORD` appearing in source code as a variable name is fine.

Actual secret values are not.

If available, optionally use:

```text
gitleaks
```

but do not require a heavy dependency for the MVP.

---

# Phase 54: Ensure Docker image contains no secret files

After local build, inspect:

```bash
docker history <image>
```

and possibly:

```bash
docker run --rm <image> find / -name '.env' -o -name 'sessions.jsonl'
```

The session may be mounted at runtime, but must not exist in the static image.

Verify:

```text
.env absent
sessions.jsonl absent
hmac key absent
```

from the image itself.

---

# Phase 55: Verify GCP does not contain X credentials

After deployment, inspect Cloud Run environment configuration.

Ensure there are NO production environment variables named:

```text
X_USERNAME
X_PASSWORD
X_TOTP_SECRET
```

Only safe runtime variables such as:

```text
NITTER_HOSTNAME
NITTER_HTTPS
NITTER_REDIS_HOST
NITTER_CONF_FILE
NITTER_SESSIONS_FILE
```

should exist.

Sensitive runtime content should enter through Secret Manager mounts.

---

# Phase 56: GCP resources should remain minimal

After deployment, we should have roughly:

```text
Cloud Run service
Cloud Build usage
Artifact Registry repository/image
Secret Manager secrets
```

and nothing else persistent.

Specifically verify we did not accidentally create:

```text
VM
GKE cluster
Memorystore
Cloud SQL
VPC connector
load balancer
reserved IP
Cloud NAT
```

---

# Phase 57: Cost-conscious design

This project is used rarely.

Design priorities:

```text
low idle cost
simple deployment
acceptable cold start
small resource footprint
minimal managed infrastructure
```

Do not optimize for:

```text
high availability
mass public traffic
zero cold starts
horizontal scaling
multi-region
persistent cache
```

Those are explicitly out of scope.

---

# Phase 58: Error handling

All scripts must:

```bash
set -e
```

or equivalent robust error handling.

Errors should be clear and actionable.

Examples:

```text
ERROR: .env not found.
Run:
    cp .env.example .env
and fill in your X credentials.
```

```text
ERROR: secrets/sessions.jsonl not found.
Run:
    ./scripts/create_session.py
```

```text
ERROR: gcloud is not authenticated.
Run:
    gcloud auth login
```

Do not allow confusing downstream errors when we can validate prerequisites.

---

# Phase 59: Idempotency

Scripts should be safely re-runnable.

Examples:

```text
bootstrap.sh
    should not reclone unnecessarily

gcp-init.sh
    should tolerate already-enabled APIs

deploy.sh
    should update existing secrets/services

create_session.py
    should explicitly handle existing session file

local-up.sh
    should behave predictably if containers already exist
```

Avoid scripts that require manual cleanup after every invocation.

---

# Phase 60: Session overwrite semantics

For:

```text
scripts/create_session.py
```

do not blindly append sessions forever.

For a one-account MVP, default behavior should probably be:

```text
generate a fresh temporary sessions.jsonl
validate it
atomically replace secrets/sessions.jsonl
```

Example:

```text
secrets/sessions.jsonl.tmp
        ↓
validate
        ↓
rename to sessions.jsonl
```

This prevents:

```text
old dead session
old dead session
new session
```

from accumulating accidentally.

If multiple X sessions are supported later, change this deliberately.

---

# Phase 61: Atomic secret generation

When generating session:

```text
write temporary file
validate JSON
validate required keys
chmod 600
rename atomically
```

Do not leave half-written session files if login crashes.

Likewise for HMAC key:

```text
create once
chmod 600
```

---

# Phase 62: Permissions

Set local secret files to:

```bash
chmod 600 secrets/sessions.jsonl
chmod 600 secrets/hmac_key
```

The `secrets` directory can optionally be:

```bash
chmod 700 secrets
```

Do not require root.

---

# Phase 63: Container user

Run Nitter as an unprivileged user.

Do not run:

```text
USER root
```

in the final runtime unless absolutely necessary.

The build stage may use root.

Runtime should be non-root.

Valkey should use its image's normal safe user/configuration.

---

# Phase 64: Read-only container considerations

After MVP works, investigate whether the Nitter container can run:

```text
read_only filesystem
```

with writable `/tmp`.

Upstream itself supports read-only-style operation in its Compose configuration.

However:

Our entrypoint writes:

```text
/tmp/nitter.conf
```

so `/tmp` must remain writable.

Do not add read-only hardening before basic functionality works.

This is a secondary hardening task.

---

# Phase 65: No automatic public instance discovery

Do not register this instance in any public Nitter instance list.

Do not add metadata advertising it.

This is a personal instance.

---

# Phase 66: No RSS abuse optimization initially

Leave RSS enabled according to upstream defaults unless it causes issues.

This is a private/personal instance.

Do not spend time building anti-abuse measures unless anonymous public access is later enabled.

If it becomes public, reconsider:

```text
RSS
search
rate limiting
authentication
```

---

# Phase 67: Rate limits

Do not try to bypass or circumvent X rate limits.

Nitter manages available session capacity internally.

For one occasional user, one session may be sufficient.

Keep:

```ini
maxConcurrentReqs = 2
```

or upstream default.

Do not implement:

```text
account farms
proxy rotation
IP rotation
rate-limit evasion
```

They are outside this project.

If the account becomes rate-limited:

```text
wait
or
add a legitimate additional account/session later
```

But start with one.

---

# Phase 68: Dedicated X account recommendation

The software should work with the user's existing account.

However, documentation should recommend using:

```text
a dedicated X account
```

rather than the user's main personal account.

Reasons:

```text
session exposure risk
automated access risk
rate limiting
possible X account enforcement
```

Do not require a dedicated account, but recommend it.

---

# Phase 69: Keep Cloud Run concurrency conservative

Because Nitter uses one X session, avoid extreme request concurrency.

Cloud Run defaults may allow many simultaneous requests into one container.

Investigate setting a conservative Cloud Run concurrency value.

Potential starting point:

```text
container concurrency = 10
```

or lower.

However, do not choose arbitrarily.

Nitter internally limits concurrent requests per X session.

For a personal instance, even:

```text
concurrency = 4
```

may be enough.

Research current Nitter behavior and pick a modest value.

Document the reason.

Do NOT configure high concurrency like:

```text
80
1000
```

without need.

---

# Phase 70: Avoid autoscaling race with secrets/cache

Because:

```text
max instances = 1
```

we eliminate most distributed-state concerns.

Do not introduce:

```text
shared Redis
distributed lock
shared filesystem
```

unless a concrete need arises.

---

# Phase 71: Cloud Run deployment verification

After deployment, query:

```bash
gcloud run services describe "$CLOUD_RUN_SERVICE" \
    --region "$GCP_REGION"
```

Programmatically inspect:

```text
service URL
latest ready revision
container names
environment variables
secret mounts
min instances
max instances
CPU/billing mode
concurrency
memory
```

If any differs from intended config, fail `smoke-test.sh`.

---

# Phase 72: Cloud Logging verification

Check logs after first cold start.

Ensure expected logs resemble:

```text
Waiting for Valkey...
Starting Nitter.
Connected to Redis/Valkey...
Starting Nitter at ...
```

Do NOT see:

```text
auth_token
ct0
X_PASSWORD
TOTP seed
```

If secrets appear, fix immediately.

---

# Phase 73: Custom domain is out of scope initially

Use:

```text
*.run.app
```

initially.

Do not configure custom DNS yet.

Once stable, a later optional phase may add:

```text
nitter.example.com
```

Possibly behind Cloudflare.

But custom domain setup must not block MVP.

---

# Phase 74: Cloudflare is out of scope initially

Do not introduce Cloudflare Workers or Cloudflare Containers.

GCP Cloud Run is the primary target.

Cloudflare may later be used only for:

```text
custom domain
Cloudflare Access
authentication
```

if desired.

---

# Phase 75: Vercel is out of scope

Do not build Vercel configuration.

This workload is a long-running HTTP server container with Redis/Valkey dependency.

Cloud Run is more appropriate.

---

# Phase 76: Tests

Add lightweight tests where useful.

At minimum:

## Python tests

Test session validation without real credentials.

Given:

```json
{"kind":"cookie","username":"foo","id":"123","auth_token":"abc","ct0":"xyz"}
```

validation succeeds.

Given missing:

```text
auth_token
```

validation fails.

Do not add brittle tests around the actual X login flow.

---

# Phase 77: Shell formatting/linting

If convenient, run:

```text
shellcheck
```

against scripts.

Do not make shellcheck an absolute prerequisite if unavailable.

Scripts should nevertheless use:

```bash
set -euo pipefail
```

for Bash scripts where appropriate.

For POSIX shell entrypoint:

```sh
set -eu
```

is sufficient.

---

# Phase 78: Docker validation

Run:

```bash
docker build \
  --build-arg NITTER_REF="$NITTER_REF" \
  -t my-nitter:test \
  .
```

Make sure build cache works.

Changing wrapper scripts should not unnecessarily rebuild Nitter if avoidable, although build simplicity matters more than perfect cache optimization.

---

# Phase 79: Reproducibility

A fresh clone should require only:

```text
Git
Docker
Python 3
gcloud
X credentials
GCP project
```

Then:

```bash
cp .env.example .env

./scripts/bootstrap.sh
./scripts/create_session.py
./scripts/local-up.sh
```

and later:

```bash
cp deploy.env.example deploy.env

./scripts/gcp-init.sh
./scripts/deploy.sh
```

No undocumented manual steps.

---

# Phase 80: Do not commit generated upstream checkout

Check:

```bash
git status
```

after bootstrap.

Expected ignored directories:

```text
.cache/
.venv/
secrets/
```

should not appear.

---

# Phase 81: Commit strategy

Make logical commits.

Suggested sequence:

```text
1. Initial project structure and secret protections
2. Add pinned Nitter Docker build
3. Add local session generation
4. Add local Docker Compose
5. Add GCP Cloud Run deployment
6. Add documentation and smoke tests
```

Do not create one giant opaque commit if avoidable.

However, prioritize working software over commit cosmetics.

---

# Phase 82: First milestone

STOP after this milestone and verify everything:

```text
.env
  ↓
scripts/create_session.py
  ↓
secrets/sessions.jsonl
  ↓
Docker Compose
 ├── Nitter
 └── Valkey
  ↓
http://localhost:8080
  ↓
real X profile successfully displayed
```

Do NOT touch GCP until this passes.

This separation is important.

It tells us:

```text
X authentication works
Nitter works
Docker works
Valkey works
```

Therefore any subsequent Cloud Run failure is a deployment/configuration problem rather than four simultaneous unknowns.

---

# Phase 83: Second milestone

After local success:

```text
sessions.jsonl
      ↓
Secret Manager
      ↓
Cloud Run
 ├── Nitter
 └── Valkey
      ↓
authenticated *.run.app URL
      ↓
real X profile displayed
```

Acceptance:

```text
min instances = 0
max instances = 1
request-based billing
```

---

# Phase 84: Third milestone

Test lifecycle:

```text
service idle
   ↓
0 instances
   ↓
first request
   ↓
cold start
   ↓
Nitter works
   ↓
second request
   ↓
warm request works
```

Ensure loss of Valkey cache across cold starts does not matter.

---

# Phase 85: Fourth milestone

Security audit:

```text
[ ] no X password in Git
[ ] no X TOTP in Git
[ ] no sessions.jsonl in Git
[ ] no auth_token in Git history
[ ] no secrets baked in Docker image
[ ] no X password in Cloud Run env
[ ] no X TOTP in Secret Manager
[ ] session only in Secret Manager
[ ] HMAC key only in Secret Manager
[ ] logs contain no secrets
```

---

# Phase 86: Final acceptance checklist

## Repository

```text
[ ] Git repository remains clean
[ ] .env ignored
[ ] deploy.env ignored
[ ] secrets ignored
[ ] upstream Nitter not vendored
[ ] exact Nitter commit pinned
[ ] Docker build is reproducible
```

## Session creation

```text
[ ] .env credentials read locally
[ ] browser-based upstream session tool used
[ ] old deprecated HTTP-only login helper not used
[ ] sessions.jsonl generated
[ ] session validated
[ ] session file permissions restricted
[ ] credentials not printed
[ ] session tokens not printed
```

## Local Docker

```text
[ ] Nitter image builds
[ ] Nitter runs non-root
[ ] Valkey runs
[ ] Nitter connects to Valkey
[ ] homepage works
[ ] profile works
[ ] status/tweet works
[ ] media works
[ ] restart works
[ ] cache may safely disappear
```

## GCP

```text
[ ] gcloud setup scripted
[ ] APIs enabled idempotently
[ ] sessions stored in Secret Manager
[ ] HMAC stored in Secret Manager
[ ] X password never uploaded
[ ] X TOTP never uploaded
[ ] Cloud Run deployment works
[ ] Nitter + Valkey live in same Cloud Run service
[ ] min instances = 0
[ ] max instances = 1
[ ] request-based billing / CPU throttling
[ ] conservative concurrency
[ ] Cloud Run URL works
```

## Cold starts

```text
[ ] service scales to zero
[ ] cold startup succeeds
[ ] Valkey starts before Nitter needs it
[ ] session mount available
[ ] first X request succeeds
[ ] warm request succeeds
[ ] cache loss causes no functional problem
```

## Security

```text
[ ] public anonymous access NOT enabled by default
[ ] no secrets in Git
[ ] no secrets in Docker layers
[ ] no secrets in logs
[ ] no secrets in command output
[ ] no credentials inside Cloud Build arguments
```

## Documentation

```text
[ ] README reproduces local setup
[ ] README reproduces GCP setup
[ ] README explains secret model
[ ] README explains session refresh
[ ] README explains Nitter upgrades
[ ] README explains how public access could later be enabled
[ ] README warns about public URL consuming X account capacity
```

---

# Phase 87: Things explicitly NOT to do

DO NOT:

```text
commit `.env`

commit `sessions.jsonl`

commit `auth_token`

commit `ct0`

commit X password

commit TOTP seed

send X password to GCP

send TOTP seed to GCP

put credentials in Docker ARG

put credentials in Docker ENV

put credentials in Docker layers

generate X session during Docker build

generate X session during Cloud Build

generate X session during Cloud Run startup

login to X on every cold start

use deprecated create_session_curl.py

reimplement the X authentication flow

modify upstream Nitter unless necessary

track upstream Nitter master unpinned

deploy Memorystore

deploy Cloud SQL

deploy a VM

deploy GKE

deploy Cloud Functions

deploy Vercel

create persistent Redis storage

enable anonymous Cloud Run access automatically

configure multiple Cloud Run instances

optimize for public traffic

implement rate-limit bypass mechanisms
```

---

# Phase 88: Things Codex should challenge if implementation reality differs

This plan is prescriptive but not dogmatic.

If current versions of:

```text
Nitter
Docker
Cloud Run
gcloud run compose
Secret Manager
Valkey
```

behave differently than expected, inspect the current official behavior and adapt.

In particular verify:

```text
Cloud Run Compose secret syntax
Cloud Run sidecar networking
Cloud Run Compose build arguments
Cloud Run request-based billing flags
Cloud Run min/max instance syntax
Cloud Run concurrency syntax
Cloud Run deterministic hostname format
```

Do not blindly force stale syntax.

Preserve the architectural goals even if implementation details change.

Those goals are:

```text
local X login
only session uploaded
Nitter container
ephemeral Valkey
Cloud Run
scale to zero
maximum one instance
minimal cost
no permanent backend
reproducible deployment
```

---

# Phase 89: Preferred working sequence for Codex

Work in this exact order.

## Step 1

Inspect repository and upstream.

## Step 2

Create:

```text
.gitignore
.dockerignore
.env.example
directory structure
```

## Step 3

Create pinned Docker build.

Build it.

Do not proceed until build succeeds.

## Step 4

Create bootstrap tooling.

Verify `.cache/nitter` and `.venv`.

## Step 5

Create session-generation wrapper.

Generate valid:

```text
secrets/sessions.jsonl
```

Do not proceed until valid.

## Step 6

Generate HMAC key.

## Step 7

Create local Nitter config template and entrypoint.

## Step 8

Create local Compose.

## Step 9

Run local Nitter.

## Step 10

Test a real X profile.

STOP and fix any local problem before GCP.

## Step 11

Create GCP deployment config.

## Step 12

Create idempotent GCP initialization.

## Step 13

Create Secret Manager lifecycle.

## Step 14

Create Cloud Run Compose deployment.

## Step 15

Deploy authenticated service.

## Step 16

Test actual X profile through Cloud Run.

## Step 17

Force/verify:

```text
min = 0
max = 1
request-based billing
```

## Step 18

Test cold start.

## Step 19

Audit secrets.

## Step 20

Finish README.

---

# Phase 90: Completion report expected from Codex

When finished, provide a concise report containing:

```text
Files created
Files modified
Pinned Nitter SHA
Local test result
Cloud Run deployment result
Cloud Run URL
GCP region
Secret names
Scale-to-zero configuration
Maximum instance configuration
Authentication configuration
Any deviations from this plan
Any remaining manual action
```

Never include sensitive values.

Good example:

```text
Implementation complete.

Nitter:
    pinned at abcdef1234...

Local:
    Docker Compose validated
    profile fetching validated

GCP:
    service: my-nitter
    region: europe-west1
    URL: https://...
    min instances: 0
    max instances: 1
    access: authenticated

Secrets:
    my-nitter-sessions
    my-nitter-hmac

X password uploaded to GCP: no
X TOTP uploaded to GCP: no

Remaining manual action:
    none
```

---

# Final architectural target

The completed system should look like this:

```text
┌─────────────────────────────────────────────┐
│ LOCAL MAC                                   │
│                                             │
│ .env                                        │
│ ├── X_USERNAME                              │
│ ├── X_PASSWORD                              │
│ └── X_TOTP_SECRET                           │
│        │                                    │
│        ▼                                    │
│ create_session_browser.py                   │
│        │                                    │
│        ▼                                    │
│ secrets/sessions.jsonl                      │
│        │                                    │
└────────┼────────────────────────────────────┘
         │
         │ upload session only
         ▼
┌─────────────────────────────────────────────┐
│ GCP SECRET MANAGER                          │
│                                             │
│ my-nitter-sessions                          │
│ my-nitter-hmac                              │
└─────────────────┬───────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────┐
│ CLOUD RUN                                   │
│                                             │
│ min instances: 0                            │
│ max instances: 1                            │
│ request-based billing                       │
│                                             │
│ ┌─────────────────────────────────────────┐ │
│ │ Nitter                                  │ │
│ │                                         │ │
│ │ :8080                                   │ │
│ │ sessions.jsonl ← Secret Manager         │ │
│ │ nitter.conf generated on startup        │ │
│ └──────────────┬──────────────────────────┘ │
│                │                            │
│                │ Redis protocol             │
│                ▼                            │
│ ┌─────────────────────────────────────────┐ │
│ │ Valkey                                  │ │
│ │                                         │ │
│ │ :6379                                   │ │
│ │ ephemeral cache                         │ │
│ │ no persistent volume                    │ │
│ └─────────────────────────────────────────┘ │
└─────────────────┬───────────────────────────┘
                  │
                  ▼
               X / Twitter
                  │
                  ▼
          authenticated requests
          using dedicated session


When unused:

Cloud Run
    ↓
0 instances
    ↓
approximately zero compute cost


When requested:

browser
    ↓
Cloud Run cold start
    ↓
Valkey starts
    ↓
Nitter starts
    ↓
X session loaded
    ↓
page served
```

The implementation should optimize for:

```text
simplicity
security
reproducibility
low idle cost
rare personal usage
```

rather than:

```text
high traffic
public hosting
horizontal scaling
persistent infrastructure
zero cold-start latency
```

#!/usr/bin/env bash
# LeoMan installer for the pre-built images (no source checkout, nothing is built). Idempotent: re-running it
# keeps an existing .env and its secrets, and only refreshes the compose files.
#
#   curl -fsSL https://leoman.eyemnv.com/install.sh | bash
#   scripts/install.sh [--dir ~/leoman] [--expose] [--version 1.0.0] [--registry docker.io/eyemnv] [--no-tls-file]
#
#   --dir DIR        install folder (default ~/leoman): docker-compose.yml, .env, secrets/
#   --expose         publish the UI on every interface (LEOMAN_BIND=0.0.0.0); default 127.0.0.1 = this host only
#   --version V      image tag to pin in .env (LEOMAN_VERSION; default: latest)
#   --registry R     image registry (LEOMAN_REGISTRY; default docker.io/eyemnv)
#   --workspace DIR  allowed base folder for agents (WORKSPACE_ROOT_1; default ~/leoman-workspaces)
#   --backup-dir DIR database backups (LEOMAN_BACKUP_DIR; default ~/leoman-backups)
#   LEOMAN_SOURCE=https://raw.githubusercontent.com/<owner>/leoman-release/<ref>   where the compose files are downloaded from
#                (the release repo keeps them flat at its root: compose.release.yml, compose.release.tls.yml)
#
# Run it as the regular (non-root) user whose Claude Code login the agents should use; that user needs access to
# the Docker daemon (member of the `docker` group). The Claude Code CLI is NOT part of LeoMan: install it on this
# host and run `claude` once to sign in.
set -euo pipefail

# The published installer is self-contained: scripts/build-installer.sh puts the compose files and the image-signing
# public key here (payload_* functions). A source checkout runs without them and copies / downloads the files.
payload_compose_release_yml() {
  cat <<'LEOMAN_PAYLOAD_EOF_payload_compose_release_yml'
# LeoMan, release install from pre-built images (no source checkout, nothing is built).
# scripts/install.sh downloads this file as <install dir>/docker-compose.yml next to a generated .env; then:
#   docker compose pull && docker compose up -d
# Upgrade: set LEOMAN_VERSION in .env (or keep `latest`), then `docker compose pull && docker compose up -d`.
# HTTPS front: add deploy/compose.release.tls.yml (COMPOSE_FILE=docker-compose.yml:compose.release.tls.yml).
# Images: leoman-hub, leoman-worker, leoman-backup (and leoman-tls) from $LEOMAN_REGISTRY. The Claude Code CLI is
# NOT in any image: install it on this host and run `claude` once to sign in; the worker mounts the host's copy.
# Host-specific additions (extra masks for private folders) go in docker-compose.override.yml next to this file.
name: leoman

x-logging: &logging
  driver: json-file
  options: { max-size: "20m", max-file: "5" }

services:
  db:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: tether
      POSTGRES_USER: tether
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?run scripts/install.sh}
    volumes: [pgdata:/var/lib/postgresql/data]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U tether -d tether"]
      interval: 5s
      timeout: 3s
      retries: 20
    networks: [backend]
    # hardening: runs directly as the image's postgres user (the data volume is already owned by it), so no
    # capabilities are needed; read-only root, scratch on tmpfs
    user: "70:70"
    read_only: true
    tmpfs:
      - /var/run/postgresql:size=16m,uid=70,gid=70,mode=0775
      - /tmp:size=256m,uid=70,gid=70,mode=1777
    shm_size: 256m
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    deploy:
      resources: { limits: { pids: 512, memory: 2g } }
    logging: *logging

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: ["redis-server", "--requirepass", "${REDIS_PASSWORD:?run scripts/install.sh}", "--appendonly", "yes", "--maxmemory", "512mb", "--maxmemory-policy", "noeviction"]
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD}
    volumes: [redisdata:/data]
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a \"$$REDIS_PASSWORD\" --no-auth-warning ping | grep -q PONG"]
      interval: 5s
      timeout: 3s
      retries: 20
    networks: [backend]
    user: "999:1000"   # the image's redis user (owns /data); no root entrypoint step, no capabilities
    read_only: true
    tmpfs: ["/tmp:size=16m,uid=999,gid=1000,mode=1777"]
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    deploy:
      resources: { limits: { pids: 128, memory: 768m } }   # maxmemory 512mb + AOF rewrite headroom
    logging: *logging

  hub:
    image: ${LEOMAN_REGISTRY:-docker.io/eyemnv}/leoman-hub:${LEOMAN_VERSION:-latest}
    restart: unless-stopped
    depends_on:
      db: { condition: service_healthy }
      redis: { condition: service_healthy }
    environment:
      DATABASE_URL: postgresql+asyncpg://tether:${POSTGRES_PASSWORD}@db:5432/tether
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379/0
      JWT_SECRET: ${JWT_SECRET:?run scripts/install.sh}
      WORKER_TOKEN: ${WORKER_TOKEN:?run scripts/install.sh}
      ADMIN_USERNAME: ${ADMIN_USERNAME:-admin}
      ADMIN_PASSWORD: ${ADMIN_PASSWORD:?run scripts/install.sh}
      PUBLIC_HUB_URL: http://hub:6969
      PERMISSION_TIMEOUT_S: ${PERMISSION_TIMEOUT_S:-1800}
      MAIN_DECISION_TIMEOUT_S: ${MAIN_DECISION_TIMEOUT_S:-90}
      TASK_MAX_SECONDS: ${TASK_MAX_SECONDS:-14400}
      AUTOMATION_TICK_S: ${AUTOMATION_TICK_S:-10}   # §19 schedule ticker period (seconds, ≥ 0.5)
      # §12: encrypts notification secrets at rest (bot tokens, SMTP passwords, webhook secrets, VAPID key)
      LEOMAN_SECRET_KEY: ${LEOMAN_SECRET_KEY:-}
      LEOMAN_PUBLIC_URL: ${LEOMAN_PUBLIC_URL:-}
      NOTIFY_ALLOW_PRIVATE: ${NOTIFY_ALLOW_PRIVATE:-0}
      TELEGRAM_API_BASE: ${TELEGRAM_API_BASE:-https://api.telegram.org}
      NOTIFY_COALESCE_S: ${NOTIFY_COALESCE_S:-15}
      NOTIFY_RATE_PER_MIN: ${NOTIFY_RATE_PER_MIN:-20}
      # §16 folders: "~" of the protected paths and the default allowed base folders (Admin → Folders narrows them)
      HOST_HOME: ${HOST_HOME:?run scripts/install.sh}
      # §16: the operator's own protected paths (comma/colon separated, ~ and globs), locked in Admin → Folders
      LEOMAN_PROTECTED_PATHS: ${LEOMAN_PROTECTED_PATHS:-}
      WORKSPACE_ROOTS: "${WORKSPACE_ROOT_1:?set WORKSPACE_ROOT_1 in .env}:${WORKSPACE_ROOT_2:-}:${WORKSPACE_ROOT_3:-}:${WORKSPACE_ROOT_4:-}"
      # §21 metrics: GET /metrics needs Bearer METRICS_TOKEN (≥ 16 chars; unset = disabled, 404). Optional CIDR list.
      METRICS_TOKEN: ${METRICS_TOKEN:-}
      METRICS_ALLOW_NETS: ${METRICS_ALLOW_NETS:-}
      # §21 backups: the sidecar's host folder (shown in Admin → System; always a protected path for agents)
      LEOMAN_BACKUP_DIR: ${LEOMAN_BACKUP_DIR:?run scripts/install.sh}
      # §25 self-protection: LeoMan's own folder (code, compose files, .env, backups); no agent may touch it
      LEOMAN_INSTALL_DIR: ${LEOMAN_INSTALL_DIR:-}
      BACKUP_STALE_H: ${BACKUP_STALE_H:-36}
      # Every other hub setting (.env.example documents each one). Explicit `${VAR:-default}` lines, never env_file:
      # the hub gets exactly these, and nothing of .env leaks into a container that does not need it. The defaults
      # equal the built-in ones (app/config.py), so an unset variable changes nothing.
      LOG_LEVEL: ${LOG_LEVEL:-INFO}
      DEBUG: ${DEBUG:-0}
      LEOMAN_ALLOW_WEAK_SECRETS: ${LEOMAN_ALLOW_WEAK_SECRETS:-0}   # tests only: weak/placeholder secrets warn instead of refusing to boot
      LEOMAN_FORCE_ADMIN_PASSWORD_CHANGE: ${LEOMAN_FORCE_ADMIN_PASSWORD_CHANGE:-1}   # the bootstrapped admin must pick a new password at first login
      CSP_EXTRA_SRC: ${CSP_EXTRA_SRC:-}
      VAPID_SUBJECT: ${VAPID_SUBJECT:-mailto:admin@leoman.local}
      # login throttling (failures; per username / per client IP), §18
      LOGIN_RATE_PER_MIN: ${LOGIN_RATE_PER_MIN:-10}
      LOGIN_FAIL_WINDOW_S: ${LOGIN_FAIL_WINDOW_S:-900}
      LOGIN_USER_FREE_FAILS: ${LOGIN_USER_FREE_FAILS:-5}
      LOGIN_USER_LOCK_FAILS: ${LOGIN_USER_LOCK_FAILS:-10}
      LOGIN_IP_FREE_FAILS: ${LOGIN_IP_FREE_FAILS:-20}
      LOGIN_IP_LOCK_FAILS: ${LOGIN_IP_LOCK_FAILS:-60}
      LOGIN_BACKOFF_BASE_S: ${LOGIN_BACKOFF_BASE_S:-1}
      LOGIN_BACKOFF_MAX_S: ${LOGIN_BACKOFF_MAX_S:-60}
      LOGIN_LOCKOUT_S: ${LOGIN_LOCKOUT_S:-900}
      # retention built-in defaults (Admin → Retention overrides them)
      EVENTS_RETENTION_DAYS: ${EVENTS_RETENTION_DAYS:-30}
      AUDIT_RETENTION_DAYS: ${AUDIT_RETENTION_DAYS:-180}
      # sessions / limits / timers
      USER_TOKEN_TTL_S: ${USER_TOKEN_TTL_S:-604800}
      AGENT_TOKEN_TTL_S: ${AGENT_TOKEN_TTL_S:-7200}
      MAX_BODY_BYTES: ${MAX_BODY_BYTES:-10485760}
      NODE_OFFLINE_AFTER_S: ${NODE_OFFLINE_AFTER_S:-30}
      NODE_PING_INTERVAL_S: ${NODE_PING_INTERVAL_S:-10}
      RPC_TIMEOUT_S: ${RPC_TIMEOUT_S:-20}
      UI_QUEUE_MAX: ${UI_QUEUE_MAX:-1000}
      SCHEDULER_INTERVAL_S: ${SCHEDULER_INTERVAL_S:-2}
      JANITOR_INTERVAL_S: ${JANITOR_INTERVAL_S:-3600}
      JANITOR_INITIAL_DELAY_S: ${JANITOR_INITIAL_DELAY_S:-120}
      # plain-HTTP mode: proxies whose X-Forwarded-For / -Proto uvicorn trusts (login throttling keys on the client
      # IP). 127.0.0.1 = nobody external. Behind your own reverse proxy put its address here. With
      # docker-compose.tls.yml the TLS front's pinned address replaces this value.
      FORWARDED_ALLOW_IPS: ${FORWARDED_ALLOW_IPS:-127.0.0.1}
      # §22.2: optional JSON overrides of the model price table (terminal agents' cost estimates); Admin → Usage wins
      LEOMAN_MODEL_PRICES: ${LEOMAN_MODEL_PRICES:-}
    # plain-HTTP mode (default). With docker-compose.tls.yml this port is removed and the TLS front owns it.
    ports: ["${LEOMAN_BIND:-127.0.0.1}:${LEOMAN_PORT:-6969}:6969"]
    networks: [backend, edge]
    read_only: true
    tmpfs: ["/tmp:size=256m,uid=10001,gid=10001,mode=0700"]   # multipart upload spill
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    deploy:
      resources: { limits: { pids: 512, memory: 1g } }
    logging: *logging

  # §21 scheduled pg_dump (gzip, daily/weekly retention) to a host folder. Stock postgres image + a read-only
  # script (baked into the leoman-backup image), internal `backend` network only (no new network), the host user, nothing published. The hub only
  # requests ("Backup now") and reports; see docs/ARCHITECTURE.md §21.5 for the restore procedure.
  backup:
    image: ${LEOMAN_REGISTRY:-docker.io/eyemnv}/leoman-backup:${LEOMAN_VERSION:-latest}   # postgres:16-alpine + leoman-backup.sh
    restart: unless-stopped
    depends_on:
      db: { condition: service_healthy }
    environment:
      PGHOST: db
      PGUSER: tether
      PGDATABASE: tether
      PGPASSWORD: ${POSTGRES_PASSWORD}
      BACKUP_DIR: /backups
      LEOMAN_BACKUP_HOST_DIR: ${LEOMAN_BACKUP_DIR:?run scripts/install.sh}
      HOST_HOME: ${HOST_HOME:?run scripts/install.sh}
      # the backup folder may never lie in (or contain) one of the operator's protected paths
      LEOMAN_PROTECTED_PATHS: ${LEOMAN_PROTECTED_PATHS:-}
      BACKUP_INTERVAL_H: ${BACKUP_INTERVAL_H:-24}
      BACKUP_KEEP_DAILY: ${BACKUP_KEEP_DAILY:-7}
      BACKUP_KEEP_WEEKLY: ${BACKUP_KEEP_WEEKLY:-4}
      BACKUP_POLL_S: ${BACKUP_POLL_S:-10}
      BACKUP_RETRY_MIN: ${BACKUP_RETRY_MIN:-30}
    volumes:
      - ${LEOMAN_BACKUP_DIR:?run scripts/install.sh}:/backups
    networks: [backend]
    user: "${HOST_UID:-1000}:${HOST_GID:-1000}"   # files on the host belong to the host user (mode 0600)
    read_only: true
    # the image declares VOLUME /var/lib/postgresql/data: a tiny tmpfs there avoids a new anonymous volume per start
    tmpfs: ["/tmp:size=16m,mode=1777", "/var/lib/postgresql/data:size=1m,mode=0700"]
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    deploy:
      resources: { limits: { pids: 64, memory: 512m } }
    logging: *logging

  # Local node: runs agents on THIS host with the host's authenticated Claude CLI. §16 confinement: the container
  # sees ONLY the allowed base folders (WORKSPACE_ROOT_1..4), the Claude login and its own state dir, never the
  # whole home folder. HOME is an empty tmpfs; the gitignored docker-compose.override.yml may add more masks.
  # scripts/install.sh pre-creates the Claude CLI paths mounted below (else docker creates them root-owned).
  worker-local:
    image: ${LEOMAN_REGISTRY:-docker.io/eyemnv}/leoman-worker:${LEOMAN_VERSION:-latest}
    restart: unless-stopped
    depends_on: [hub]
    user: "${HOST_UID:-1000}:${HOST_GID:-1000}"   # the host user (no sudo in the image)
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    environment:
      HOME: ${HOST_HOME:?run scripts/install.sh}
      HOST_HOME: ${HOST_HOME:?run scripts/install.sh}
      LEOMAN_PROTECTED_PATHS: ${LEOMAN_PROTECTED_PATHS:-}
      PATH: ${HOST_HOME:?run scripts/install.sh}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      HUB_WS_URL: ws://hub:6969/ws/node
      HUB_URL_FOR_AGENTS: http://hub:6969
      # §22: the enrollment token is a read-only secret file, never an environment variable (the container's PID 1
      # would keep an env value readable in /proc/1/environ for every agent process of the same user). The worker
      # reads it only when it has to enroll; afterwards it uses its own node credential (STATE_DIR).
      WORKER_TOKEN_FILE: /run/secrets/worker_token
      NODE_NAME: ${NODE_NAME:-local}
      WORKSPACE_ROOTS: "${WORKSPACE_ROOT_1:?set WORKSPACE_ROOT_1 in .env (an allowed base folder, never the home folder)}:${WORKSPACE_ROOT_2:-}:${WORKSPACE_ROOT_3:-}:${WORKSPACE_ROOT_4:-}"
      MAX_CONCURRENCY: ${MAX_CONCURRENCY:-4}
      STATE_DIR: ${HOST_HOME:?run scripts/install.sh}/.local/state/tether-worker
      CHECKPOINTS: ${CHECKPOINTS:-1}
      CHECKPOINT_TIMEOUT_S: ${CHECKPOINT_TIMEOUT_S:-30}
      CHECKPOINT_MAX_FILES: ${CHECKPOINT_MAX_FILES:-50000}
      CHECKPOINT_MAX_FILE_MB: ${CHECKPOINT_MAX_FILE_MB:-5}
      CHECKPOINT_KEEP: ${CHECKPOINT_KEEP:-200}
      CHECKPOINT_KEEP_DAYS: ${CHECKPOINT_KEEP_DAYS:-14}
      TASK_MAX_SECONDS: ${TASK_MAX_SECONDS:-14400}
      TASK_IDLE_SECONDS: ${TASK_IDLE_SECONDS:-1200}
      HEARTBEAT_SECONDS: ${HEARTBEAT_SECONDS:-10}
      LOG_LEVEL: ${LOG_LEVEL:-INFO}
      LOG_FORMAT: ${LOG_FORMAT:-json}
      # the CLI otherwise hangs at startup on telemetry/update endpoints a firewalled host cannot reach
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1"
      DISABLE_AUTOUPDATER: "1"
    tmpfs:
      - ${HOST_HOME:?run scripts/install.sh}:uid=${HOST_UID:-1000},gid=${HOST_GID:-1000},mode=0700,size=64m
      # the CLI keeps version locks in ~/.local/state/claude (the parent dirs of the binds below are root-owned)
      - ${HOST_HOME:?run scripts/install.sh}/.local/state:uid=${HOST_UID:-1000},gid=${HOST_GID:-1000},mode=0700,size=16m
    volumes:
      # allowed base folders, same path inside & outside (unused slots mount /dev/null at a dummy path)
      - ${WORKSPACE_ROOT_1}:${WORKSPACE_ROOT_1}
      - ${WORKSPACE_ROOT_2:-/dev/null}:${WORKSPACE_ROOT_2:-/opt/leoman/unused-root-2}
      - ${WORKSPACE_ROOT_3:-/dev/null}:${WORKSPACE_ROOT_3:-/opt/leoman/unused-root-3}
      - ${WORKSPACE_ROOT_4:-/dev/null}:${WORKSPACE_ROOT_4:-/opt/leoman/unused-root-4}
      # Claude login + sessions (rw: the CLI refreshes tokens and writes session files; same path as on the host so
      # `claude --resume` works from the host too). The CLI binary itself is read-only.
      - ${HOST_HOME:?run scripts/install.sh}/.claude:${HOST_HOME:?run scripts/install.sh}/.claude
      - ${HOST_HOME:?run scripts/install.sh}/.claude.json:${HOST_HOME:?run scripts/install.sh}/.claude.json
      - ${HOST_HOME:?run scripts/install.sh}/.local/bin:${HOST_HOME:?run scripts/install.sh}/.local/bin:ro
      - ${HOST_HOME:?run scripts/install.sh}/.local/share/claude:${HOST_HOME:?run scripts/install.sh}/.local/share/claude:ro
      # worker state (outbox, shadow checkpoints, extension cache); test stacks point it elsewhere
      - ${LEOMAN_WORKER_STATE:-${HOST_HOME:?run scripts/install.sh}/.local/state/tether-worker}:${HOST_HOME:?run scripts/install.sh}/.local/state/tether-worker
    secrets:
      - worker_token   # /run/secrets/worker_token (read-only; a built-in protected path for agents)
    working_dir: /tmp
    networks: [edge]
    deploy:
      resources: { limits: { memory: 6g } }
    logging: *logging

volumes:
  pgdata:
  redisdata:

secrets:
  # created by scripts/install.sh from .env's WORKER_TOKEN: mode 0400, owned by HOST_UID (the worker's user)
  worker_token:
    file: ${LEOMAN_WORKER_TOKEN_FILE:-./secrets/worker_token}

# Subnets are ALWAYS pinned (defaults 172.30.0.0/24 + 172.30.1.0/24; change them with LEOMAN_BACKEND_SUBNET /
# LEOMAN_EDGE_SUBNET when they clash with your network). Never let Docker auto-allocate: once 172.17-31 are used up
# it falls back to other private ranges, which can collide with a real LAN and cut the host off.
# scripts/net-guard.sh checks every bridge network (allowed range: NET_GUARD_ALLOWED, default 172.16.0.0/12).
networks:
  backend:
    internal: true   # db + redis: reachable only by the hub, never by agents/terminals
    ipam:
      config:
        - subnet: ${LEOMAN_BACKEND_SUBNET:-172.30.0.0/24}
  edge:
    ipam:
      config:
        - subnet: ${LEOMAN_EDGE_SUBNET:-172.30.1.0/24}
LEOMAN_PAYLOAD_EOF_payload_compose_release_yml
}
payload_compose_release_tls_yml() {
  cat <<'LEOMAN_PAYLOAD_EOF_payload_compose_release_tls_yml'
# Optional HTTPS front for a release install (pre-built images). Download it next to docker-compose.yml and add
# to .env:
#   COMPOSE_FILE=docker-compose.yml:compose.release.tls.yml
# (list docker-compose.override.yml before it if you have one). Same behaviour as the source tree's
# docker-compose.tls.yml: the hub is no longer published; nginx terminates HTTPS on LEOMAN_BIND:LEOMAN_PORT; certs
# come from ./tls (cert.pem + key.pem) or a private CA kept in the `tlscerts` volume.
services:
  hub:
    ports: !reset []
    environment:
      # trust X-Forwarded-For / -Proto only from the front's pinned address (login throttling keys on client IP)
      FORWARDED_ALLOW_IPS: ${LEOMAN_EDGE_PROXY_IP:-172.30.1.250}

  tls-init:
    image: ${LEOMAN_REGISTRY:-docker.io/eyemnv}/leoman-hub:${LEOMAN_VERSION:-latest}
    depends_on: [hub]
    restart: "no"
    user: "0:0"          # to read a root-only key.pem and hand the files to uid 10001
    command: ["python", "-m", "app.tlsgen"]
    environment:
      TLS_OUT: /certs
      TLS_CUSTOM: /custom
      TLS_OWNER: "10001:10001"
      LEOMAN_TLS_SANS: ${LEOMAN_TLS_SANS:-}
    volumes:
      - tlscerts:/certs
      - ${LEOMAN_TLS_DIR:-./tls}:/custom:ro
    network_mode: none
    read_only: true
    tmpfs: ["/tmp:size=16m"]
    cap_drop: [ALL]
    cap_add: [CHOWN, DAC_OVERRIDE, FOWNER]
    security_opt: ["no-new-privileges:true"]
    deploy:
      resources: { limits: { pids: 32, memory: 128m } }
    logging: { driver: json-file, options: { max-size: "20m", max-file: "5" } }

  tls:
    image: ${LEOMAN_REGISTRY:-docker.io/eyemnv}/leoman-tls:${LEOMAN_VERSION:-latest}   # nginx:alpine + deploy/tls/nginx.conf
    restart: unless-stopped
    depends_on:
      tls-init: { condition: service_completed_successfully, restart: true }   # new cert → nginx restarts
      hub: { condition: service_started }
    user: "10001:10001"
    volumes:
      - tlscerts:/certs:ro
    ports: ["${LEOMAN_BIND:-127.0.0.1}:${LEOMAN_PORT:-6969}:8443"]
    networks:
      edge:
        ipv4_address: ${LEOMAN_EDGE_PROXY_IP:-172.30.1.250}
    read_only: true
    tmpfs: ["/tmp:size=64m,uid=10001,gid=10001,mode=0700"]
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    deploy:
      resources: { limits: { pids: 64, memory: 256m } }
    logging: { driver: json-file, options: { max-size: "20m", max-file: "5" } }

volumes:
  tlscerts:
LEOMAN_PAYLOAD_EOF_payload_compose_release_tls_yml
}
payload_cosign_pub() {
  cat <<'LEOMAN_PAYLOAD_EOF_payload_cosign_pub'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEIAeSblcnRxYJ0hZtF/f3xpXk3pay
2s0buWLj20rEhKbeII6eMlaa6FyRzqfe9EgSGtzBMpdIFDqD4ulQYv9BnQ==
-----END PUBLIC KEY-----
LEOMAN_PAYLOAD_EOF_payload_cosign_pub
}

dir="$HOME/leoman"
bind=127.0.0.1
version=""
registry=""
workspace="$HOME/leoman-workspaces"
backup="$HOME/leoman-backups"
tls_file=1
source_base=${LEOMAN_SOURCE:-https://raw.githubusercontent.com/eyemnv/leoman-release/main}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) dir=${2:?--dir needs a folder}; shift ;;
    --expose) bind=0.0.0.0 ;;
    --version) version=${2:?--version needs a tag}; shift ;;
    --registry) registry=${2:?--registry needs a value}; shift ;;
    --workspace) workspace=${2:?--workspace needs a folder}; shift ;;
    --backup-dir) backup=${2:?--backup-dir needs a folder}; shift ;;
    --no-tls-file) tls_file=0 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 2; }

# ---------------------------------------------------------------------------------------------- checks
if [[ "$(id -u)" = 0 ]]; then
  cat >&2 <<'EOF'
install.sh: refusing to run as root.
  LeoMan's worker runs agents as the host user whose Claude Code login they use, never as root (uid 0).
  Create (or pick) a regular user, give it Docker access, and run the installer as that user:
    sudo useradd -m -s /bin/bash leoman        # or use your own account
    sudo usermod -aG docker leoman             # log out and in again afterwards
    sudo -iu leoman bash -c 'curl -fsSL https://leoman.eyemnv.com/install.sh | bash'
EOF
  exit 2
fi
command -v docker >/dev/null || die "docker is not installed (https://docs.docker.com/engine/install/)"
docker compose version >/dev/null 2>&1 || die "the Docker Compose v2 plugin is missing ('docker compose version' fails)"
docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon as $(id -un): is it running, and is $(id -un) in the 'docker' group?"
for p in "$dir" "$workspace" "$backup"; do
  [[ "$p" = /* ]] || die "folders must be absolute paths (got '$p')"
done
for p in "$workspace" "$backup"; do
  case "${p%/}" in ""|/|"${HOME%/}") die "'$p' cannot be / or your home folder itself" ;; esac
done

rnd() {  # strong random alphanumeric string of length $1
  local v=""
  if command -v openssl >/dev/null; then v=$(openssl rand -base64 128 | tr -dc 'A-Za-z0-9' | head -c "$1" || true); fi
  [[ ${#v} -ge $1 ]] || v=$(head -c 256 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$1" || true)
  [[ ${#v} -ge $1 ]] || die "could not generate a random secret"
  printf '%s' "$v"
}

payload_fn() {  # deploy/compose.release.tls.yml -> payload_compose_release_tls_yml
  local b; b=$(basename "$1"); printf 'payload_%s' "${b//[.-]/_}"
}

fetch() {  # $1 = path in the repository, $2 = destination; embedded payload > local checkout > download
  local here src fn
  fn=$(payload_fn "$1")
  if declare -F "$fn" >/dev/null; then
    "$fn" > "$2.tmp" && mv "$2.tmp" "$2"
    return
  fi
  here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
  local flat; flat=$(basename "$1")  # the release repo is flat; a source checkout keeps deploy/
  if [[ -n "$here" && -f "$here/../$1" ]]; then
    cp "$here/../$1" "$2.tmp"
  elif [[ -n "$here" && -f "$here/$flat" ]]; then
    cp "$here/$flat" "$2.tmp"
  elif command -v curl >/dev/null; then
    curl -fsSL "$source_base/$flat" -o "$2.tmp" || die "download failed: $source_base/$flat"
  elif command -v wget >/dev/null; then
    wget -qO "$2.tmp" "$source_base/$flat" || die "download failed: $source_base/$flat"
  else
    die "need curl or wget to download $1"
  fi
  mv "$2.tmp" "$2"
}

# ---------------------------------------------------------------------------------------------- files
mkdir -p "$dir" && chmod 700 "$dir"
cd "$dir"
fetch deploy/compose.release.yml docker-compose.yml
say "Wrote $dir/docker-compose.yml"
if [[ "$tls_file" = 1 ]]; then
  fetch deploy/compose.release.tls.yml compose.release.tls.yml
  say "Wrote $dir/compose.release.tls.yml (optional HTTPS front; see the file's header)"
fi

envval() { grep -s "^$1=" .env | tail -1 | cut -d= -f2- || true; }
if [[ -f .env ]]; then
  say "Keeping the existing $dir/.env (secrets unchanged)."
  grep -q '^LEOMAN_BACKUP_DIR=' .env || echo "LEOMAN_BACKUP_DIR=$backup" >> .env
  grep -q '^HOST_HOME=' .env || echo "HOST_HOME=$HOME" >> .env
  grep -q '^LEOMAN_INSTALL_DIR=' .env || echo "LEOMAN_INSTALL_DIR=$(pwd -P)" >> .env
  [[ -z "$version" ]] || { grep -q '^LEOMAN_VERSION=' .env && say "NOTE: LEOMAN_VERSION already set in .env; not changed"; } \
    || echo "LEOMAN_VERSION=$version" >> .env
  ADMIN_PW=""
else
  ADMIN_PW=$(rnd 20)
  (umask 077 && cat > .env <<ENV
# LeoMan release install, generated by scripts/install.sh. Every setting: .env.example in the LeoMan repository.
POSTGRES_PASSWORD=$(rnd 32)
REDIS_PASSWORD=$(rnd 40)
JWT_SECRET=$(rnd 64)
WORKER_TOKEN=$(rnd 48)
LEOMAN_SECRET_KEY=$(rnd 64)
METRICS_TOKEN=$(rnd 40)
ADMIN_USERNAME=admin
ADMIN_PASSWORD=${ADMIN_PW}
HOST_UID=$(id -u)
HOST_GID=$(id -g)
HOST_HOME=${HOME}
WORKSPACE_ROOT_1=${workspace}
NODE_NAME=$(hostname -s 2>/dev/null || echo local)
MAX_CONCURRENCY=4
LEOMAN_BIND=${bind}
LEOMAN_BACKUP_DIR=${backup}
# §25: LeoMan's own folder; agents can never change, copy or read it
LEOMAN_INSTALL_DIR=$(pwd -P)
# Your own private folders/files that agents may never touch (comma separated, ~/ and globs), e.g. ~/private:
LEOMAN_PROTECTED_PATHS=
ENV
  )
  [[ -z "$version" ]] || echo "LEOMAN_VERSION=$version" >> .env
  [[ -z "$registry" ]] || echo "LEOMAN_REGISTRY=$registry" >> .env
  chmod 600 .env
  say "Created $dir/.env (mode 0600) with random secrets"
fi

# §22 the worker's enrollment token: a read-only secret file (same value as WORKER_TOKEN), never an env variable
tok=$(envval WORKER_TOKEN)
if [[ ! -f secrets/worker_token ]]; then
  mkdir -p secrets && chmod 700 secrets
  (umask 077 && printf '%s\n' "$tok" > secrets/worker_token) && chmod 400 secrets/worker_token
  say "Created $dir/secrets/worker_token (mode 0400)"
fi

# folders the containers bind-mount: created now as this user (docker would create missing ones owned by root)
h=$(envval HOST_HOME)
bk=$(envval LEOMAN_BACKUP_DIR)
ws=$(envval WORKSPACE_ROOT_1)
(umask 077 && mkdir -p "$bk/leoman-db")
mkdir -p "$ws" "$h/.claude" "$h/.local/bin" "$h/.local/share/claude" "$h/.local/state"
[[ -e "$h/.claude.json" ]] || (umask 077 && printf '{}\n' > "$h/.claude.json")
say "Prepared $bk (backups), $ws (agent folders) and the Claude Code paths under $h"

# image signatures: the public key ships with the installer; verified here when cosign is installed
if declare -F payload_cosign_pub >/dev/null; then
  payload_cosign_pub > cosign.pub
  reg=$(envval LEOMAN_REGISTRY); reg=${reg:-docker.io/eyemnv}
  ver=$(envval LEOMAN_VERSION); ver=${ver:-latest}
  if command -v cosign >/dev/null; then
    for img in hub worker backup tls; do
      cosign verify --key cosign.pub "$reg/leoman-$img:$ver" >/dev/null 2>&1 \
        || die "the signature of $reg/leoman-$img:$ver does not verify with $dir/cosign.pub, do not start it"
    done
    say "Verified the image signatures ($reg, $ver) with $dir/cosign.pub"
  else
    say "Image signatures: install cosign and run  cosign verify --key $dir/cosign.pub $reg/leoman-hub:$ver  (optional)"
  fi
fi

# ---------------------------------------------------------------------------------------------- next steps
port=$(envval LEOMAN_PORT); port=${port:-6969}
b=$(envval LEOMAN_BIND); b=${b:-127.0.0.1}
cat <<EOF

LeoMan is ready to start. Next steps:
  1. Install Claude Code on this host (as $(id -un)) and run \`claude\` once to sign in.
     LeoMan does not include the Claude Code CLI; its worker uses this host's signed-in copy
     ($h/.local/bin/claude and $h/.claude).$( [[ -x "$h/.local/bin/claude" ]] && printf ' (found: ok)' )
  2. Optional: list private folders/files agents must never touch in $dir/.env (LEOMAN_PROTECTED_PATHS).
  3. Start it:
       cd $dir && docker compose pull && docker compose up -d
  4. Open http://$( [[ "$b" = 0.0.0.0 ]] && echo '<this host>' || echo "$b" ):$port and sign in as admin$( [[ -n "$ADMIN_PW" ]] && printf ' / %s' "$ADMIN_PW" ).
     Change the password after the first login (it is also in $dir/.env).
  Agents work only inside $ws (more folders: WORKSPACE_ROOT_2..4 in .env).
  HTTPS for the LAN: add COMPOSE_FILE=docker-compose.yml:compose.release.tls.yml to .env, set LEOMAN_BIND=0.0.0.0.
EOF

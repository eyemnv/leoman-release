#!/usr/bin/env bash
# LeoMan installer for the pre-built images (no source checkout, nothing is built). Idempotent: re-running it
# keeps an existing .env and its secrets, and only refreshes the compose files.
#
#   curl -fsSL https://leoman.eyemnv.com/install.sh | bash
#   curl -fsSL https://leoman.eyemnv.com/install.sh | bash -s -- --expose        # other computers connect (HTTPS)
#   scripts/install.sh [--dir ~/leoman] [--expose] [--https|--http] [--version 1.0.0] [--registry docker.io/eyemnv]
#
#   --dir DIR          install folder (default ~/leoman): docker-compose.yml, .env, secrets/
#   --expose           publish the UI on every interface (LEOMAN_BIND=0.0.0.0); default 127.0.0.1 = this host only.
#                      A new --expose install uses HTTPS with LeoMan's own certificate authority and lets other
#                      machines connect only encrypted (LEOMAN_REQUIRE_TLS_NODES=1). Add --http to keep plain HTTP.
#   --https            switch the HTTPS front on (new or existing install): COMPOSE_FILE, LEOMAN_REQUIRE_TLS_NODES=1
#                      and the certificate names (LEOMAN_TLS_SANS: this host's names and network addresses are added)
#   --http             a new install stays on plain HTTP, even with --expose or --offline (not recommended)
#   --tls-add-name N   add a name or address (e.g. 192.168.10.22 or leoman.example.lan) to the certificate of an
#                      existing install and renew the certificate now; repeatable. The certificate authority stays
#                      the same, so machines that are already connected keep working.
#   --tls-renew        renew the certificate now (also adds new addresses of this host); the CA stays the same.
#                      Not needed for expiry: LeoMan renews it on its own 30 days before it ends (tls-renew).
#   --ca-info          show the certificate authority's fingerprint and the names the certificate covers, then exit
#   --version V        image tag to pin in .env (LEOMAN_VERSION; default: latest). On an existing install it changes
#                      the pinned version (then run: docker compose pull && docker compose up -d)
#   --registry R       image registry (LEOMAN_REGISTRY; default docker.io/eyemnv)
#   --workspace DIR    allowed base folder for agents (WORKSPACE_ROOT_1; default ~/leoman-workspaces)
#   --backup-dir DIR   database backups (LEOMAN_BACKUP_DIR; default ~/leoman-backups)
#   --offline B        air-gapped install from a bundle (scripts/build-offline-bundle.sh; .tar.gz or its unpacked
#                      folder): checks SHA256SUMS (+ its cosign signature when cosign is installed), `docker load`s the
#                      images and never touches the network. HTTPS with LeoMan's private CA by default
#                      (LEOMAN_REQUIRE_TLS_NODES=1), LEOMAN_OFFLINE=1 and LEOMAN_UPDATE_CHECK=0 (no registry to ask).
#   --load-only        with --offline: only verify + load the images (other machines that run a worker)
#   LEOMAN_SOURCE=https://raw.githubusercontent.com/<owner>/leoman-release/<ref>   where the compose files are
#                      downloaded from when they are not embedded (flat: compose.release.yml, compose.release.tls.yml)
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
      # §27 update check: newest release of $LEOMAN_REGISTRY/leoman-hub, every 12 h (0 = off, e.g. air-gapped sites)
      LEOMAN_UPDATE_CHECK: ${LEOMAN_UPDATE_CHECK:-1}
      LEOMAN_REGISTRY: ${LEOMAN_REGISTRY:-docker.io/eyemnv}
      # §18 air-gapped install (install.sh --offline): Settings → About shows the offline update steps
      LEOMAN_OFFLINE: ${LEOMAN_OFFLINE:-0}
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
      # §18: refuse machines (/ws/node) that do not connect through the HTTPS front; the local worker's network
      # (the edge subnet; never its .1 gateway, where published-port traffic appears) is exempt. Recommended: 1
      LEOMAN_REQUIRE_TLS_NODES: ${LEOMAN_REQUIRE_TLS_NODES:-0}
      LEOMAN_LOCAL_NODE_NETS: ${LEOMAN_EDGE_SUBNET:-172.30.1.0/24}
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

  # §21 scheduled pg_dump (gzip, daily/weekly retention) to a host folder. The leoman-backup image (Alpine + the
  # PostgreSQL 16 client tools + a read-only script), internal `backend` network only (no new network), the host user, nothing published. The hub only
  # requests ("Backup now") and reports; see docs/ARCHITECTURE.md §21.5 for the restore procedure.
  backup:
    image: ${LEOMAN_REGISTRY:-docker.io/eyemnv}/leoman-backup:${LEOMAN_VERSION:-latest}   # alpine + postgresql16-client + leoman-backup.sh
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
      # Codex / Gemini CLI: the standalone installs and their logins live here (~/.local/bin/codex links into
      # ~/.codex/packages); rw because the CLIs refresh tokens and write sessions. Claude agents can't read them (confine.py).
      - ${HOST_HOME:?run scripts/install.sh}/.codex:${HOST_HOME:?run scripts/install.sh}/.codex
      - ${HOST_HOME:?run scripts/install.sh}/.gemini:${HOST_HOME:?run scripts/install.sh}/.gemini
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
# come from ./tls (cert.pem + key.pem) or a private CA kept in the `tlscerts` volume. `tls-renew` checks once a day
# and renews the server certificate 30 days before it ends (same CA, so machines and browsers keep trusting it) or
# installs updated ./tls files; the front reloads them without a restart.

x-tlsgen: &tlsgen
  image: ${LEOMAN_REGISTRY:-docker.io/eyemnv}/leoman-hub:${LEOMAN_VERSION:-latest}
  user: "0:0"          # to read a root-only key.pem and hand the files to uid 10001
  environment:
    TLS_OUT: /certs
    TLS_CUSTOM: /custom
    TLS_OWNER: "10001:10001"
    TLS_PUB: /pub
    LEOMAN_TLS_SANS: ${LEOMAN_TLS_SANS:-}
    TLS_LEAF_DAYS: ${LEOMAN_TLS_LEAF_DAYS:-397}                   # server certificate lifetime (at most 397 days)
    TLS_CHECK_INTERVAL_S: ${LEOMAN_TLS_CHECK_INTERVAL_S:-86400}   # tls-renew: how often it checks
  volumes:
    - tlscerts:/certs
    - tlspub:/pub
    - ${LEOMAN_TLS_DIR:-./tls}:/custom:ro
  network_mode: none
  read_only: true
  tmpfs: ["/tmp:size=16m"]
  cap_drop: [ALL]
  cap_add: [CHOWN, DAC_OVERRIDE, FOWNER]
  security_opt: ["no-new-privileges:true"]
  healthcheck: { disable: true }   # the hub image's own check (its web port) does not apply here
  logging: { driver: json-file, options: { max-size: "20m", max-file: "5" } }

# nginx plus a certificate watcher: when tls-init / tls-renew change server.crt / server.key, the new files are
# checked (nginx -t) and nginx reloads gracefully; files that do not load yet are retried, the old ones stay served
x-tls-entrypoint: &tls_entrypoint
  - /bin/sh
  - -c
  - |
    conf=/etc/leoman/nginx.conf
    sig() { cat /certs/server.crt /certs/server.key 2>/dev/null | sha256sum; }
    nginx -c "$$conf" -g 'daemon off;' &
    pid=$$!
    stop=0
    spid=
    trap 'stop=1; kill -QUIT $$pid 2>/dev/null; [ -z "$$spid" ] || kill $$spid 2>/dev/null' QUIT
    trap 'stop=1; kill -TERM $$pid 2>/dev/null; [ -z "$$spid" ] || kill $$spid 2>/dev/null' TERM INT
    every=$$TLS_WATCH_S
    [ -n "$$every" ] || every=60
    last=$$(sig)
    while [ "$$stop" = 0 ] && kill -0 "$$pid" 2>/dev/null; do
      sleep "$$every" & spid=$$!
      wait "$$spid" 2>/dev/null
      spid=
      [ "$$stop" = 0 ] || break
      cur=$$(sig)
      [ "$$cur" != "$$last" ] || continue
      if nginx -t -q -c "$$conf" 2>/dev/null; then
        nginx -s reload -c "$$conf" && last=$$cur && echo "tls: the certificate changed; reloaded nginx (no restart)"
      else
        echo "tls: the new certificate files do not load (yet); still serving the previous ones"
      fi
    done
    wait "$$pid"

services:
  hub:
    ports: !reset []
    environment:
      # trust X-Forwarded-For / -Proto only from the front's pinned address (login throttling keys on client IP)
      FORWARDED_ALLOW_IPS: ${LEOMAN_EDGE_PROXY_IP:-172.30.1.250}
      # §18: Add a machine shows the private CA's fingerprint (HUB_CA_SHA256) from tls-init's public copy
      LEOMAN_TLS_FRONT: "1"
      LEOMAN_TLS_CA_FILE: /tlspub/ca.crt
    volumes:
      - tlspub:/tlspub:ro   # ca.crt, sans.txt, server.crt only (no key ever lands in this volume)

  tls-init:
    <<: *tlsgen
    depends_on: [hub]
    restart: "no"
    command: ["python", "-m", "app.tlsgen"]
    deploy:
      resources: { limits: { pids: 32, memory: 128m } }

  tls-renew:
    <<: *tlsgen
    depends_on:
      tls-init: { condition: service_completed_successfully }
    restart: unless-stopped
    command: ["python", "-m", "app.tlsgen", "--loop"]
    stop_grace_period: 5s
    deploy:
      resources: { limits: { pids: 16, memory: 96m } }

  tls:
    image: ${LEOMAN_REGISTRY:-docker.io/eyemnv}/leoman-tls:${LEOMAN_VERSION:-latest}   # nginx:alpine + deploy/tls/nginx.conf
    restart: unless-stopped
    depends_on:
      tls-init: { condition: service_completed_successfully, restart: true }
      hub: { condition: service_started }
    user: "10001:10001"
    entrypoint: *tls_entrypoint
    environment:
      TLS_WATCH_S: ${LEOMAN_TLS_WATCH_S:-60}   # how often the front looks for new certificate files (seconds)
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
  tlspub:
LEOMAN_PAYLOAD_EOF_payload_compose_release_tls_yml
}
payload_cosign_pub() {
  cat <<'LEOMAN_PAYLOAD_EOF_payload_cosign_pub'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEL9SNUkqNZS6u1DZJ5fwXZY6nvhid
Vivw+tpn2Ep0sGejN/P3paTIFntjxtNLx/FpcfiZPNLkt8TySjrCgMY/hA==
-----END PUBLIC KEY-----
LEOMAN_PAYLOAD_EOF_payload_cosign_pub
}

say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 2; }

# ---------------------------------------------------------------------------------------------- certificate names
# §18: every address / name of this host goes into the HTTPS certificate (LEOMAN_TLS_SANS), so browsers and other
# machines can use any of them. tls-init runs without a network and cannot look itself, so the installer does. One
# implementation for the online and the offline install and for --tls-add-name. Docker's own interfaces (docker0,
# br-*, veth*, ...) are skipped by interface, never by address range: a real LAN may well use 172.16.0.0/12.
# Entries already in .env are never dropped.
san_ok() { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.:-]{0,252})$ ]]; }

sans_from_ip_output() {  # stdin: `ip -o addr show`; stdout: one address per line (no loopback / Docker / link-local)
  local _n ifc fam addr _rest
  while read -r _n ifc fam addr _rest; do
    ifc=${ifc%:}; ifc=${ifc%%@*}
    case "$ifc" in lo|docker*|br-*|veth*|virbr*|cni*|flannel*|cali*|vxlan*|kube-*|podman*|lxcbr*|lxdbr*|cilium*|weave*) continue ;; esac
    [[ $fam = inet || $fam = inet6 ]] || continue
    case " $_rest " in *" scope host "*|*" scope link "*) continue ;; esac
    # IPv6 privacy addresses change every day; tentative / deprecated ones are not (or no longer) usable
    case " ${_rest//\\/ } " in *" temporary "*|*" deprecated "*|*" tentative "*|*" dadfailed "*) continue ;; esac
    addr=${addr%%/*}
    case "$addr" in 127.*|::1|fe80:*|FE80:*) continue ;; esac
    san_ok "$addr" && printf '%s\n' "$addr"
  done
}

detect_sans() {  # this host's non-loopback, non-Docker addresses + short and full host name, comma separated
  local out gws
  out=$( {
    if command -v ip >/dev/null 2>&1; then
      ip -o addr show 2>/dev/null | sans_from_ip_output
    else  # no iproute2: hostname -I minus the gateways of Docker's networks (= the addresses of its interfaces)
      gws=$(docker network ls -q 2>/dev/null | xargs -r docker network inspect \
              --format '{{range .IPAM.Config}}{{.Gateway}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep -v '^$' || true)
      hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | grep -vE '^(127\.|::1$|fe80:)' | grep -vxF -e "${gws:-#none#}" || true
    fi
    hostname -s 2>/dev/null || true
    if command -v timeout >/dev/null; then timeout 3 hostname -f 2>/dev/null || true; else hostname -f 2>/dev/null || true; fi
  } | while read -r n; do [[ -n $n && $n != localhost* ]] && san_ok "$n" && printf '%s\n' "$n"; done || true)
  merge_sans "" "$(printf '%s' "$out" | paste -sd, -)"
}

merge_sans() {  # $1 existing list (kept first, in order), $2 additions -> deduplicated (names case-insensitive) list
  local -a out=() parts=(); local -A seen=(); local x k
  IFS=', ' read -ra parts <<< "$1,$2" || true
  for x in "${parts[@]}"; do
    x=${x// /}; [[ -n $x ]] || continue
    k=${x,,}
    [[ -z ${seen[$k]:-} ]] || continue
    seen[$k]=1; out+=("$x")
  done
  local IFS=,; printf '%s' "${out[*]}"
}

# .env helpers (the current directory is the install folder)
envval() { grep -s "^$1=" .env | tail -1 | cut -d= -f2- || true; }
setenv() {  # set or replace KEY=VALUE in .env, keeping its mode (0600)
  local tmp
  if grep -q "^$1=" .env 2>/dev/null; then
    tmp=$(mktemp .env.XXXXXX)
    awk -v k="$1=" -v v="$2" 'index($0, k) == 1 { if (!done) print k v; done = 1; next } { print }' .env > "$tmp"
    chmod 600 "$tmp" && mv "$tmp" .env
  else
    echo "$1=$2" >> .env
  fi
}
tls_on() { [[ $(envval COMPOSE_FILE) == *compose.release.tls.yml* ]]; }

# the running install's certificate (tls-init's volumes; never the private key): fp=, sans=, until=
TLS_INFO_PY='
import hashlib, os, ssl
p = "/pub/ca.crt"
if os.path.isfile(p):
    h = hashlib.sha256(ssl.PEM_cert_to_DER_cert(open(p).read())).hexdigest().upper()
    print("fp=" + ":".join(h[i:i + 2] for i in range(0, 64, 2)))
s = "/certs/sans.txt"
print("sans=" + (open(s).read().strip() if os.path.isfile(s) else ""))
try:
    from cryptography import x509
    c = x509.load_pem_x509_certificate(open("/certs/server.crt", "rb").read())
    print("until=" + c.not_valid_after_utc.strftime("%Y-%m-%d"))
except Exception:
    pass
'
tls_info() { docker compose run --rm --no-deps -T --entrypoint python tls-init -c "$TLS_INFO_PY" 2>/dev/null || true; }

[[ ${LEOMAN_INSTALL_LIB:-0} != 1 ]] || return 0 2>/dev/null || exit 0   # tests: load the helpers above only

dir="$HOME/leoman"
bind=127.0.0.1
version=""
registry=""
workspace="$HOME/leoman-workspaces"
backup="$HOME/leoman-backups"
tls_file=1
offline=""
load_only=0
https_opt=""      # "" = default (on for a new --expose or --offline install), on = --https, off = --http
add_names=()
ca_info=0
renew=0
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
    --offline) offline=${2:?--offline needs a bundle file or folder}; shift ;;
    --load-only) load_only=1 ;;
    --https) https_opt=on ;;
    --http) https_opt=off ;;
    --tls-add-name) n=${2:?--tls-add-name needs a name or IP address}; shift
                    san_ok "$n" || die "--tls-add-name: '$n' is not a host name or IP address"
                    add_names+=("$n") ;;
    --tls-renew) renew=1 ;;
    --ca-info) ca_info=1 ;;
    -h|--help)
      if [[ -f ${BASH_SOURCE[0]:-} ]]; then sed -n '2,39p' "${BASH_SOURCE[0]}"
      else say "Options: --dir --expose --https --http --tls-add-name --tls-renew --ca-info --version --registry --workspace --backup-dir --offline --load-only. Guide: https://leoman.eyemnv.com"; fi
      exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done
[[ -z $version || $version =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "--version: '$version' is not an image tag"
[[ -z $registry || $registry =~ ^[A-Za-z0-9._/:-]+$ ]] || die "--registry: '$registry' is not a registry path"

# how to run this installer again (shown in the next steps): the copy in the install folder (kept below) when there
# is a file to copy, else the download
src_self=${BASH_SOURCE[0]:-}; [[ -f "$src_self" ]] && src_self=$(cd "$(dirname "$src_self")" && pwd)/$(basename "$src_self") || src_self=""
if [[ -n $src_self ]]; then self="bash $dir/install.sh --dir $dir"
else self="curl -fsSL https://leoman.eyemnv.com/install.sh | bash -s --"; [[ $dir = "$HOME/leoman" ]] || self="$self --dir $dir"; fi
[[ -n $src_self || ! -f $dir/install.sh ]] || self="bash $dir/install.sh --dir $dir"

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
docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon as $(id -un): is it running, and is $(id -un) in the 'docker' group?"
[[ $load_only = 0 || -n "$offline" ]] || die "--load-only needs --offline <bundle>"

# ---------------------------------------------------------------------------------------------- certificate upkeep
# --tls-add-name / --tls-renew / --ca-info work on an existing install and change nothing else.
if [[ ${#add_names[@]} -gt 0 || $ca_info = 1 || $renew = 1 ]]; then
  [[ -z $offline ]] || die "--tls-add-name, --tls-renew and --ca-info cannot be combined with --offline"
  [[ -f "$dir/.env" ]] || die "there is no LeoMan installation in $dir (use --dir <folder>)"
  cd "$dir"
  docker compose version >/dev/null 2>&1 || die "the Docker Compose v2 plugin is missing ('docker compose version' fails)"
  if [[ ${#add_names[@]} -gt 0 || $renew = 1 ]]; then
    old=$(envval LEOMAN_TLS_SANS)
    adds=$(IFS=,; printf '%s' "${add_names[*]+"${add_names[*]}"}")
    new=$(merge_sans "$old" "$(merge_sans "$(detect_sans)" "$adds")")
    [[ $new == "$old" ]] || setenv LEOMAN_TLS_SANS "$new"
    say "The HTTPS certificate covers: localhost, 127.0.0.1, ::1${new:+, ${new//,/, }}"
    if ! tls_on; then
      say "HTTPS is off for this installation, so there is no certificate to renew yet. The names are used as soon as"
      say "you switch HTTPS on:  $self --https"
      exit 0
    fi
    before=$(tls_info | sed -n 's/^fp=//p')
    say "Renewing the certificate ..."
    docker compose run --rm --no-deps tls-init >/dev/null || die "tls-init failed (docker compose logs tls-init)"
    if [[ -n $(docker compose ps -q tls 2>/dev/null) ]]; then
      # the renewal service picks up the new names too (else its next check would go back to the old ones)
      docker compose up -d --no-deps tls-renew >/dev/null 2>&1 || say "NOTE: could not restart tls-renew; run: docker compose up -d"
      # a graceful reload keeps open connections; the front would also notice the new files within a minute
      if docker compose exec -T tls nginx -s reload -c /etc/leoman/nginx.conf >/dev/null 2>&1; then
        say "The HTTPS front now serves the renewed certificate (reloaded, no restart)."
      else
        docker compose restart tls >/dev/null || die "could not restart the HTTPS front (docker compose restart tls)"
        say "Restarted the HTTPS front: it now serves the renewed certificate."
      fi
    else
      say "LeoMan is not running; start it with:  cd $dir && docker compose up -d"
    fi
    after=$(tls_info | sed -n 's/^fp=//p')
    if [[ -z $after ]]; then
      tdir=$(envval LEOMAN_TLS_DIR); tdir=${tdir:-./tls}
      say "NOTE: this installation uses your own certificate (cert.pem in $tdir), not LeoMan's certificate authority."
      say "      Add the name to that certificate instead (whoever issued it can do that)."
    elif [[ -n $before && $before != "$after" ]]; then
      say "WARNING: the certificate authority changed (it was $before)."
      say "         Machines added before must get a new command: Machines -> the machine -> Get a new command."
    else
      say "The certificate authority is unchanged, so machines and browsers that trust it keep working."
    fi
  fi
  info=$(tls_info)
  fp=$(sed -n 's/^fp=//p' <<<"$info"); sans=$(sed -n 's/^sans=//p' <<<"$info"); until=$(sed -n 's/^until=//p' <<<"$info")
  if ! tls_on; then
    say "HTTPS is off for this installation (plain HTTP). Switch it on with:  $self --https"
  elif [[ -z $sans && -z $fp ]]; then
    say "No certificate yet: start LeoMan once (cd $dir && docker compose up -d), then run this again."
  else
    [[ -z $sans ]] || say "The certificate covers: ${sans//,/, }${until:+ (valid until $until)}"
    if [[ -n $fp ]]; then
      say "LeoMan's certificate authority: https://<this server>:$(envval LEOMAN_PORT | grep . || echo 6969)/leoman-ca.crt"
      say "  SHA-256 fingerprint: $fp"
      say "  Compare it with the fingerprint your device shows before you trust the certificate."
    fi
  fi
  exit 0
fi

# ---------------------------------------------------------------------------------------------- offline bundle
# §18 air-gapped: verify the bundle (SHA256SUMS, signature when cosign is here) and load its images. No network.
bundle_tmp=""
trap '[[ -z "$bundle_tmp" ]] || rm -rf "$bundle_tmp"' EXIT
if [[ -n "$offline" ]]; then
  if [[ -d "$offline" ]]; then
    bdir=$offline
  else
    [[ -f "$offline" ]] || die "--offline: $offline not found"
    bundle_tmp=$(mktemp -d "${TMPDIR:-/tmp}/leoman-offline.XXXXXX")
    say "Unpacking $offline ..."
    tar -xzf "$offline" -C "$bundle_tmp" || die "--offline: cannot unpack $offline"
    bdir=$(find "$bundle_tmp" -mindepth 1 -maxdepth 1 -type d -name 'leoman-*-offline-*' | head -1)
    [[ -n "$bdir" ]] || die "--offline: $offline is not a LeoMan offline bundle"
  fi
  for f in SHA256SUMS bundle.env images.tar images.txt; do
    [[ -f "$bdir/$f" ]] || die "--offline: $bdir/$f is missing"
    [[ $f = SHA256SUMS ]] || grep -Eq "^[0-9a-f]{64}  $f\$" "$bdir/SHA256SUMS" || die "--offline: $f is not covered by SHA256SUMS"
  done
  say "Checking the bundle's checksums ..."
  (cd "$bdir" && sha256sum --quiet -c SHA256SUMS) || die "the bundle is damaged or was modified (SHA256SUMS does not match) - do not use it"
  if [[ -f "$bdir/SHA256SUMS.sig" ]]; then
    if command -v cosign >/dev/null && declare -F payload_cosign_pub >/dev/null; then
      pub=$(mktemp); payload_cosign_pub > "$pub"
      cosign verify-blob --key "$pub" --signature "$bdir/SHA256SUMS.sig" --insecure-ignore-tlog=true \
        "$bdir/SHA256SUMS" >/dev/null 2>&1 || { rm -f "$pub"; die "the bundle's signature does not verify with LeoMan's key - do not use it"; }
      rm -f "$pub"
      say "Verified the bundle's signature (cosign, embedded key)"
    else
      say "NOTE: the bundle is signed, but cosign (or the embedded key) is not available here: signature not checked"
    fi
  else
    say "WARNING: this bundle is not signed (built with --no-sign); only its checksums were checked"
  fi
  bval() { grep "^$1=" "$bdir/bundle.env" | tail -1 | cut -d= -f2- || true; }
  bundle_version=$(bval LEOMAN_BUNDLE_VERSION); bundle_registry=$(bval LEOMAN_BUNDLE_REGISTRY); bundle_arch=$(bval LEOMAN_BUNDLE_ARCH)
  [[ $bundle_version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || die "--offline: bad version in bundle.env"
  [[ $bundle_registry =~ ^[A-Za-z0-9._/:-]+$ ]] || die "--offline: bad registry in bundle.env"
  case "$(uname -m)" in x86_64|amd64) host_arch=amd64 ;; aarch64|arm64) host_arch=arm64 ;; *) host_arch=$(uname -m) ;; esac
  [[ "$bundle_arch" = "$host_arch" ]] || die "--offline: the bundle is for $bundle_arch, this host is $host_arch"
  say "Loading the images (LeoMan $bundle_version, $bundle_arch) ..."
  docker load -q -i "$bdir/images.tar" >/dev/null || die "docker load failed"
  while read -r ref; do
    [[ -z "$ref" ]] || docker image inspect "$ref" >/dev/null 2>&1 || die "--offline: $ref missing after docker load"
  done < "$bdir/images.txt"
  # Machines -> Add a machine runs <registry>/leoman-worker:<the hub's version> (loaded above); :latest too, for
  # commands copied from a development build
  docker tag "$bundle_registry/leoman-worker:$bundle_version" "$bundle_registry/leoman-worker:latest"
  say "Loaded: $(tr '\n' ' ' < "$bdir/images.txt")"
  if [[ $load_only = 1 ]]; then
    say "Done (--load-only). This machine can now run a LeoMan worker ($bundle_registry/leoman-worker:$bundle_version):"
    say "in LeoMan open Machines -> Add a machine (or Update for a machine that is already there) and run the command."
    exit 0
  fi
  version=$bundle_version
  registry=$bundle_registry
fi
docker compose version >/dev/null 2>&1 || die "the Docker Compose v2 plugin is missing ('docker compose version' fails)"
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
  elif [[ -n "$offline" ]]; then
    die "--offline: $1 is not part of this installer (use the install.sh from the bundle)"
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
fresh=1; [[ ! -f .env ]] || fresh=0

# A new .env next to an earlier install's database volume would lock the hub out (Postgres keeps the password it was
# created with) and the user sees "502 Bad Gateway". Archive that old data into the backup folder and start clean.
stale_data_aside() {
  local proj=${COMPOSE_PROJECT_NAME:-leoman} vols=() v running stamp out img
  docker volume inspect "${proj}_pgdata" >/dev/null 2>&1 || return 0
  for v in pgdata redisdata; do docker volume inspect "${proj}_$v" >/dev/null 2>&1 && vols+=("${proj}_$v"); done
  running=$(docker ps -q --filter "label=com.docker.compose.project=$proj")
  if [[ -n $running ]]; then
    cat >&2 <<EOF
install.sh: an earlier LeoMan ("$proj") is still running on this host, but $dir/.env is missing.
  If you still have its folder, run the installer with --dir <that folder> to update it instead.
  To replace it with a new install, stop it first, then run the installer again:
    docker stop \$(docker ps -q --filter label=com.docker.compose.project=$proj)
  (Its data is kept: the installer saves it to $backup before starting fresh.)
EOF
    exit 2
  fi
  stamp=$(date -u +%Y%m%d-%H%M%S)
  out="$backup/earlier-install-$stamp"
  (umask 077 && mkdir -p "$out")
  img=postgres:16-alpine
  docker image inspect "$img" >/dev/null 2>&1 || docker pull -q "$img" >/dev/null 2>&1 || img=redis:7-alpine
  say "Found data from an earlier LeoMan install (${vols[*]}) without its .env: saving it to $out"
  for v in "${vols[@]}"; do
    docker run --rm --network none -v "$v":/data:ro -v "$out":/out "$img" sh -c \
      "tar -czf /out/$v.tar.gz -C /data . && chown $(id -u):$(id -g) /out/$v.tar.gz" || die "could not save volume $v to $out (nothing was removed)"
  done
  docker ps -aq --filter "label=com.docker.compose.project=$proj" | xargs -r docker rm >/dev/null
  docker volume rm "${vols[@]}" >/dev/null || die "could not remove the old volumes ${vols[*]} (saved in $out)"
  say "       Saved and removed. To go back to it later: restore those archives into the volumes and its old .env."
}
[[ $fresh = 0 || $load_only = 1 ]] || stale_data_aside
# HTTPS: asked for (--https), or the default of a new install that other computers reach (--expose) and of a new
# offline install; --http opts out. An existing install keeps what it has (HTTPS: its certificate names are refreshed).
want_https=0
if [[ $https_opt = on ]]; then want_https=1
elif [[ $https_opt = off ]]; then want_https=0
elif [[ $fresh = 1 && ( -n $offline || $bind = 0.0.0.0 ) ]]; then want_https=1
elif [[ $fresh = 0 ]] && tls_on; then want_https=1
fi
[[ $want_https = 0 ]] || tls_file=1
fetch deploy/compose.release.yml docker-compose.yml
say "Wrote $dir/docker-compose.yml"
# a copy of this installer for later (--tls-add-name, re-runs); not when piped from curl (nothing to copy)
if [[ -n "$src_self" && "$src_self" != "$(pwd -P)/install.sh" ]]; then
  cp "$src_self" install.sh.tmp && chmod 755 install.sh.tmp && mv install.sh.tmp install.sh
fi
if [[ "$tls_file" = 1 ]]; then
  fetch deploy/compose.release.tls.yml compose.release.tls.yml
  say "Wrote $dir/compose.release.tls.yml (the HTTPS front; see the file's header)"
fi

if [[ $fresh = 0 ]]; then
  say "Keeping the existing $dir/.env (secrets unchanged)."
  grep -q '^LEOMAN_BACKUP_DIR=' .env || echo "LEOMAN_BACKUP_DIR=$backup" >> .env
  grep -q '^HOST_HOME=' .env || echo "HOST_HOME=$HOME" >> .env
  grep -q '^LEOMAN_INSTALL_DIR=' .env || echo "LEOMAN_INSTALL_DIR=$(pwd -P)" >> .env
  if [[ -n "$offline" ]]; then  # only the bundle's images exist here: pin them
    setenv LEOMAN_VERSION "$version"
    setenv LEOMAN_REGISTRY "$registry"
    say "Set LEOMAN_VERSION=$version and LEOMAN_REGISTRY=$registry in .env (the loaded bundle)"
  else
    if [[ -n $version && $(envval LEOMAN_VERSION) != "$version" ]]; then
      setenv LEOMAN_VERSION "$version"
      say "Set LEOMAN_VERSION=$version in .env (then: docker compose pull && docker compose up -d)"
    fi
    if [[ -n $registry && $(envval LEOMAN_REGISTRY) != "$registry" ]]; then
      setenv LEOMAN_REGISTRY "$registry"
      say "Set LEOMAN_REGISTRY=$registry in .env"
    fi
  fi
  [[ $https_opt != off ]] || ! tls_on || say "NOTE: HTTPS stays on for this existing installation. To switch it off, remove ':compose.release.tls.yml' from COMPOSE_FILE in .env and run: docker compose up -d --remove-orphans"
  ADMIN_PW=""
else
  ADMIN_PW=$(rnd 20)
  (umask 077 && cat > .env <<ENV
# LeoMan release install, generated by install.sh. Every setting: .env.example in the LeoMan repository.
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

# §18 / §27 air-gapped: Settings -> About shows the offline update steps; no registry to ask for updates
if [[ -n $offline ]]; then
  setenv LEOMAN_OFFLINE 1
  [[ -n $(envval LEOMAN_UPDATE_CHECK) ]] || { setenv LEOMAN_UPDATE_CHECK 0; say "Set LEOMAN_UPDATE_CHECK=0 (no internet: nothing to check)"; }
elif [[ $(envval LEOMAN_OFFLINE) = 1 ]]; then
  setenv LEOMAN_OFFLINE 0
  say "This installation now updates online (LEOMAN_OFFLINE=0). LEOMAN_UPDATE_CHECK stays as it is ($(envval LEOMAN_UPDATE_CHECK))."
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
(umask 077 && mkdir -p "$h/.codex" "$h/.gemini")  # Codex / Gemini CLI homes, bind-mounted into the worker
[[ -e "$h/.claude.json" ]] || (umask 077 && printf '{}\n' > "$h/.claude.json")
say "Prepared $bk (backups), $ws (agent folders) and the Claude Code / Codex / Gemini paths under $h"

# §18 HTTPS front with LeoMan's private CA; machines must connect encrypted
if [[ $want_https = 1 ]]; then
  cf=$(envval COMPOSE_FILE)
  if [[ -z $cf ]]; then
    cf=docker-compose.yml
    [[ ! -f docker-compose.override.yml ]] || cf="$cf:docker-compose.override.yml"
    setenv COMPOSE_FILE "$cf:compose.release.tls.yml"
    say "HTTPS: switched on the HTTPS front (COMPOSE_FILE in .env)"
  elif [[ $cf != *compose.release.tls.yml* ]]; then
    setenv COMPOSE_FILE "$cf:compose.release.tls.yml"
    say "HTTPS: switched on the HTTPS front (COMPOSE_FILE in .env)"
  fi
  [[ -n $(envval LEOMAN_REQUIRE_TLS_NODES) ]] || setenv LEOMAN_REQUIRE_TLS_NODES 1
  old=$(envval LEOMAN_TLS_SANS)
  new=$(merge_sans "$old" "$(detect_sans)")
  [[ $new == "$old" ]] || setenv LEOMAN_TLS_SANS "$new"
  say "HTTPS: the certificate covers localhost, 127.0.0.1, ::1${new:+, ${new//,/, }}"
  say "       Another name or address later:  $self --tls-add-name <name or address>"
fi

# image signatures: the public key ships with the installer; verified here when cosign is installed
if [[ -n "$offline" ]] && declare -F payload_cosign_pub >/dev/null; then
  payload_cosign_pub > cosign.pub   # the registry signatures cannot be checked offline; the bundle's was (above)
elif declare -F payload_cosign_pub >/dev/null; then
  payload_cosign_pub > cosign.pub
  reg=$(envval LEOMAN_REGISTRY); reg=${reg:-docker.io/eyemnv}
  ver=$(envval LEOMAN_VERSION); ver=${ver:-latest}
  if command -v cosign >/dev/null; then
    for img in hub worker backup tls; do
      cosign verify --key cosign.pub "$reg/leoman-$img:$ver" >/dev/null 2>&1 \
        || die "the signature of $reg/leoman-$img:$ver does not verify with $dir/cosign.pub - do not start it"
    done
    say "Verified the image signatures ($reg, $ver) with $dir/cosign.pub"
  else
    say "Image signatures: install cosign and run  cosign verify --key $dir/cosign.pub $reg/leoman-hub:$ver  (optional)"
  fi
fi

# ---------------------------------------------------------------------------------------------- next steps
port=$(envval LEOMAN_PORT); port=${port:-6969}
b=$(envval LEOMAN_BIND); b=${b:-127.0.0.1}
scheme=http; ! tls_on || scheme=https
if [[ "$b" = 0.0.0.0 ]]; then
  addr=$(IFS=,; for n in $(envval LEOMAN_TLS_SANS); do printf '%s\n' "$n"; done | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -1 || true)
  [[ -n $addr ]] || addr=$(detect_sans | tr ',' '\n' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -1 || true)
  addr=${addr:-<this server>}
else
  addr=$b
fi
url="$scheme://$addr:$port"
if [[ -n "$offline" ]]; then
  cat <<EOF

LeoMan $version is loaded and ready to start (offline: nothing is downloaded). Next steps:
  1. Claude Code must already be installed on this host (as $(id -un)) and set up for your network's model gateway:
     LeoMan does not include a model. In an air-gapped network point Claude Code at an internal endpoint (for
     example ANTHROPIC_BASE_URL, or a private Bedrock / Vertex endpoint) in $h/.claude/settings.json.
  2. Start it:
       cd $dir && docker compose up -d
EOF
  start_step=3
else
  cat <<EOF

LeoMan is ready to start. Next steps:
  1. Install Claude Code on this host (as $(id -un)) and run \`claude\` once to sign in.
     LeoMan does not include the Claude Code CLI; its worker uses this host's signed-in copy
     ($h/.local/bin/claude and $h/.claude).$( [[ -x "$h/.local/bin/claude" ]] && printf ' (found: ok)' )
  2. Optional: list private folders/files agents must never touch in $dir/.env (LEOMAN_PROTECTED_PATHS).
  3. Start it:
       cd $dir && docker compose pull && docker compose up -d
EOF
  start_step=4
fi
cat <<EOF
  $start_step. Open $url and sign in as admin$( [[ -n "$ADMIN_PW" ]] && printf ' / %s' "$ADMIN_PW" ).
     Change the password after the first login (it is also in $dir/.env).
EOF
if [[ $scheme = https ]]; then
  cat <<EOF
     Your browser warns about the certificate until you trust LeoMan's own certificate authority. Do this once
     on each computer or phone: open $url/leoman-ca.crt, save the file and add it to the trusted
     certificates (Windows: double-click it, Install Certificate, "Trusted Root Certification Authorities";
     Mac: Keychain Access, System, then "Always Trust"). To see its fingerprint, run:  $self --ca-info
     The server certificate renews itself before it expires; the certificate authority stays the same.
EOF
fi
[[ -z $offline ]] || cat <<EOF
  $((start_step + 1)). Other machines: copy the bundle there and run  install.sh --offline <bundle> --load-only , then use
     Machines -> Add a machine (over HTTPS the command checks LeoMan's certificate by its fingerprint).
EOF
[[ -n $offline ]] || say "  Agents work only inside $ws (more folders: WORKSPACE_ROOT_2..4 in .env)."
if [[ "$b" != 0.0.0.0 ]]; then
  say "  Only this computer can open LeoMan now (LEOMAN_BIND=$b). For other computers: set LEOMAN_BIND=0.0.0.0 in .env,"
  [[ $scheme = https ]] && say "  then run docker compose up -d." || say "  run  $self --https  and then docker compose up -d."
elif [[ $scheme = http ]]; then
  say "  WARNING: other computers reach LeoMan over plain HTTP, which is not encrypted. Switch to HTTPS with:"
  say "    $self --https   (then: cd $dir && docker compose up -d)"
fi

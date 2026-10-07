<p align="center">
  <a href="https://leoman.eyemnv.com">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://leoman.eyemnv.com/assets/leoman-logo-dark.svg">
      <img src="https://leoman.eyemnv.com/assets/leoman-logo-light.svg" alt="LeoMan" height="72">
    </picture>
  </a>
</p>

# LeoMan

**Sessions that survive the shutdown.**

LeoMan runs AI coding agents such as Claude Code (with Codex and Gemini in experimental mode) on your own Linux server, behind a simple web page. Close the tab,
lose your Wi-Fi or VPN, shut your laptop: the agents keep working, and when you come back everything is still there.

- **Agents that keep running.** Tasks live on the server, not in your terminal.
- **You stay in control.** Agents ask before risky actions. You approve in the browser, and a main agent can handle
  routine questions from its helper agents.
- **Safe by default.** Agents only see the folders you allow. They can never read your private files, change LeoMan
  itself, or reveal its internals.
- **Ready-made skills.** 100+ built-in skills (coding, DevOps, security, writing, data) that you switch on per agent.
- **Teams, schedules, backups.** Several users, scheduled tasks, and automatic daily database backups.

LeoMan is free to use, for personal and commercial purposes, on machines you control (see [LICENSE](LICENSE)).

**Website and guides:** https://leoman.eyemnv.com

## What you need

- A Linux server or PC (x86-64 or ARM64) with **Docker** and the **Docker Compose v2** plugin.
- A regular (non-root) user that may use Docker (member of the `docker` group).
- An **AI coding CLI** installed for that user and signed in once, with your own account. LeoMan does not include one:
  - **Claude Code (recommended):** every LeoMan safety feature works with it (folder sandbox, approvals in the browser,
    protected files, self-protection).
  - **OpenAI Codex or Google Gemini CLI (experimental):** an admin can switch them on for their own agents, but they run
    without LeoMan's safety checks for now. Full support with the same safety is planned.

## Install

Run this as the regular user (not root):

```bash
curl -fsSL https://leoman.eyemnv.com/install.sh | bash
```

(The same installer is also at `https://raw.githubusercontent.com/eyemnv/leoman-release/main/install.sh`.)

The installer creates `~/leoman` with the settings file (`.env`, random passwords) and prints the next steps and
your first admin password. Then:

```bash
cd ~/leoman && docker compose pull && docker compose up -d
```

Open **http://127.0.0.1:6969** and sign in as `admin`. You will be asked to choose your own password.

Useful options (`bash -s -- <options>` after the `curl … |`):

| Option | What it does |
|---|---|
| `--expose` | Make the web page reachable from other computers (default: this machine only) |
| `--version 1.0.0` | Pin a version instead of `latest` |
| `--dir /srv/leoman` | Install somewhere other than `~/leoman` |
| `--workspace /srv/projects` | The folder agents may work in (default `~/leoman-workspaces`) |
| `--backup-dir /srv/leoman-backups` | Where daily database backups go (default `~/leoman-backups`) |

**HTTPS on your network:** add `COMPOSE_FILE=docker-compose.yml:compose.release.tls.yml` and `LEOMAN_BIND=0.0.0.0` to
`~/leoman/.env`, then run `docker compose up -d` again (see the top of `compose.release.tls.yml`).

## Update

```bash
cd ~/leoman && docker compose pull && docker compose up -d
```

Re-running the installer is safe: it keeps your `.env` and only refreshes the compose files.

## Check the images are genuine (optional)

The images are signed. The installer saves the public key as `~/leoman/cosign.pub` and, if
[cosign](https://docs.sigstore.dev/cosign/system_config/installation/) is installed, checks the signatures for you.
By hand:

```bash
cosign verify --key ~/leoman/cosign.pub docker.io/eyemnv/leoman-hub:latest
```

## Uninstall

```bash
cd ~/leoman && docker compose down        # add -v to also delete the database (all agents and history)
```

Your agent folders and backups stay where they are until you delete them.

## Licenses

LeoMan is proprietary freeware ([LICENSE](LICENSE)). The open-source components inside the images and their licenses
are listed in `/licenses` in each image, e.g.
`docker run --rm --entrypoint cat docker.io/eyemnv/leoman-hub:latest /licenses/THIRD_PARTY_NOTICES.md`.

LeoMan is not affiliated with or endorsed by Anthropic, OpenAI or Google. Claude, Codex and Gemini are trademarks of
their respective owners.

Questions: contact@eyemnv.com

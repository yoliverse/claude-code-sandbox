# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A self-contained Docker sandbox for running the Claude Code CLI with restricted network egress. There is no application code — the repository is the files that build and lock down the container image. It is built to run Claude Code unattended (e.g. in an autonomous "Ralph" loop) inside the locked-down container.

Layout:
- `Dockerfile` — builds the image (tooling, toolchains, global config, firewall).
- `docker/` — files baked into the image (consumed by the Dockerfile's `COPY`s):
  - `init-firewall.sh` — the egress allowlist enforced inside the running container.
  - `entrypoint.sh` — runs on container start; seeds the global CLAUDE.md into the config dir when missing, auto-runs the firewall (non-fatal; skip with `SANDBOX_SKIP_FIREWALL=1`), then `exec`s the requested command.
  - `claude-global.md` — Karpathy's coding-agent guidelines; baked in as the canonical `/usr/local/share/claude-global.md` and seeded into the config dir's `CLAUDE.md` at start by the entrypoint, so it applies to every project.
- `scripts/` — host-side helpers (NOT in the image):
  - `migrate-session.sh` — copies a local session transcript into a mounted workspace so it can be `claude --resume`d in the container (keys it to the container working dir).
- `.github/workflows/release.yml` — on a `vX.Y.Z` tag, builds the image (amd64+arm64 via buildx) and publishes it to GHCR (`ghcr.io/yoliverse/claude-code-sandbox`) using the built-in `GITHUB_TOKEN`, then cuts a GitHub Release. Also runnable via `workflow_dispatch`.

## Commands

```bash
# Build (tag is a date stamp; bump it when changing the image)
docker build . -t claude-code-sandbox:20260302

# Run interactively (single mount; config+sessions persist under /workspace/.claude)
docker run -it --rm --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -v ~/local-workspace:/workspace \
  claude-code-sandbox:20260302 bash

# The egress firewall runs automatically on start (needs NET_ADMIN/NET_RAW).
# To run it manually (e.g. after SANDBOX_SKIP_FIREWALL=1):
sudo /usr/local/bin/init-firewall.sh

# Python work inside the container
uv venv && source .venv/bin/activate
```

The container runs as the non-root `node` user. `init-firewall.sh` is the only command `node` may run as root without a password — this is wired up via `/etc/sudoers.d/node-firewall` in the Dockerfile, and the entrypoint invokes it via `sudo` on start. To apply iptables/ipset rules, the container must be started with the `NET_ADMIN`/`NET_RAW` capabilities (e.g. `--cap-add=NET_ADMIN --cap-add=NET_RAW`); without them the firewall step warns and the container runs with egress open.

## Architecture

Two pieces work together:

- **`Dockerfile`** — builds on `node:20`, installs dev tooling plus the networking utilities the firewall depends on (`iptables`, `ipset`, `iproute2`, `dnsutils`, `aggregate`, `jq`), installs `@anthropic-ai/claude-code` globally, and copies `docker/init-firewall.sh` to `/usr/local/bin`. It also provisions the developer toolchains: `uv` (Python, with a CPython pinned via the `PYTHON_VERSION` arg), corepack-managed `pnpm`/`yarn` and global `typescript`/`ts-node`/`tsx` (Node), and the global `claude-global.md`. Build args for pinning: `CLAUDE_CODE_VERSION`, `GIT_DELTA_VERSION`, `ZSH_IN_DOCKER_VERSION`, `PYTHON_VERSION`, `TZ`.

  Two non-obvious constraints to preserve when editing: everything after `USER node` runs unprivileged, so node-installed binaries must land in node-owned dirs — `corepack enable` is pointed at `/usr/local/share/npm-global/bin` (on `PATH`) rather than the root-owned `/usr/local/bin`, and `uv` installs to `~/.local/bin` (prepended to `PATH`). GitHub/git auth is deliberately NOT baked into the image (no secrets stored); `gh` is installed but the user authenticates manually at runtime — `gh auth login` (or `GH_TOKEN` + `gh auth setup-git`) plus their `git config` identity. See the README for the steps.

  Persistence model: the image sets `ENV CLAUDE_CONFIG_DIR=/workspace/.claude` (Claude Code's config-dir override), so *all* Claude state — `.claude.json`, `settings.json`, login, `projects/` transcripts — lives under `/workspace`. A single `-v ...:/workspace` mount therefore persists everything (config + code) across `--rm` containers. Intended layout: mount a workspace dir at `/workspace` and keep repos as subfolders, working from a subfolder so `/workspace/.claude` (user config) doesn't collide with a repo's own project-level `.claude/`. Never mount over all of `/home/node` — that would shadow the image-baked `uv`/Python (`~/.local`), zsh config, etc. Because a mount can shadow the baked CLAUDE.md, the canonical copy is kept at `/usr/local/share/claude-global.md` (unshadowable) and `entrypoint.sh` seeds `CLAUDE.md` into the active config dir (`${CLAUDE_CONFIG_DIR:-~/.claude}`) on start only when absent.

- **`docker/init-firewall.sh`** — enforces a default-deny egress policy. The flow is order-sensitive: it first captures and re-applies Docker's internal DNS (`127.0.0.11`) NAT rules *before* flushing everything, builds an `allowed-domains` ipset, then sets the default OUTPUT policy to DROP and only permits traffic to that set. The allowlist is GitHub's published IP ranges (fetched from `api.github.com/meta`) plus a hard-coded list of domains: the npm and yarn registries, PyPI (`pypi.org`, `files.pythonhosted.org`) for uv/pip, `api.anthropic.com` and `claude.ai` (the latter so interactive login works behind the firewall), Sentry, Statsig, and the VS Code endpoints. The script self-verifies at the end — it must *fail* to reach `example.com` and *succeed* in reaching `api.github.com`, exiting non-zero otherwise.

## When editing the firewall

- New outbound destinations Claude Code needs must be added to the domain loop (or the GitHub-meta fetch) — anything not in `allowed-domains` is rejected.
- Preserve the ordering: DNS capture before flush, ipset populated before the DROP policy, established-connection rule before the allowlist match. Reordering silently breaks connectivity or DNS.
- Keep the two verification curls at the end; they are the smoke test that the policy is actually closed.

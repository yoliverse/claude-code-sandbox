# claude-code-sandbox

A Docker image for running the [Claude Code](https://claude.com/claude-code) CLI
in an isolated, network-restricted container — built for running Claude Code
unattended (e.g. an autonomous "Ralph" loop) without handing it your whole
machine.

**What's inside:**

- **Default-deny firewall** — all egress is blocked except an allowlist (GitHub,
  npm/yarn, PyPI, the Anthropic API, …), so the agent can't reach arbitrary hosts.
- **Batteries-included toolchains** — Node (npm/pnpm/yarn/tsc) and Python (uv)
  preinstalled.
- **Single-mount persistence** — your code and all Claude state (login, settings,
  session history) live in one mounted `/workspace` directory, so they persist
  even if the container is removed.
- **Global guidelines** — a global `CLAUDE.md` (Karpathy's coding-agent rules) is
  seeded automatically.
- Runs as a **non-root** user; GitHub auth and secrets stay out of the image.

## Requirements

- Docker.
- The firewall runs automatically at startup and needs
  `--cap-add=NET_ADMIN --cap-add=NET_RAW` at `docker run` (it sets iptables/ipset
  rules). Without them the container still runs, but egress stays open and the
  startup output warns you.

## Quick start

```bash
# 1. Build (the tag is just a date stamp; bump it when you change the image)
docker build . -t claude-code-sandbox:20260302

# 2. Run — a named container, mounting ONE persistent workspace dir at /workspace
docker run -it --name claude-sandbox \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -v ~/local-workspace:/workspace \
  claude-code-sandbox:20260302 \
  bash
```

The container is kept after you exit (no `--rm`). To re-enter it later, restart
it instead of running again (a second `docker run --name` would fail with "name
already in use"):

```bash
docker start -ai claude-sandbox          # reattach
docker exec -it claude-sandbox bash      # open another shell in it
```

`CLAUDE_CONFIG_DIR` defaults to `/workspace/.claude`, so Claude's config, login,
and sessions live inside that mount automatically. The network is **locked down
automatically on startup** (see [Network lockdown](#network-lockdown)). Then do
the first-run setup below.

## First run (inside the container)

On the first run, set up auth. With a persistent `/workspace`, login and config
carry over — later runs need none of this.

### 1. Log in to Claude Code

Log in *inside the container* — on macOS your host credentials live in the
Keychain, which the Linux container can't read. There's no browser, so Claude
prints a URL: open it on your host, authorize, and paste the code back.

```bash
claude        # follow the prompt (or run /login in the TUI)
```

The auth host (`claude.ai`) is on the firewall allowlist, so login works even
with the network locked down — the browser step happens on your host. With a
persistent mount this is a **first-run-only** step.

> If login can't reach an auth host, either start the container once with
> `-e SANDBOX_SKIP_FIREWALL=1` to log in, or use the headless path: run
> `claude setup-token` on the host and start with
> `-e CLAUDE_CODE_OAUTH_TOKEN="<token>"`.

### 2. Set up GitHub & git

Not baked into the image (no secrets stored). Authenticate `gh` and let it
configure git's HTTPS credentials, then set your commit identity:

```bash
gh auth login                                  # interactive
# or: export GH_TOKEN=ghp_xxx && gh auth setup-git

git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
```

## Running Claude

```bash
claude
```

Because the container's egress is restricted to an allowlist, you can safely let
Claude run without permission prompts — the point of this sandbox, and ideal for
unattended / "Ralph" loops:

```bash
claude --dangerously-skip-permissions
```

This bypasses **all** tool-permission checks (file edits, command execution,
etc.). Only do it here, where the network is locked down — never on an
unsandboxed machine with open internet access.

## Network lockdown

The entrypoint runs the firewall (`init-firewall.sh`) automatically on every
start, applying a default-deny egress policy with a small allowlist: GitHub,
npm/yarn, PyPI, the Anthropic API + `claude.ai`, and a few telemetry/VS Code
hosts. Nothing else is reachable.

It requires the container to be started with `--cap-add=NET_ADMIN
--cap-add=NET_RAW`; without them the container still starts but **warns and runs
unlocked** (check the startup output). The full firewall log is at
`/tmp/init-firewall.log`.

- To allow a new outbound host, add it to the domain list in
  `docker/init-firewall.sh` and rebuild.
- To skip lockdown for a run, start with `-e SANDBOX_SKIP_FIREWALL=1`.

## How persistence works

The image sets `CLAUDE_CONFIG_DIR=/workspace/.claude`, where Claude Code keeps
*everything*: `.claude.json`, `settings.json`, login, `backups/`, and `projects/`
(session transcripts). Because that's under `/workspace`, a single
`-v ...:/workspace` mount persists it all — including your login — even across a
removed or recreated container.

On start, the entrypoint seeds a default `CLAUDE.md` into `/workspace/.claude` if
one isn't there (canonical copy: `/usr/local/share/claude-global.md`); an existing
one is never overwritten.

**Recommended layout — keep repos as subfolders and `cd` into them:**

```
~/local-workspace/        ->  /workspace
├── .claude/              ->  Claude config + sessions (auto-managed)
├── my-project/           ->  cd here, then run claude
└── another-project/
```

Working from a subfolder (cwd ≠ `/workspace`) keeps the user-level config dir
(`/workspace/.claude`) from colliding with a repo's own project-level `.claude/`.
To use a different location, set `-e CLAUDE_CONFIG_DIR=...` to another path you
also mount.

## Migrating an existing session

To continue a conversation you started on the host, copy its transcript into the
workspace with `scripts/migrate-session.sh` (run on the host):

```bash
# from the repo whose session you want to carry over:
./scripts/migrate-session.sh \
  --workspace <the same host dir you pass to -v ...:/workspace> \
  --dest-cwd /workspace/<subfolder-you-cd-into>
```

`--workspace` must be the **mount root** — the exact host dir from your
`-v <dir>:/workspace` (e.g. if you run `-v ~/Documents/Yoliverse:/workspace`, pass
`--workspace ~/Documents/Yoliverse`), **not** a project subfolder.

It defaults to the most recent session for the current directory; `--list` shows
ids, `--session <id>` picks one, `--source-dir` reads another project. `--dest-cwd`
must match where you'll run `claude` in the container (sessions are keyed by
working directory). Then, inside the container:

```bash
cd /workspace/<subfolder>
claude --resume            # pick it, or: claude --resume <session-id>
```

No `docker cp` needed — `/workspace` is your mounted host dir, and sessions live
under `/workspace/.claude/projects/`.

## Preinstalled toolchains

- **Python** — `uv` (default CPython pinned via the `PYTHON_VERSION` build arg);
  `uv venv && source .venv/bin/activate`.
- **Node** — `node`/`npm`/`npx`, plus `pnpm`/`yarn` (corepack) and
  `typescript`/`ts-node`/`tsx`.
- **Tools** — `git`, `gh`, `git-delta`, `fzf`, `jq`, `zsh` (default shell),
  `vim`/`nano`.

## Customizing the build

Override with `--build-arg`:

| Arg                     | Default  | Purpose                              |
| ----------------------- | -------- | ------------------------------------ |
| `CLAUDE_CODE_VERSION`   | `latest` | Pin the Claude Code CLI version      |
| `PYTHON_VERSION`        | `3.12`   | Default CPython installed via uv     |
| `GIT_DELTA_VERSION`     | `0.18.2` | git-delta version                    |
| `ZSH_IN_DOCKER_VERSION` | `1.2.0`  | zsh-in-docker version                |
| `TZ`                    | –        | Container timezone                   |

```bash
docker build . -t claude-code-sandbox:20260302 --build-arg CLAUDE_CODE_VERSION=2.1.152
```

## Releases

Tagged releases are built and published to the GitHub Container Registry by
[`.github/workflows/release.yml`](.github/workflows/release.yml). Push a semver
tag:

```bash
git tag v1.0.0
git push origin v1.0.0
```

This builds the image for `linux/amd64` and `linux/arm64`, pushes it to
`ghcr.io/yoliverse/claude-code-sandbox` (tags `1.0.0`, `1.0`, `1`, and `latest`),
and creates a GitHub Release with auto-generated notes. You can also run the
workflow manually from the **Actions** tab. Then pull it:

```bash
docker pull ghcr.io/yoliverse/claude-code-sandbox:latest
```

The package inherits the repo's visibility (currently private), so run
`docker login ghcr.io` first. No registry secrets are needed in CI — the workflow
authenticates with the built-in `GITHUB_TOKEN`.

## Notes & caveats

- **Don't run as root.** The image runs as the unprivileged `node` user; don't add
  `--user root`. Only `init-firewall.sh` needs root, and `node` may run just that
  via `sudo`.
- **The firewall runs automatically** on every start; it needs
  `--cap-add=NET_ADMIN --cap-add=NET_RAW` or it warns and leaves egress open.
  To allow a new outbound host, add it to `docker/init-firewall.sh` and rebuild;
  to skip for a run, set `-e SANDBOX_SKIP_FIREWALL=1`.
- **Keep secrets at runtime** — pass via `-e` (`ANTHROPIC_API_KEY`, `GH_TOKEN`, …)
  or interactive login; never in the Dockerfile or committed files.
- **Don't mount over all of `/home/node`** — a bind mount there wipes the baked-in
  `uv`/Python (`~/.local`) and zsh setup. Mount only `/workspace`. (Linux bind
  mounts have UID-mapping caveats; on macOS it just works.)
- **Reuse the named container** with `docker start -ai claude-sandbox` instead of
  re-running `docker run` (same `--name` twice errors). `docker rm claude-sandbox`
  to discard it — everything worth keeping lives in the `/workspace` mount anyway.

## Repository layout

```
.github/workflows/
└── release.yml             build + publish image to GHCR on a vX.Y.Z tag
Dockerfile                  image definition
docker/                     files baked into the image
├── entrypoint.sh             seeds the global CLAUDE.md, then runs your command
├── init-firewall.sh          egress allowlist (applied automatically on start)
└── claude-global.md          global coding-agent guidelines
scripts/
└── migrate-session.sh      host-side: copy a session into the workspace
```

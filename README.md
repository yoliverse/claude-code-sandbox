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
  session history) live in one mounted `/workspace` directory and survive `--rm`
  containers.
- **Global guidelines** — a global `CLAUDE.md` (Karpathy's coding-agent rules) is
  seeded automatically.
- Runs as a **non-root** user; GitHub auth and secrets stay out of the image.

## Requirements

- Docker.
- The firewall needs `--cap-add=NET_ADMIN --cap-add=NET_RAW` at `docker run` (it
  sets iptables/ipset rules). Without them the container still runs, but
  `init-firewall.sh` will fail.

## Quick start

```bash
# 1. Build (the tag is just a date stamp; bump it when you change the image)
docker build . -t claude-code-sandbox:20260302

# 2. Run — mount ONE persistent workspace dir at /workspace
docker run -it --rm \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -v ~/local-workspace:/workspace \
  claude-code-sandbox:20260302 \
  bash
```

`CLAUDE_CONFIG_DIR` defaults to `/workspace/.claude`, so Claude's config, login,
and sessions live inside that mount automatically. Then follow **First run**.

## First run (inside the container)

Do these in order. With a persistent `/workspace`, login and config carry over —
on later runs you can skip straight to the firewall.

### 1. Log in to Claude Code

Log in *inside the container* — on macOS your host credentials live in the
Keychain, which the Linux container can't read. There's no browser, so Claude
prints a URL: open it on your host, authorize, and paste the code back.

```bash
claude        # follow the prompt (or run /login in the TUI)
```

Log in **before** the firewall — the OAuth flow reaches hosts outside the
allowlist. Afterwards normal use only needs `api.anthropic.com` (allowlisted).
With a persistent mount this is a **first-run-only** step.

> Headless alternative (no browser): run `claude setup-token` on the host, then
> start the container with `-e CLAUDE_CODE_OAUTH_TOKEN="<token>"`.

### 2. Lock down the network

```bash
sudo /usr/local/bin/init-firewall.sh
```

### 3. Set up GitHub & git

Not baked into the image (no secrets stored). Authenticate `gh` and let it
configure git's HTTPS credentials, then set your commit identity:

```bash
gh auth login                                  # interactive
# or: export GH_TOKEN=ghp_xxx && gh auth setup-git

git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
```

## How persistence works

The image sets `CLAUDE_CONFIG_DIR=/workspace/.claude`, where Claude Code keeps
*everything*: `.claude.json`, `settings.json`, login, `backups/`, and `projects/`
(session transcripts). Because that's under `/workspace`, a single
`-v ...:/workspace` mount persists it all across `--rm` containers — including
your login.

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
  --workspace ~/local-workspace \
  --dest-cwd /workspace/<subfolder-you-cd-into>
```

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

## Notes & caveats

- **Don't run as root.** The image runs as the unprivileged `node` user; don't add
  `--user root`. Only `init-firewall.sh` needs root, and `node` may run just that
  via `sudo`.
- **Apply the firewall every run** (it's runtime state, not baked in), after
  logging in. To allow a new outbound host, add it to `docker/init-firewall.sh`
  and rebuild.
- **Keep secrets at runtime** — pass via `-e` (`ANTHROPIC_API_KEY`, `GH_TOKEN`, …)
  or interactive login; never in the Dockerfile or committed files.
- **Don't mount over all of `/home/node`** — a bind mount there wipes the baked-in
  `uv`/Python (`~/.local`) and zsh setup. Mount only `/workspace`. (Linux bind
  mounts have UID-mapping caveats; on macOS it just works.)
- **`--rm` is safe** — everything worth keeping lives in the `/workspace` mount.

## Repository layout

```
Dockerfile                  image definition
docker/                     files baked into the image
├── entrypoint.sh             seeds the global CLAUDE.md, then runs your command
├── init-firewall.sh          egress allowlist (run inside the container)
└── claude-global.md          global coding-agent guidelines
scripts/
└── migrate-session.sh      host-side: copy a session into the workspace
```

# Build image

docker build . -t claude-code-sandbox:20260302

# Run image

Recommended run command — you only mount **one** thing: a persistent workspace
directory at `/workspace`. The image defaults `CLAUDE_CONFIG_DIR=/workspace/.claude`,
so Claude's config, login, and sessions live inside that mount and persist
automatically:

docker run -it --rm \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -v ~/local-workspace:/workspace \
  claude-code-sandbox:20260302 \
  bash

Then run the in-container steps below in order.

## Persisting config & sessions — how it works

The image sets `CLAUDE_CONFIG_DIR=/workspace/.claude`, which is where Claude Code
keeps *everything*: `.claude.json`, `settings.json`, login, `backups/`, and
`projects/` (your session transcripts). Because it lives under `/workspace`, the
single `-v ...:/workspace` mount persists all of it across `--rm` containers —
including your login, so you only sign in on the first run.

The entrypoint seeds a default `CLAUDE.md` into `/workspace/.claude` on start when
one is missing, so a fresh mount still gets the global guidelines; an existing
CLAUDE.md is never overwritten. The canonical copy lives at
`/usr/local/share/claude-global.md`.

**Recommended layout — work from subfolders of `/workspace`:**

```
~/local-workspace/          ->  /workspace
  .claude/                  ->  Claude config + sessions (auto-managed)
  my-project/               ->  cd here and run claude
  another-project/
```

Keep your repos as *subfolders* and `cd` into them. Do not mount a single repo
directly at `/workspace` and run Claude from `/workspace` — then `/workspace/.claude`
(user config) collides with that repo's own project-level `.claude/`, and Claude's
`.claude.json` / transcripts get written into your repo root. To override the
location, set `-e CLAUDE_CONFIG_DIR=...` to any other path you also mount.

Do NOT mount over all of `/home/node`: a bind mount replaces the directory and
would wipe the image's baked-in `uv` + Python (`~/.local`) and the zsh setup.
(Linux bind mounts have UID-mapping caveats; on macOS it just works.)

## Migrating an existing session into the container

To continue a conversation you started on the host, copy its transcript into the
workspace dir you mount at `/workspace`, using `scripts/migrate-session.sh` (run
on the host):

# from the repo whose session you want to carry over:
./scripts/migrate-session.sh \
  --workspace ~/local-workspace \
  --dest-cwd /workspace/<subfolder-you'll-cd-into>

It defaults to the most recent session for the current directory; use `--list` to
see ids, `--session <id>` to pick one, and `--source-dir` to read a different
project. `--dest-cwd` must match where you'll run `claude` in the container,
because sessions are keyed by working directory. Then, inside the container:

cd /workspace/<subfolder>
claude --resume        # pick it, or: claude --resume <session-id>

Why this works without `docker cp`: `/workspace` is your mounted host dir, and the
container keeps sessions under `/workspace/.claude/projects/`, so writing the
transcript into the host folder is all it takes.

# Usage practices

- **Don't run as root.** The image already runs as the unprivileged `node` user.
  Do not add `--user root` or `docker exec -u root`; the only thing needing root
  is the firewall script, and `node` is allowed to run just that one via sudo.
- **Mount one persistent `/workspace`.** Bind-mount a host workspace dir to
  `/workspace` and keep repos as subfolders; `cd` into one to work. Both your
  code and Claude's config (`/workspace/.claude`) persist there, so cloning a repo
  inside `/workspace` is fine — it survives the container.
- **Apply the firewall every run, after logging in.** It is runtime state, not
  baked into the image. Run `sudo /usr/local/bin/init-firewall.sh` once you're
  logged in but before agent work; it needs `--cap-add=NET_ADMIN` (and
  `NET_RAW`) or it cannot set iptables rules. If you need a new outbound host,
  add it to `docker/init-firewall.sh` and rebuild.
- **Pass secrets at runtime, never bake them in.** API keys and tokens go through
  `-e` env vars (e.g. `-e ANTHROPIC_API_KEY=...`, `-e GH_TOKEN=...`) or
  interactive login — never in the Dockerfile or committed files.
- **Use `--rm` for throwaway containers** so stopped ones don't pile up; the
  `/workspace` mount holds everything that should outlive them — your code *and*
  Claude's config/login/sessions under `/workspace/.claude`.

# Run inside the image

Do these in order each run (with `--rm` the container is fresh every time).

## 1. Log in to Claude Code

Log in *inside the container*, not on the host — macOS stores Claude credentials
in the Keychain, which the Linux container can't read. The container has no
browser, so Claude prints a URL: open it in your host browser, authorize, and
paste the code back.

claude        # follow the login prompt (or run /login inside the TUI)

With a persistent `/workspace` mount this is a **first-run-only** step — your
login is saved under `/workspace/.claude` and reused on later runs.

Log in BEFORE running the firewall — the OAuth flow reaches hosts outside the
allowlist. After login, normal use only needs `api.anthropic.com` (allowlisted).

Headless alternative (no browser step): on the host run `claude setup-token`,
then start the container with `-e CLAUDE_CODE_OAUTH_TOKEN="<token>"`.

## 2. Lock down egress

sudo /usr/local/bin/init-firewall.sh

## 3. GitHub & git setup

Not baked into the image — no secrets are stored in it. Authenticate `gh`, then
let it configure git's HTTPS credentials. Either log in interactively:

gh auth login

or pass a token and wire it into git:

export GH_TOKEN="ghp_xxx"   # or run: gh auth login
gh auth setup-git

Set your commit identity (auth doesn't set the commit author):

git config --global user.email "you@example.com"
git config --global user.name "Your Name"

## Preinstalled toolchains

- Python: `uv` (default CPython pinned via the `PYTHON_VERSION` build arg)
  - `uv venv && source .venv/bin/activate`
- Node: `node`/`npm`/`npx` plus `pnpm`/`yarn` (via corepack) and `typescript`/`ts-node`/`tsx`
- Global coding-agent guidelines seeded to `/workspace/.claude/CLAUDE.md`, applied to every project

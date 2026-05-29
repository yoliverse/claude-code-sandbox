FROM node:20

ARG TZ
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=latest

# Install basic development tools and iptables/ipset
RUN apt-get update && apt-get install -y --no-install-recommends \
  less \
  git \
  procps \
  sudo \
  fzf \
  zsh \
  man-db \
  unzip \
  gnupg2 \
  gh \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  iputils-ping \
  telnet \
  traceroute \
  netcat-openbsd \
  net-tools \
  lsof \
  jq \
  nano \
  vim \
  curl \
  ca-certificates \
  python3-venv \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Ensure default node user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R node:node /usr/local/share

ARG USERNAME=node

# Persist bash history.
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  && mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory

# Set `DEVCONTAINER` environment variable to help with orientation
ENV DEVCONTAINER=true

# Create workspace and config directories and set permissions
RUN mkdir -p /workspace /home/node/.claude && \
  chown -R node:node /workspace /home/node/.claude

WORKDIR /workspace

ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  sudo dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Set up non-root user
USER node

# Install global packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=/home/node/.local/bin:$PATH:/usr/local/share/npm-global/bin

# Set the default shell to zsh rather than sh
ENV SHELL=/bin/zsh

# Set the default editor and visual
ENV EDITOR=nano
ENV VISUAL=nano

# Keep Claude Code's config dir under the mounted /workspace so config, login,
# and session transcripts persist with a single `-v ...:/workspace` mount. The
# entrypoint seeds CLAUDE.md here on start. Work from repo subfolders of
# /workspace (not /workspace itself) so this user-config dir doesn't collide
# with a repo's own project-level .claude/.
ENV CLAUDE_CONFIG_DIR=/workspace/.claude

# Default powerline10k theme
ARG ZSH_IN_DOCKER_VERSION=1.2.0
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -x

# Install Claude
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} && \
  npm cache clean --force

# Install GitNexus (code-intelligence / knowledge-graph CLI + MCP server)
ARG GITNEXUS_VERSION=latest
RUN npm install -g gitnexus@${GITNEXUS_VERSION} && \
  npm cache clean --force

# Node toolchain: enable corepack (pnpm/yarn) and install global TypeScript tools.
# Shims go into the node-owned npm-global bin (on PATH), not the root-owned /usr/local/bin.
RUN mkdir -p /usr/local/share/npm-global/bin && \
  corepack enable --install-directory /usr/local/share/npm-global/bin && \
  corepack prepare pnpm@latest yarn@stable --activate && \
  npm install -g typescript ts-node tsx

# Python toolchain: install uv and pin a default CPython
ARG PYTHON_VERSION=3.12
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
  uv python install ${PYTHON_VERSION}

# Global CLAUDE.md (Karpathy's coding-agent guidelines). Keep the canonical copy
# in /usr/local/share where a mounted config dir cannot shadow it; the entrypoint
# seeds it into the config dir on start when that file is missing.
COPY docker/claude-global.md /usr/local/share/claude-global.md

# Copy firewall script and the entrypoint that seeds the global CLAUDE.md
COPY docker/init-firewall.sh /usr/local/bin/
COPY docker/entrypoint.sh /usr/local/bin/
USER root
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh && \
  echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node-firewall && \
  chmod 0440 /etc/sudoers.d/node-firewall
USER node

# Seed the global CLAUDE.md (if missing) before running the requested command
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]


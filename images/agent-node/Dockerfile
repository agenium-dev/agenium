# The standard agent node: the agent CLIs, the capability CLIs, the supervisor
# and the boot path. No agent and no secret is here, and no build is made per
# agent: the agent is raised at boot from the store by CAPABILITIES_PROJECT_ID,
# and until the box is told which agent and which store it waits idle.
FROM debian:bookworm-slim

LABEL org.opencontainers.image.source="https://github.com/agenium-dev/agenium"
LABEL org.opencontainers.image.description="The standard Agenium agent node: agent CLIs, capability CLIs and the boot path, with no agent and no secret inside."

# bubblewrap and socat are what Claude Code's and Codex's sandboxes need on Linux.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git openssh-client ripgrep file ffmpeg python3 procps supervisor sudo \
        bubblewrap socat \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI, from GitHub's own apt repository. Its login is made on the node
# and kept on the config volume (~/.config/gh); git reaches github.com over
# https through it, set system-wide so the helper outlives a new tag.
RUN set -eux; \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh; \
    rm -rf /var/lib/apt/lists/*; \
    git config --system credential.https://github.com.helper '!gh auth git-credential'

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

ARG USERNAME=agent
RUN useradd --create-home --home-dir /home/agent --shell /bin/bash ${USERNAME}

USER ${USERNAME}
ENV HOME=/home/agent
ENV XDG_STATE_HOME=/home/agent/.local/state
ENV PATH=/home/agent/.local/bin:${PATH}
WORKDIR /app

RUN mkdir -p "$HOME/.local/bin" "$HOME/.local/state" "$HOME/.claude" "$HOME/.codex"

# Claude Code CLI. Its login is made on the node, never baked in. The state it
# keeps in ~/.claude.json lives on the ~/.claude volume, through a link the
# entrypoint keeps (keep-claude-config); what the installer wrote there moves
# onto the volume now, so a fresh volume starts with it.
RUN curl -fsSL https://claude.ai/install.sh | bash \
 && if [ -f "$HOME/.claude.json" ] && [ ! -L "$HOME/.claude.json" ]; then mv "$HOME/.claude.json" "$HOME/.claude/.claude.json"; fi \
 && ln -sfn .claude/.claude.json "$HOME/.claude.json"

# OpenAI Codex CLI. The complete package includes the code-mode host and runtime
# resources required by current releases. Its login is made on the node.
ARG CODEX_REF=rust-v0.162.1
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) triple=x86_64-unknown-linux-musl ;; \
      arm64) triple=aarch64-unknown-linux-musl ;; \
      *) echo "unsupported arch $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    release_dir="$HOME/.local/share/codex/${CODEX_REF}"; \
    curl -fsSL "https://github.com/openai/codex/releases/download/${CODEX_REF}/codex-package-${triple}.tar.gz" -o /tmp/codex-package.tgz; \
    mkdir -p "$release_dir" "$HOME/.local/bin"; \
    tar -xzf /tmp/codex-package.tgz -C "$release_dir"; \
    chmod +x "$release_dir/bin/codex" "$release_dir/bin/codex-code-mode-host"; \
    ln -sf "$release_dir/bin/codex" "$HOME/.local/bin/codex"; \
    ln -sf "$release_dir/bin/codex-code-mode-host" "$HOME/.local/bin/codex-code-mode-host"; \
    test -x "$HOME/.local/bin/codex" && test -x "$HOME/.local/bin/codex-code-mode-host"; \
    rm -f /tmp/codex-package.tgz

RUN uv python install 3.13

USER root
RUN mkdir -p /opt/agent /app && chown ${USERNAME}:${USERNAME} /opt/agent /app \
 && ln -sf /home/agent/.local/bin/claude /usr/local/bin/claude \
 && ln -sf /home/agent/.local/bin/codex /usr/local/bin/codex
USER ${USERNAME}
COPY --chown=${USERNAME}:${USERNAME} entrypoint.sh healthcheck keep-claude-config /opt/agent/
RUN chmod +x /opt/agent/entrypoint.sh /opt/agent/healthcheck /opt/agent/keep-claude-config

# The node stays the agent's: a docker exec lands as the agent. Its one root
# path is the helper that joins the group of the host's Docker socket at boot,
# kept where the agent cannot replace it and run by sudo with no argument.
USER root
COPY join-docker-socket /usr/local/sbin/agent-node-join-docker-socket
COPY sudoers /etc/sudoers.d/agent-node
RUN chown root:root /usr/local/sbin/agent-node-join-docker-socket /etc/sudoers.d/agent-node \
 && chmod 0755 /usr/local/sbin/agent-node-join-docker-socket \
 && chmod 0440 /etc/sudoers.d/agent-node \
 && visudo -cf /etc/sudoers.d/agent-node
USER ${USERNAME}

# Capability CLIs: every capability in the catalogue at CAPABILITIES_REF (a
# branch, tag, or SHA), installed by the manager. Whether one is usable is its
# gate's and its connections' answer, not whether it is installed. Each install
# also warms its PEP-723 environment, best-effort so missing credentials break
# no build.
ARG CAPABILITIES_REF=main
ENV CAPABILITIES_SOURCE=https://raw.githubusercontent.com/ai-cluster-one/capabilities/${CAPABILITIES_REF}
RUN curl -fsSL "${CAPABILITIES_SOURCE}/install.sh" \
      | CAPABILITIES_TAG=${CAPABILITIES_REF} sh \
 && names="$(curl -fsSL "${CAPABILITIES_SOURCE}/.capability-source/catalog.json" | python3 -c 'import json,sys; [print(n) for n in sorted(json.load(sys.stdin)["capabilities"])]')" \
 && test -n "$names" \
 && for name in $names; do \
      capabilities install "$name" --allow < /dev/null \
        || { echo "[build] could not install $name from the catalogue" >&2; exit 1; }; \
      "$name" help >/dev/null 2>&1 || true; \
    done || { echo "[build] capabilities readiness check failed" >&2; exit 1; }

# State the node keeps is mounted where the node's resource says. Each usual
# mount point is made here, as root and handed to the agent, so a fresh named
# volume inherits the agent's ownership.
USER root
RUN mkdir -p "$HOME/.local/state" "$HOME/.config" "$HOME/.claude" "$HOME/.codex" "$HOME/work" /app/capabilities \
 && chown ${USERNAME}:${USERNAME} "$HOME/.local/state" "$HOME/.config" "$HOME/.claude" "$HOME/.codex" "$HOME/work" /app/capabilities
USER ${USERNAME}

# Healthy while it waits for its agent and once the agent is up with its
# services under the supervisor; see the check for what it asks.
HEALTHCHECK --interval=30s --timeout=5s --start-period=2m --retries=3 \
  CMD /opt/agent/healthcheck

ENTRYPOINT ["/opt/agent/entrypoint.sh"]

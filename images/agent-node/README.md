# agent-node

The standard agent node image, `ghcr.io/agenium-dev/agent-node`, for linux/amd64 and linux/arm64. It holds the tools and the boot path of an agent node: Python and uv, git and the GitHub CLI (`gh`), Claude Code and Codex, the capabilities manager with the whole capability catalogue, the supervisor, and the entrypoint. It holds no agent and no secret, and no image is built per agent.

## Running it

Started with nothing, the node waits idle and healthy, and its log says what it is waiting for. It raises an agent once it has all three of these:

- `CAPABILITIES_PROJECT_ID`, the id of the agent the store holds;
- `AGENT_NODE_NAME`, this node's name among the agent's nodes;
- a store setting the capabilities manager resolves, either the `AGENTKIT_DB_*` keys in the environment or a store setting file written onto the node.

While it waits, it looks again every `AGENT_NODE_POLL_SECONDS` (30 by default), so a store setting written while it waits brings it up without a restart. Then it binds its root, `CAPABILITIES_PROJECT_ID_ROOT` (`/app` by default), to that agent and composes the agent's context from the store. It compiles the agent's services with `deployment` and runs them under the supervisor. Each service starts only where the agent's gate places it on this node. It does the same on every boot, a restart of the same container included, and reports itself unhealthy while it runs the agent without services it could not compile or once the supervisor no longer answers.

The Claude Code, Codex and GitHub CLI logins are made on the node, each with `docker exec -it <container>`: `claude login`, `codex login --device-auth` and `gh auth login`. The `gh` login also lets git reach github.com over https, through the credential helper the image sets. Keep `/home/agent/.claude`, `/home/agent/.codex`, `/home/agent/.config` and `/home/agent/.local/state` on volumes if they should outlive the container.

A node given the host's Docker socket at `/var/run/docker.sock` reaches it as the agent. At boot the entrypoint reads the socket's group id, which is the host's own, and puts the agent in a group with that id, through the one root helper the agent may run with `sudo`. Nothing in the image or in a Dockerfile built from it names that id, and nothing changes on the host. The node stays the agent's, so `docker exec` lands as the agent, already in that group.

## Releasing

A pull request or a push to `main` that changes the image builds it and checks it on a native runner of each architecture. A release is made by pushing the tag `agent-node/v<version>` on a commit whose `VERSION` matches it. The `agent-node.yml` workflow then publishes `ghcr.io/agenium-dev/agent-node:<version>` for both architectures, moves `:latest` to it, and writes the tag's release notes, which name any capability whose environment is not made on an architecture; such a capability does not hold the image back.

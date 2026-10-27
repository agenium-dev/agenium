#!/usr/bin/env bash
# The standard agent node's boot path. The image knows no agent: it waits idle
# until it is told which agent it runs (CAPABILITIES_PROJECT_ID) and a store to
# reach, then raises that agent from the store into its root
# (CAPABILITIES_PROJECT_ID_ROOT, /app by default) and runs the agent's services
# under the node's service manager. It runs as the node whose id is kept on its
# config volume, which enrolment writes there (`capabilities node id`);
# AGENT_NODE_NAME is only the label it is shown by.
set -euo pipefail

# What the box is doing, for its health check: healthy while it waits and once
# it runs, unhealthy once it runs its agent without the services it could not
# compile. The supervisor's configuration is named only once the supervisor is
# what runs, and the health check then also asks the supervisor. A box that
# cannot raise its agent exits instead. A restarted container keeps /tmp, so
# each boot starts both afresh. The image names the state file
# (AGENT_NODE_STATE_FILE), so the capabilities manager reports its line too.
STATE="${AGENT_NODE_STATE_FILE:-/tmp/agent-node.state}"
SUPERVISED=/tmp/agent-node.supervisor
node_state() { printf '%s\n' "$*" > "$STATE"; }
rm -f "$SUPERVISED"
node_state "booting"

# --- The host's Docker socket ------------------------------------------------
# A node given the host's /var/run/docker.sock reaches it through the socket's
# group, whose id is the host's. While the agent is not in it, the entrypoint
# saves its environment and arguments and hands over to the one root helper the
# agent may run, which puts the agent in that group and starts the entrypoint
# again as the agent. The image stays the agent's, so a docker exec still lands
# as the agent, and from then on in the socket's group too.
if [ -S /var/run/docker.sock ]; then
  socket_gid="$(stat -c %g /var/run/docker.sock)"
  case " $(id -G) " in
    *" $socket_gid "*)
      echo "[entrypoint] the host's Docker socket is reached through group $socket_gid"
      ;;
    *)
      if [ -z "${AGENT_NODE_DOCKER_SOCKET_JOINED:-}" ]; then
        (umask 077; { export -p; printf 'set --'; [ "$#" -eq 0 ] || printf ' %q' "$@"; printf '\n'; } > /tmp/agent-node.env)
        exec sudo -n /usr/local/sbin/agent-node-join-docker-socket
      fi
      echo "[entrypoint] WARN: the agent is not in group $socket_gid of the host's Docker socket, so it cannot reach Docker" >&2
      ;;
  esac
fi

# --- Claude Code's account state on its volume -------------------------------
# Claude Code keeps it in ~/.claude.json, outside the ~/.claude volume; it is
# kept on the volume through a link, so a redeploy does not lose it.
/opt/agent/keep-claude-config \
  || echo "[entrypoint] WARN: could not keep Claude Code's account state on the ~/.claude volume; a redeploy may ask for a sign-in again" >&2

if [ -n "${GIT_DEPLOY_KEY_B64:-}" ]; then
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  if printf '%s' "$GIT_DEPLOY_KEY_B64" | base64 -d > "$HOME/.ssh/id_ed25519" 2>/dev/null \
       && [ -s "$HOME/.ssh/id_ed25519" ]; then
    chmod 600 "$HOME/.ssh/id_ed25519"
    grep -q '^github.com ' "$HOME/.ssh/known_hosts" 2>/dev/null || \
      echo 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' >> "$HOME/.ssh/known_hosts"
    if [ -n "${AGENT_GIT_KNOWN_HOSTS_B64:-}" ]; then
      host_key="$(printf '%s' "$AGENT_GIT_KNOWN_HOSTS_B64" | base64 -d)"
      printf 'host.docker.internal %s\n' "$host_key" >> "$HOME/.ssh/known_hosts"
    fi
    git config --global user.name "agent"
    git config --global user.email "agent@local"
  else
    rm -f "$HOME/.ssh/id_ed25519"
    echo "[entrypoint] WARN: GIT_DEPLOY_KEY_B64 is set but not valid base64; git push identity skipped" >&2
  fi
fi

# --- The manager at the catalogue this image names ---------------------------
# Each boot brings the capabilities to the catalogue at CAPABILITIES_SOURCE, and
# what they compile may need a manager newer than the one this image was built
# with - the node's service manager, which runs the agent's services, is the
# manager's. So the manager is brought to the release that catalogue carries
# first.
if capabilities self-update --check < /dev/null 2>/dev/null \
     | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("update_available") else 1)'; then
  echo "[entrypoint] updating the capabilities manager to the release the catalogue this image names carries"
  if ! capabilities self-update < /dev/null > /dev/null; then
    echo "[entrypoint] WARN: could not update the capabilities manager; the node runs the manager it has" >&2
  fi
fi

# --- Catalogue capabilities at the catalogue this image names ----------------
# A node holds the whole catalogue at CAPABILITIES_SOURCE; whether a capability
# is usable is its gate's and its connections' answer. One the registry lacks is
# installed; one installed from another catalogue is installed again from this
# one; one already from this catalogue is updated only where the manager finds a
# different payload there. One installed from anywhere else is left as it is.
registry="${CAPABILITIES_HOME:-$HOME/.capabilities}"
if plan="$(curl -fsSL "${CAPABILITIES_SOURCE}/.capability-source/catalog.json" | python3 -c 'import json,os,sys
reg, base, ex = sys.argv[1], sys.argv[2], set(sys.argv[3:])
for n in sorted(json.load(sys.stdin)["capabilities"]):
    if n in ex: continue
    if not os.path.isfile(os.path.join(reg, n, n)): print("missing", n); continue
    try: meta = json.load(open(os.path.join(reg, n, "meta.json")))
    except (OSError, ValueError): continue
    src, rel = str(meta.get("source") or ""), "/capabilities/%s/bin/%s" % (n, n)
    if meta.get("source_id") or not src.startswith(("http://", "https://")) or not src.endswith(rel): continue
    print("recorded" if src == base + rel else "moved", n)
' "$registry" "${CAPABILITIES_SOURCE}")"; then
  recorded=""
  while read -r state name; do
    case "$state" in
      missing)
        echo "[entrypoint] installing $name: the catalogue carries it and this node's registry lacks it"
        if ! capabilities install "$name" --allow < /dev/null > /dev/null; then
          echo "[entrypoint] WARN: could not install $name; the box runs without it" >&2
        fi
        ;;
      moved)
        echo "[entrypoint] updating $name: it was installed from another catalogue than the one this image names"
        if ! capabilities install "$name" < /dev/null > /dev/null; then
          echo "[entrypoint] WARN: could not update $name; the box runs the payload it has" >&2
        fi
        ;;
      recorded) recorded="$recorded $name" ;;
    esac
  done <<< "$plan"
  if [ -n "$recorded" ]; then
    behind="$(capabilities update --check < /dev/null 2>/dev/null | python3 -c 'import json,sys; want=set(sys.argv[1:]); rows=json.load(sys.stdin).get("checked") or []; [print(r["name"]) for r in rows if r.get("name") in want and r.get("update_available")]' $recorded || true)"
    for name in $behind; do
      echo "[entrypoint] updating $name: the catalogue this image names carries a different payload"
      if ! capabilities update "$name" < /dev/null > /dev/null; then
        echo "[entrypoint] WARN: could not update $name; the box runs the payload it has" >&2
      fi
    done
  fi
else
  echo "[entrypoint] WARN: could not read the capability catalogue; the box runs with the capabilities it has" >&2
fi

# --- Waiting for its agent ---------------------------------------------------
# A node starts knowing nothing. Until it has an agent id and a store the
# manager resolves for its root - in the environment, or a store setting written
# onto the node later, after its node id - it waits here, healthy, and looks
# again every AGENT_NODE_POLL_SECONDS, so a setting written while it waits brings
# it up.
APP="${CAPABILITIES_PROJECT_ID_ROOT:-/app}"
mkdir -p "$APP"

missing() {
  local what=""
  [ -n "${CAPABILITIES_PROJECT_ID:-}" ] || what="$what CAPABILITIES_PROJECT_ID"
  if ! capabilities store show --project "$APP" < /dev/null 2>/dev/null \
       | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("configured") else 1)' 2>/dev/null; then
    what="$what store-setting"
  fi
  printf '%s' "${what# }"
}

said=""
while waiting="$(missing)"; [ -n "$waiting" ]; do
  if [ "$waiting" != "$said" ]; then
    echo "[entrypoint] idle: no agent to raise yet; waiting for: $waiting"
    said="$waiting"
  fi
  node_state "idle: waiting for $waiting"
  sleep "${AGENT_NODE_POLL_SECONDS:-30}"
done
node_state "raising agent $CAPABILITIES_PROJECT_ID"

# --- The agent, raised from the store by its id ------------------------------
# Nothing of the agent arrives from Git: the agent is the one the store holds
# under CAPABILITIES_PROJECT_ID. Its root starts empty and is bound to that
# agent here, on every boot, so the node runs what the store holds now.
cd "$APP"

# The manager composes context only for a folder bound to ContextKit. The binding
# carries nothing of the agent, so an empty one is laid where none is.
mkdir -p .contextkit
[ -f .contextkit/config.toml ] || : > .contextkit/config.toml

# The node's id: the one kept on its config volume.
if ! NODE_ID="$(capabilities node id < /dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"; then
  echo "[entrypoint] FATAL: this node resolves no node id; set it with capabilities node id --set <id>" >&2
  exit 1
fi
NODE="$NODE_ID${AGENT_NODE_NAME:+ ($AGENT_NODE_NAME)}"

# --- A node created before node ids -----------------------------------------
# Such a node is registered under its name, the AGENT_NODE_NAME it was created
# with. While the store still holds a node whose id is that name, it is this
# node, and it moves to its own id here, before the agent is bound - until then
# the store knows this node only by that name - and before any of its services
# starts. The rekey waits while a lease its previous container held has not yet
# run out.
if [ -n "${AGENT_NODE_NAME:-}" ] && [ "$AGENT_NODE_NAME" != "$NODE_ID" ] \
   && capabilities node list < /dev/null 2>/dev/null | python3 -c 'import json,sys; sys.exit(0 if any(n.get("node") == sys.argv[1] for n in json.load(sys.stdin).get("nodes") or []) else 1)' "$AGENT_NODE_NAME"; then
  node_state "moving node $AGENT_NODE_NAME to its id $NODE_ID"
  deadline=$(( $(date +%s) + ${AGENT_NODE_REKEY_SECONDS:-900} ))
  until out="$(capabilities node rekey "$AGENT_NODE_NAME" < /dev/null 2>&1)"; do
    if ! printf '%s' "$out" | grep -q node_services_running || [ "$(date +%s)" -ge "$deadline" ]; then
      echo "[entrypoint] FATAL: could not move node $AGENT_NODE_NAME to its id $NODE_ID:" >&2
      printf '%s\n' "$out" >&2
      exit 1
    fi
    echo "[entrypoint] waiting for the services node $AGENT_NODE_NAME ran to let go before moving it to its id"
    sleep 30
  done
  echo "[entrypoint] node $AGENT_NODE_NAME moved to its id $NODE_ID"
fi

if ! capabilities init --id "$CAPABILITIES_PROJECT_ID" < /dev/null > /dev/null; then
  echo "[entrypoint] FATAL: could not bind $APP to agent $CAPABILITIES_PROJECT_ID as node $NODE in the store this node reaches" >&2
  exit 1
fi
echo "[entrypoint] $APP bound to agent $CAPABILITIES_PROJECT_ID as node $NODE"

# --- Context, composed from the store ----------------------------------------
# The agent CLIs' session hooks rebuild it as each session starts; the build here
# gives the node its context before anything runs.
if ! capabilities hooks install --claude --codex < /dev/null > /dev/null; then
  echo "[entrypoint] WARN: could not wire the agent CLIs' session hooks; run capabilities hooks install --claude --codex inside the node" >&2
fi
if capabilities build < /dev/null > /dev/null; then
  echo "[entrypoint] context composed from the store"
else
  echo "[entrypoint] WARN: the agent's context could not be composed; run capabilities build inside the node" >&2
fi

# Readiness is reported, never fatal: one briefly unreachable service must not
# stop the node from coming up.
capabilities doctor >/dev/null 2>&1 || echo "[entrypoint] WARN: capabilities doctor reported findings; run it inside the node" >&2

# --- The agent's services ----------------------------------------------------
# `deployment` compiles the supervisor for this agent, here and on every boot.
# For an agent the store holds, its one program for the services is the node's
# service manager, `capabilities node run`, which keeps a program for each
# service the agent's gate places on this node and none for any other. The
# compiled folder is the entrypoint's own, so each boot - a restart of the same
# container too - lays it anew rather than meeting what the last boot left.
supervisor_conf=""
compiled=""
rm -rf "$APP/deployment"
if out="$(deployment init --profile agent-box-shell --provider manual < /dev/null 2>&1)" \
   && out="$(python3 - "$APP/deployment/runtime.json" "$APP" <<'PY' 2>&1
import json, sys
path, root = sys.argv[1], sys.argv[2]
with open(path) as f:
    runtime = json.load(f)
container = runtime.setdefault("compiler", {}).setdefault("container", {})
if container.get("project_root") != root:
    container["project_root"] = root
    with open(path, "w") as f:
        json.dump(runtime, f, indent=2, sort_keys=True)
        f.write("\n")
PY
)" \
   && out="$(deployment sync < /dev/null 2>&1)"; then
  compiled=yes
  if [ -f "$APP/deployment/targets/production/supervisord.conf" ]; then
    supervisor_conf="$APP/deployment/targets/production/supervisord.conf"
    if grep -q '^command=capabilities node run ' "$supervisor_conf"; then
      echo "[entrypoint] services compiled: the node's service manager runs those placed on this node"
    else
      echo "[entrypoint] services compiled: $(grep -c '^\[program:' "$supervisor_conf") runner(s) under the supervisor"
    fi
  else
    echo "[entrypoint] no service in the installed catalogue; nothing runs under the supervisor"
  fi
else
  echo "[entrypoint] WARN: the agent's services could not be compiled, so none runs on this node:" >&2
  printf '%s\n' "$out" >&2
fi

if [ -f "$HOME/.claude/.credentials.json" ] || [ -d "$HOME/.claude/projects" ]; then
  claude_auth="claude state present"
else
  claude_auth="claude not logged in; run: docker exec -it <container> claude login"
fi

if [ -f "$HOME/.codex/auth.json" ]; then
  codex_auth="codex state present"
else
  codex_auth="codex not logged in; run: docker exec -it <container> codex login --device-auth"
fi

echo "[entrypoint] agent node ready; $(claude --version 2>/dev/null || echo 'claude missing'); $claude_auth"
echo "[entrypoint] $(codex --version 2>/dev/null || echo 'codex missing'); $codex_auth"
if [ -n "$compiled" ]; then
  node_state "running agent $CAPABILITIES_PROJECT_ID as node $NODE"
else
  node_state "unhealthy: running agent $CAPABILITIES_PROJECT_ID as node $NODE without its services, which could not be compiled"
fi

if [ "$#" -gt 0 ]; then
  exec "$@"
fi

if [ -n "$supervisor_conf" ]; then
  printf '%s\n' "$supervisor_conf" > "$SUPERVISED"
  exec supervisord -c "$supervisor_conf"
fi

exec sleep infinity

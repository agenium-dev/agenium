#!/usr/bin/env bash
# The standard agent node's boot path. The image knows no agent: it waits idle
# until it is told which agent it runs (CAPABILITIES_PROJECT_ID), its name as a
# node (AGENT_NODE_NAME) and a store to reach, then raises that agent from the
# store into its root (CAPABILITIES_PROJECT_ID_ROOT, /app by default) and runs
# the agent's services under the supervisor.
set -euo pipefail

# What the box is doing, for its health check: present while it waits and once
# it runs. A box that cannot raise its agent exits instead.
STATE=/tmp/agent-node.state
node_state() { printf '%s\n' "$*" > "$STATE"; }
node_state "booting"

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
# A node starts knowing nothing. Until it has an agent id, a node name and a
# store the manager resolves for its root - in the environment, or a store
# setting written onto the node later - it waits here, healthy, and looks again
# every AGENT_NODE_POLL_SECONDS, so a setting written while it waits brings it up.
APP="${CAPABILITIES_PROJECT_ID_ROOT:-/app}"
mkdir -p "$APP"

missing() {
  local what=""
  [ -n "${CAPABILITIES_PROJECT_ID:-}" ] || what="$what CAPABILITIES_PROJECT_ID"
  [ -n "${AGENT_NODE_NAME:-}" ] || what="$what AGENT_NODE_NAME"
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

if ! capabilities init --id "$CAPABILITIES_PROJECT_ID" < /dev/null > /dev/null; then
  echo "[entrypoint] FATAL: could not bind $APP to agent $CAPABILITIES_PROJECT_ID as node $AGENT_NODE_NAME in the store this node reaches" >&2
  exit 1
fi
echo "[entrypoint] $APP bound to agent $CAPABILITIES_PROJECT_ID as node $AGENT_NODE_NAME"

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
# `deployment` compiles them for this agent, here and on every boot: a runner
# for every service of the installed catalogue, each of which starts its
# service only where the agent's gate places it on this node.
supervisor_conf=""
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
  if [ -f "$APP/deployment/targets/production/supervisord.conf" ]; then
    supervisor_conf="$APP/deployment/targets/production/supervisord.conf"
    echo "[entrypoint] services compiled: $(grep -c '^\[program:' "$supervisor_conf") runner(s) under the supervisor"
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
node_state "running agent $CAPABILITIES_PROJECT_ID as node $AGENT_NODE_NAME"

if [ "$#" -gt 0 ]; then
  exec "$@"
fi

if [ -n "$supervisor_conf" ]; then
  exec supervisord -c "$supervisor_conf"
fi

exec sleep infinity

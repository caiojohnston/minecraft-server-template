#!/bin/bash
# MineHost — Minecraft Server Startup Script
# Runs inside the GitHub Codespace on startup

# Detect script directory (works anywhere)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Server data lives as sibling to the script
SERVER="$SCRIPT_DIR/server"
LOG="$SERVER/server.log"
CONF="$SERVER/minehost.json"
CONTROL="$SCRIPT_DIR/control-server.js"

mkdir -p "$SERVER"
cd "$SERVER"

log() {
  local msg="[$(date '+%H:%M:%S')] [MINEHOST] $1"
  echo "$msg" >> "$LOG"
  echo "$msg"
}
err() {
  local msg="[$(date '+%H:%M:%S')] [MINEHOST] ERROR: $1"
  echo "$msg" >> "$LOG"
  echo "$msg" >&2
}

# ── Ensure dependencies ─────────────────────────────────────────────────────
if ! command -v tmux &>/dev/null; then
  log "Installing tmux..."
  sudo apt-get update -qq && sudo apt-get install -y -qq tmux > /dev/null 2>&1 || err "Failed to install tmux"
fi

if ! command -v jq &>/dev/null; then
  log "Installing jq..."
  sudo apt-get install -y -qq jq > /dev/null 2>&1 || err "Failed to install jq"
fi

if ! command -v java &>/dev/null; then
  err "Java is not installed"
  exit 1
fi

if ! command -v node &>/dev/null; then
  err "Node.js is not installed"
  exit 1
fi

log "Java: $(java -version 2>&1 | head -1)"
log "Node: $(node --version)"

# ── Read configuration ──────────────────────────────────────────────────────
if [ -f "$CONF" ]; then
  TYPE=$(jq -r '.type // "vanilla"' "$CONF")
  VER=$(jq -r '.version // "latest"' "$CONF")
  JVM=$(jq -r '.jvmArgs // "-Xmx2048m -Xms1024m"' "$CONF")
else
  TYPE="${MINEHOST_TYPE:-vanilla}"
  VER="${MINEHOST_VERSION:-latest}"
  JVM="${MINEHOST_JVM:--Xmx2048m -Xms1024m}"
  printf '{"type":"%s","version":"%s","jvmArgs":"%s"}\n' "$TYPE" "$VER" "$JVM" > "$CONF"
fi

log "Preparing $TYPE server (version: $VER)"

# Kill leftover tmux sessions
tmux kill-session -t mc 2>/dev/null || true

# ────────────────────────────────────────
# Download server JAR
# ────────────────────────────────────────

case "$TYPE" in
  vanilla)
    MANIFEST=$(curl -sL "https://launchermeta.mojang.com/mc/game/version_manifest.json")
    if [ "$VER" = "latest" ]; then
      VER_ID=$(echo "$MANIFEST" | jq -r '.latest.release')
    else
      VER_ID="$VER"
    fi
    VER_URL=$(echo "$MANIFEST" | jq -r --arg v "$VER_ID" '.versions[] | select(.id == $v) | .url' | head -1)
    if [ -z "$VER_URL" ] || [ "$VER_URL" = "null" ]; then
      err "Could not find Vanilla $VER_ID in manifest"
      exit 1
    fi
    JAR=$(curl -sL "$VER_URL" | jq -r '.downloads.server.url')
    curl -sL -o server.jar "$JAR"
    JAR_NAME="server.jar"
    log "Downloaded Vanilla $VER_ID"
    ;;

  paper)
    API="https://api.papermc.io/v2/projects/paper"
    if [ "$VER" = "latest" ]; then
      LVER=$(curl -sL "$API/versions" | jq -r '.versions[-1]')
    else
      LVER="$VER"
    fi
    BNUM=$(curl -sL "$API/versions/$LVER/builds" | jq -r '.builds[-1].build')
    JNAME=$(curl -sL "$API/versions/$LVER/builds/$BNUM" | jq -r '.downloads.application.name')
    curl -sL -o paper.jar "$API/versions/$LVER/builds/$BNUM/downloads/$JNAME"
    JAR_NAME="paper.jar"
    log "Downloaded Paper $LVER build #$BNUM"
    ;;

  fabric)
    FAPI="https://meta.fabricmc.net/v2"
    if [ "$VER" = "latest" ]; then
      VER=$(curl -sL "$FAPI/versions/game?limit=1" | jq -r '.[0].version')
    fi
    LOADER=$(curl -sL "$FAPI/versions/$VER" | jq -r '.[0].loader.version')
    log "Installing Fabric $VER with loader $LOADER"
    curl -sL -o fabric-installer.jar "https://maven.fabricmc.net/net/fabricmc/fabric-installer/1.1.0/fabric-installer-1.1.0.jar"
    java -jar fabric-installer.jar server -mcversion "$VER" -loader "$LOADER" -downloadMinecraft -nointeraction >> "$LOG" 2>&1
    JAR_NAME="fabric-server-launch.jar"
    rm -f fabric-installer.jar 2>/dev/null || true
    log "Fabric $VER installed"
    ;;

  forge)
    if [ "$VER" = "latest" ]; then
      MC_VER=$(curl -sL "https://launchermeta.mojang.com/mc/game/version_manifest.json" | jq -r '.latest.release')
    else
      MC_VER="$VER"
    fi
    log "Installing Forge for Minecraft $MC_VER"
    MCDATA=$(curl -sL "https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml")
    forge_ver=$(echo "$MCDATA" | grep "<latest>" | head -1 | sed 's/.*<latest>\(.*\)<\/latest>.*/\1/')
    if [ -z "$forge_ver" ] || [ "$forge_ver" = "null" ]; then
      err "Could not find Forge installer"
      exit 1
    fi
    curl -sL -o forge-installer.jar "https://maven.minecraftforge.net/net/minecraftforge/forge/$forge_ver/forge-$forge_ver-installer.jar"
    java -jar forge-installer.jar --installServer >> "$LOG" 2>&1
    rm -f forge-installer.jar 2>/dev/null || true
    JAR_NAME="run.sh"
    chmod +x "$JAR_NAME" 2>/dev/null || true
    log "Forge $forge_ver installed"
    ;;

  *)
    err "Unknown server type: $TYPE"
    exit 1
    ;;
esac

# ── Accept EULA ─────────────────────────────────────────────────────────────
echo "eula=true" > eula.txt

# ── Start server in tmux session ─────────────────────────────────────────────
FIRST_RUN=false
if [ ! -d "world" ] && [ "$JAR_NAME" != "run.sh" ]; then
  FIRST_RUN=true
  log "First run — generating world..."
fi

if [ "$JAR_NAME" = "run.sh" ]; then
  CMD="bash $JAR_NAME >> $LOG 2>&1"
else
  CMD="java $JVM -jar $JAR_NAME nogui >> $LOG 2>&1"
fi

tmux new-session -d -s mc "$CMD" || { err "Failed to create tmux session"; exit 1; }

if [ "$FIRST_RUN" = true ]; then
  for i in $(seq 1 30); do
    sleep 2
    if grep -q "Done" "$LOG" 2>/dev/null || grep -q "Complete" "$LOG" 2>/dev/null; then
      break
    fi
  done
  tmux send-keys -t mc "stop" C-m 2>/dev/null || true
  sleep 5
  tmux kill-session -t mc 2>/dev/null || true
  log "World generation complete — restarting server"
  tmux new-session -d -s mc "$CMD" || { err "Failed to restart tmux session"; exit 1; }
fi

sleep 2
log "Server started — tmux session: mc"

# ── Start control server (port 8081) ─────────────────────────────────────────
log "Starting control server on :8081..."
node "$CONTROL" 2>&1 &

# Wait for control server to respond
for i in $(seq 1 15); do
  if curl -s http://localhost:8081/status > /dev/null 2>&1; then
    log "Control server is up and responding"
    break
  fi
  sleep 1
done

# Set port 8081 to public via GitHub API (devcontainer.json visibility is ignored for API-created codespaces)
if [ -n "$CODESPACE_NAME" ] && [ -n "$GITHUB_TOKEN" ]; then
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PATCH \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/user/codespaces/${CODESPACE_NAME}/ports/8081" \
    -d '{"visibility":"public"}')
  log "Port 8081 visibility → public (API status: $HTTP_CODE)"
else
  log "Skipping port visibility (CODESPACE_NAME or GITHUB_TOKEN not set)"
fi

# Keep script alive
tail -f "$LOG"

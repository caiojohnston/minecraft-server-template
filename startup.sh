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

# Returns required Java major version for a given MC version string (e.g. "1.20.1")
mc_java_ver() {
  local minor patch
  minor=$(echo "$1" | cut -d. -f2)
  patch=$(echo "$1" | cut -d. -f3)
  if [ "$minor" -ge 21 ] || { [ "$minor" -eq 20 ] && [ "${patch:-0}" -ge 5 ]; }; then
    echo "21"
  elif [ "$minor" -ge 17 ]; then
    echo "17"
  else
    echo "8"
  fi
}

# Ensures Java <ver> is installed; returns path to its binary.
# All log/err calls use >&2 so stdout stays clean for command substitution.
require_java() {
  local need="$1"
  local current_major bin
  current_major=$(java -version 2>&1 | grep -oP '(?<=version ")\d+' | head -1)
  if [ "$current_major" = "$need" ]; then echo "java"; return; fi
  bin=$(find /usr/lib/jvm -maxdepth 3 -name "java" 2>/dev/null | grep -- "-${need}-" | head -1)
  if [ -z "$bin" ]; then
    log "Java $current_major present but Java $need required — installing openjdk-${need}-jdk..." >&2
    sudo apt-get install -y -qq "openjdk-${need}-jdk" > /dev/null 2>&1 \
      || { err "Failed to install Java $need — using default Java (may fail)" >&2; echo "java"; return; }
    bin=$(find /usr/lib/jvm -maxdepth 3 -name "java" 2>/dev/null | grep -- "-${need}-" | head -1)
  fi
  echo "${bin:-java}"
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

JAVA_CMD="java"
JAVA_MC_VER=""

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
    JAVA_MC_VER="$VER_ID"
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
    JAVA_MC_VER="$LVER"
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
    JAVA_MC_VER="$VER"
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
    JAVA_CMD=$(require_java "$(mc_java_ver "$MC_VER")")
    JAVA_MC_VER="$MC_VER"
    log "Using Java $(mc_java_ver "$MC_VER") for Forge ($JAVA_CMD)"
    MCDATA=$(curl -sL "https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml")
    forge_ver=$(echo "$MCDATA" | grep "<latest>" | head -1 | sed 's/.*<latest>\(.*\)<\/latest>.*/\1/')
    if [ -z "$forge_ver" ] || [ "$forge_ver" = "null" ]; then
      err "Could not find Forge installer"
      exit 1
    fi
    curl -sL -o forge-installer.jar "https://maven.minecraftforge.net/net/minecraftforge/forge/$forge_ver/forge-$forge_ver-installer.jar"
    "$JAVA_CMD" -jar forge-installer.jar --installServer >> "$LOG" 2>&1
    rm -f forge-installer.jar 2>/dev/null || true
    JAR_NAME="run.sh"
    chmod +x "$JAR_NAME" 2>/dev/null || true
    log "Forge $forge_ver installed"
    ;;

  curseforge)
    if [ -z "$MINEHOST_CF_URL" ]; then
      err "MINEHOST_CF_URL not set — provide the server pack URL during setup"
      exit 1
    fi
    log "Downloading CurseForge server pack..."
    if ! curl -sL -L --connect-timeout 30 --max-time 600 -o /tmp/cfpack.zip "$MINEHOST_CF_URL"; then
      err "Download failed: $MINEHOST_CF_URL"
      exit 1
    fi
    log "Extracting server pack..."
    unzip -q /tmp/cfpack.zip -d "$SERVER" 2>/dev/null || { err "Failed to extract zip"; exit 1; }
    rm -f /tmp/cfpack.zip

    # Write JVM args for modern Forge/NeoForge run.sh (uses user_jvm_args.txt)
    echo "$JVM" > "$SERVER/user_jvm_args.txt"

    # Accept EULA now (before looking for start scripts)
    echo "eula=true" > "$SERVER/eula.txt"

    # Run installer if pack ships forge/neoforge installer instead of server
    # Use find instead of glob ls — more reliable across environments
    INSTALLER=$(find "$SERVER" -maxdepth 1 \( -name "forge-*-installer.jar" -o -name "neoforge-*-installer.jar" \) 2>/dev/null | head -1)
    if [ -n "$INSTALLER" ]; then
      # Extract MC version from installer name (e.g. forge-1.20.1-47.4.2-installer.jar → 1.20.1)
      CF_MC_VER=$(basename "$INSTALLER" | grep -oP '(?:forge|neoforge)-\K\d+\.\d+(?:\.\d+)?')
      if [ -n "$CF_MC_VER" ]; then
        JAVA_MC_VER="$CF_MC_VER"
        JAVA_CMD=$(require_java "$(mc_java_ver "$CF_MC_VER")")
        log "Detected MC $CF_MC_VER → using Java $(mc_java_ver "$CF_MC_VER") ($JAVA_CMD)"
      fi
      log "Running Forge/NeoForge installer: $(basename "$INSTALLER")"
      (cd "$SERVER" && "$JAVA_CMD" -jar "$(basename "$INSTALLER")" --installServer >> "$LOG" 2>&1)
      INSTALLER_EXIT=$?
      [ $INSTALLER_EXIT -ne 0 ] && log "WARNING: Installer exited with code $INSTALLER_EXIT — continuing"
      rm -f "$INSTALLER"
    fi

    # Find start mechanism — ordered by preference
    CMD=""
    for script in run.sh start.sh startserver.sh ServerStart.sh; do
      if [ -f "$SERVER/$script" ]; then
        chmod +x "$SERVER/$script"
        JAR_NAME="$script"
        break
      fi
    done

    # Fallback: run.bat present — generate run.sh from libraries/unix_args.txt
    if [ -z "$JAR_NAME" ] && [ -f "$SERVER/run.bat" ]; then
      UNIX_ARGS=$(find "$SERVER/libraries" -name "unix_args.txt" 2>/dev/null | head -1)
      if [ -n "$UNIX_ARGS" ]; then
        log "Generating run.sh from unix_args.txt"
        printf '#!/usr/bin/env bash\n"%s" @user_jvm_args.txt @"%s" "$@"\n' "$JAVA_CMD" "$UNIX_ARGS" > "$SERVER/run.sh"
        chmod +x "$SERVER/run.sh"
        JAR_NAME="run.sh"
      fi
    fi

    # Fallback: find server jar directly
    if [ -z "$JAR_NAME" ]; then
      FOUND_JAR=$(find "$SERVER" -maxdepth 1 \( -name "server.jar" -o -name "minecraft_server*.jar" -o -name "forge-*-server.jar" -o -name "neoforge-*-server.jar" \) 2>/dev/null | head -1)
      if [ -n "$FOUND_JAR" ]; then
        JAR_NAME=$(basename "$FOUND_JAR")
      else
        err "No server start method found. Contents: $(ls "$SERVER" | head -20 | tr '\n' ' ')"
        exit 1
      fi
    fi

    log "CurseForge server pack ready: $JAR_NAME"
    ;;

  *)
    err "Unknown server type: $TYPE"
    exit 1
    ;;
esac

# ── Resolve correct Java for vanilla/paper/fabric (forge/curseforge set it earlier) ──
if [ -n "$JAVA_MC_VER" ] && [ "$JAVA_CMD" = "java" ]; then
  JAVA_NEED=$(mc_java_ver "$JAVA_MC_VER")
  JAVA_CMD=$(require_java "$JAVA_NEED")
  [ "$JAVA_CMD" != "java" ] && log "Using Java $JAVA_NEED for MC $JAVA_MC_VER"
fi
# Export JAVA_HOME so run.sh scripts (Forge/NeoForge) pick up the right Java
if [ "$JAVA_CMD" != "java" ]; then
  export JAVA_HOME
  JAVA_HOME="$(dirname "$(dirname "$JAVA_CMD")")"
fi

# ── Accept EULA ─────────────────────────────────────────────────────────────
# curseforge case writes eula.txt early (before start script detection); skip for others
if [ "$TYPE" != "curseforge" ]; then
  echo "eula=true" > eula.txt
fi

# ── Start server in tmux session ─────────────────────────────────────────────
FIRST_RUN=false
if [ ! -d "world" ] && [ "$JAR_NAME" != "run.sh" ]; then
  FIRST_RUN=true
  log "First run — generating world..."
fi

if [ "$JAR_NAME" = "run.sh" ]; then
  CMD="bash $JAR_NAME >> $LOG 2>&1"
else
  CMD="\"$JAVA_CMD\" $JVM -jar $JAR_NAME nogui >> $LOG 2>&1"
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

# ── TCP tunnel via bore (exposes port 25565 publicly for Minecraft clients) ──
BORE_BIN="$SCRIPT_DIR/bore"
SERVER_IP_FILE="$SCRIPT_DIR/.server_ip"
rm -f "$SERVER_IP_FILE"

if [ ! -f "$BORE_BIN" ]; then
  log "Downloading bore TCP tunnel..."
  BORE_VER=$(curl -sL --connect-timeout 5 "https://api.github.com/repos/ekzhang/bore/releases/latest" \
    | grep '"tag_name"' | grep -oP 'v\K[0-9.]+' | head -1)
  BORE_VER="${BORE_VER:-0.5.0}"
  curl -sL "https://github.com/ekzhang/bore/releases/download/v${BORE_VER}/bore-v${BORE_VER}-x86_64-unknown-linux-musl.tar.gz" \
    | tar -xz -C "$SCRIPT_DIR" 2>/dev/null
  [ -f "$BORE_BIN" ] && chmod +x "$BORE_BIN" && log "bore $BORE_VER downloaded"
fi

if [ -f "$BORE_BIN" ]; then
  BORE_LOG="$SCRIPT_DIR/.bore.log"
  "$BORE_BIN" local 25565 --to bore.pub > "$BORE_LOG" 2>&1 &
  log "TCP tunnel started (bore.pub) — waiting for port assignment..."

  # Background: wait for bore to connect, then write IP to file
  (
    for i in $(seq 1 20); do
      sleep 1
      ADDR=$(grep -oP 'bore\.pub:\d+' "$BORE_LOG" 2>/dev/null | head -1)
      if [ -n "$ADDR" ]; then
        echo "$ADDR" > "$SERVER_IP_FILE"
        echo "[$(date '+%H:%M:%S')] [MINEHOST] Server IP: $ADDR — players can connect!" >> "$LOG"
        break
      fi
    done
    if [ ! -f "$SERVER_IP_FILE" ]; then
      echo "[$(date '+%H:%M:%S')] [MINEHOST] WARN: bore did not connect in 20s — no public IP" >> "$LOG"
    fi
  ) &
else
  log "bore not available — no TCP tunnel (players cannot connect externally)"
fi

# Keep script alive
tail -f "$LOG"

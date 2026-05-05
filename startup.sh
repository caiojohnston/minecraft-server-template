#!/bin/bash
# MineHost — Minecraft Server Startup Script
# Runs inside the GitHub Codespace on startup

# Detect script directory (works anywhere)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-update: pull latest template before running the rest of the script.
# This ensures Codespaces that were created before a fix always run the
# newest version without requiring the user to recreate the Codespace.
if [ -d "$SCRIPT_DIR/.git" ]; then
  _BEFORE=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null)
  git -C "$SCRIPT_DIR" pull --ff-only --quiet 2>/dev/null
  _AFTER=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null)
  if [ "$_BEFORE" != "$_AFTER" ]; then
    echo "[$(date '+%H:%M:%S')] [MINEHOST] Template updated ($_BEFORE → $_AFTER), re-executing..."
    exec bash "$SCRIPT_DIR/startup.sh" "$@"
  fi
  unset _BEFORE _AFTER
fi

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

# Write startup stage to file — control-server.js reads and broadcasts it
set_stage() {
  echo "$1" > "$SCRIPT_DIR/.mc_stage"
}

# Returns required Java major version for a given MC version string.
# Handles legacy "1.X.Y" format and new calendar-based "26.X.Y" format.
mc_java_ver() {
  local major minor patch
  major=$(echo "$1" | cut -d. -f1)
  minor=$(echo "$1" | cut -d. -f2)
  patch=$(echo "$1" | cut -d. -f3)
  # New calendar versioning (MC >= 2025): major is the year (e.g. 26 = year 2026)
  # MC 25.x (year 2025) → Java 25; MC 26.x+ → Java 25 (until Mojang raises the bar)
  if [ "$major" -ge 2 ] 2>/dev/null; then
    echo "25"
    return
  fi
  # Legacy 1.X.Y versioning
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
  # Exact match only — Forge/mods break on newer JVMs (e.g. Java 25 removes sun.misc.Unsafe APIs)
  if [ -n "$current_major" ] && [ "$current_major" -eq "$need" ] 2>/dev/null; then
    echo "java"
    return
  fi
  bin=$(find /usr/lib/jvm -maxdepth 3 -name "java" 2>/dev/null | grep -- "-${need}-" | head -1)
  if [ -z "$bin" ]; then
    if [ -z "$current_major" ]; then
      log "Java não encontrado — instalando openjdk-${need}-jdk..." >&2
    else
      log "Java $current_major encontrado mas Java $need necessário — instalando openjdk-${need}-jdk..." >&2
    fi
    sudo apt-get update -qq > /dev/null 2>&1
    sudo apt-get install -y -qq "openjdk-${need}-jdk" > /dev/null 2>&1 \
      || { err "Falha ao instalar Java $need — usando java padrão (pode falhar)" >&2; echo "java"; return; }
    bin=$(find /usr/lib/jvm -maxdepth 3 -name "java" 2>/dev/null | grep -- "-${need}-" | head -1)
  fi
  log "Java $need pronto: ${bin:-java}" >&2
  echo "${bin:-java}"
}

# ── Gist discovery: fix stale MINEHOST_GIST_ID Secret ───────────────────────
# Codespace Secrets propagate stale gist IDs from previous runs.
# CRITICAL: GITHUB_TOKEN in Codespaces has repo scope only — NO gist access.
# Must use MINEHOST_TOKEN (user PAT, always same value, has gist scope).
# Fallback: gh CLI is pre-authenticated in Codespaces with the user's full token.
# NOTE: jq not installed yet (installed later). Use python3 (always available).
_DISCO_TOKEN="${MINEHOST_TOKEN:-}"
if [ -z "$_DISCO_TOKEN" ] && command -v gh &>/dev/null; then
  _DISCO_TOKEN=$(gh auth token 2>/dev/null || echo "")
  [ -n "$_DISCO_TOKEN" ] && log "Gist discovery: using gh CLI token (MINEHOST_TOKEN not yet available)"
fi

if [ -n "$_DISCO_TOKEN" ]; then
  log "Gist discovery: querying GitHub API..."
  _GIST_LIST=$(curl -s \
    -H "Authorization: Bearer $_DISCO_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/gists?per_page=100" 2>/dev/null)

  # python3 primary (always available in Codespaces), jq fallback
  FOUND_GIST=$(echo "$_GIST_LIST" | python3 -c "
import sys, json
try:
  gists = json.load(sys.stdin)
  if not isinstance(gists, list):
    print('')
  else:
    m = sorted([g for g in gists if g.get('description') == 'minehost-state'],
               key=lambda g: g.get('created_at', ''), reverse=True)
    print(m[0]['id'] if m else '')
except Exception:
  print('')
" 2>/dev/null)

  if [ -z "$FOUND_GIST" ] && command -v jq &>/dev/null; then
    FOUND_GIST=$(echo "$_GIST_LIST" \
      | jq -r '[.[] | select(.description == "minehost-state")] | sort_by(.created_at) | last | .id // empty' 2>/dev/null)
  fi

  unset _GIST_LIST

  if [ -n "$FOUND_GIST" ]; then
    _STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer $_DISCO_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/gists/$FOUND_GIST" 2>/dev/null)
    if [ "$_STATUS" = "200" ]; then
      [ "$FOUND_GIST" != "${MINEHOST_GIST_ID:-}" ] && \
        log "MINEHOST_GIST_ID corrected (was: ${MINEHOST_GIST_ID:-empty}): $FOUND_GIST"
      MINEHOST_GIST_ID="$FOUND_GIST"
      # Only update MINEHOST_TOKEN if it was missing (Secret not propagated yet)
      [ -z "${MINEHOST_TOKEN:-}" ] && MINEHOST_TOKEN="$_DISCO_TOKEN"
      export MINEHOST_GIST_ID MINEHOST_TOKEN
      log "Gist sync ready: $MINEHOST_GIST_ID"
    else
      log "WARNING: Gist $FOUND_GIST not accessible (HTTP $_STATUS) — console sync may fail"
    fi
    unset _STATUS
  else
    log "No minehost-state gist found — creating a new one..."
    _NEW_GIST=$(curl -s \
      -X POST \
      -H "Authorization: Bearer $_DISCO_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -d '{"description":"minehost-state","public":false,"files":{"state.json":{"content":"{}"}}}' \
      "https://api.github.com/gists" 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null)
    if [ -n "$_NEW_GIST" ]; then
      MINEHOST_GIST_ID="$_NEW_GIST"
      [ -z "${MINEHOST_TOKEN:-}" ] && MINEHOST_TOKEN="$_DISCO_TOKEN"
      export MINEHOST_GIST_ID MINEHOST_TOKEN
      log "Created new gist: $MINEHOST_GIST_ID"
    else
      log "WARNING: Failed to create gist — console sync unavailable"
      log "DEBUG: MINEHOST_GIST_ID=${MINEHOST_GIST_ID:-empty} MINEHOST_TOKEN=${MINEHOST_TOKEN:+set}"
    fi
    unset _NEW_GIST
  fi

  unset _DISCO_TOKEN
else
  log "WARNING: No token for gist discovery (MINEHOST_TOKEN empty, gh not available)"
  log "DEBUG: MINEHOST_GIST_ID=${MINEHOST_GIST_ID:-empty} GITHUB_TOKEN=${GITHUB_TOKEN:+set}"
fi

# ── Start control server (port 8081) ─────────────────────────────────────────
# MUST start AFTER gist discovery above — control-server.js captures
# MINEHOST_GIST_ID at startup. If started before, it uses stale/empty
# GIST_ID and never syncs console/logs to the correct gist.
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

# Force port 8081 to public so the frontend SSE probe can reach it without OAuth
# devcontainer.json "visibility: public" is a VS Code hint only — not reliable
# Force port 8081 to public so SSE/control API is reachable from the browser.
# GitHub auto-detects listening ports but defaults them to private.
# Make port 8081 public so the browser can connect via SSE.
# Priority: gh CLI (pre-installed + pre-authed in Codespaces) → REST API fallback.
log "Setting port 8081 to public (CODESPACE_NAME=${CODESPACE_NAME:-EMPTY})..."
_PORT_SET=false

# 1. gh CLI — available inside every Codespace and already authenticated
if [ -z "${CODESPACE_NAME:-}" ]; then
  log "CODESPACE_NAME not set — skipping port visibility"
else
  _GH=$(command -v gh 2>/dev/null || echo "")
  [ -z "$_GH" ] && [ -x /usr/bin/gh ]       && _GH=/usr/bin/gh
  [ -z "$_GH" ] && [ -x /usr/local/bin/gh ] && _GH=/usr/local/bin/gh
  [ -z "$_GH" ] && [ -x /home/codespace/.local/bin/gh ] && _GH=/home/codespace/.local/bin/gh

  # Install gh CLI if not found (one-time, ~20s; persists for the life of the Codespace)
  if [ -z "$_GH" ]; then
    log "gh CLI not found — installing..."
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt-get update -qq 2>/dev/null && sudo apt-get install -y -qq gh 2>/dev/null
    _GH=$(command -v gh 2>/dev/null || echo "")
    [ -n "$_GH" ] && log "gh CLI installed: $_GH" || log "gh CLI install failed"
  fi

  if [ -n "$_GH" ]; then
    if "$_GH" codespace ports visibility 8081:public -c "$CODESPACE_NAME" 2>/tmp/_gh_port.log; then
      log "Port 8081 set to public via gh CLI"
      _PORT_SET=true
    else
      log "gh CLI failed: $(cat /tmp/_gh_port.log 2>/dev/null | head -c 200)"
    fi
    rm -f /tmp/_gh_port.log
  else
    log "gh CLI not found — falling back to REST API"
  fi

  # 2. REST API fallback (POST then PATCH, two tokens)
  if [ "$_PORT_SET" = false ]; then
    for _TOK in "${GITHUB_TOKEN:-}" "${MINEHOST_TOKEN:-}"; do
      [ -z "$_TOK" ] && continue
      [ "$_PORT_SET" = true ] && break

      _HTTP=$(curl -s -o /tmp/_port_resp.json -w "%{http_code}" -X POST \
        -H "Authorization: Bearer $_TOK" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -d '{"port":8081,"label":"MineHost Control","visibility":"public"}' \
        "https://api.github.com/user/codespaces/$CODESPACE_NAME/ports" 2>/dev/null)
      if [ "$_HTTP" = "200" ] || [ "$_HTTP" = "201" ] || [ "$_HTTP" = "204" ]; then
        log "Port 8081 set to public via REST POST (HTTP $_HTTP)"
        _PORT_SET=true; break
      fi

      _HTTP=$(curl -s -o /tmp/_port_resp.json -w "%{http_code}" -X PATCH \
        -H "Authorization: Bearer $_TOK" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -d '{"visibility":"public"}' \
        "https://api.github.com/user/codespaces/$CODESPACE_NAME/ports/8081" 2>/dev/null)
      if [ "$_HTTP" = "200" ] || [ "$_HTTP" = "204" ]; then
        log "Port 8081 set to public via REST PATCH (HTTP $_HTTP)"
        _PORT_SET=true; break
      fi
      _BODY=$(cat /tmp/_port_resp.json 2>/dev/null | head -c 200)
      log "REST API HTTP $_HTTP: $_BODY"
      rm -f /tmp/_port_resp.json
    done
  fi

  [ "$_PORT_SET" = false ] && log "WARNING: Could not set port 8081 to public — SSE will retry via proxy"
fi
unset _PORT_SET _GH _HTTP _TOK _BODY

# ── Ensure dependencies ─────────────────────────────────────────────────────
set_stage "deps"
if ! command -v tmux &>/dev/null; then
  log "Installing tmux..."
  sudo apt-get update -qq && sudo apt-get install -y -qq tmux > /dev/null 2>&1 || err "Failed to install tmux"
fi

if ! command -v jq &>/dev/null; then
  log "Installing jq..."
  sudo apt-get install -y -qq jq > /dev/null 2>&1 || err "Failed to install jq"
fi

if ! command -v node &>/dev/null; then
  err "Node.js is not installed"
  exit 1
fi

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

# Kill leftover tmux sessions and release any stale world lock
tmux kill-session -t mc 2>/dev/null || true
sleep 2
find "$SERVER" -name "session.lock" -delete 2>/dev/null || true

JAVA_CMD="java"
JAVA_MC_VER=""

# For non-CurseForge types with a pinned version, resolve and install Java now
# CurseForge: MC version only known after extracting the pack — handled inside the case block
if [ "$TYPE" != "curseforge" ] && [ "$VER" != "latest" ]; then
  JAVA_NEED=$(mc_java_ver "$VER")
  RESOLVED=$(require_java "$JAVA_NEED")
  if [ "$RESOLVED" != "java" ]; then
    JAVA_CMD="$RESOLVED"
    JAVA_MC_VER="$VER"
    JAVA_HOME="$(dirname "$(dirname "$JAVA_CMD")")"
    export JAVA_HOME
    export PATH="$(dirname "$JAVA_CMD"):$PATH"
    log "Pre-installed Java $JAVA_NEED for MC $VER"
  fi
fi

# ────────────────────────────────────────
# Download server JAR
# ────────────────────────────────────────
set_stage "download"

case "$TYPE" in
  vanilla)
    if [ -f "$SERVER/server.jar" ]; then
      JAR_NAME="server.jar"
      JAVA_MC_VER=$(cat "$SCRIPT_DIR/.mc_java_ver" 2>/dev/null || echo "$VER")
      log "Vanilla already installed — skipping download"
    else
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
      echo "$JAVA_MC_VER" > "$SCRIPT_DIR/.mc_java_ver"
      log "Downloaded Vanilla $VER_ID"
    fi
    ;;

  paper)
    if [ -f "$SERVER/paper.jar" ]; then
      JAR_NAME="paper.jar"
      JAVA_MC_VER=$(cat "$SCRIPT_DIR/.mc_java_ver" 2>/dev/null || echo "$VER")
      log "Paper already installed — skipping download"
    else
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
      echo "$JAVA_MC_VER" > "$SCRIPT_DIR/.mc_java_ver"
      log "Downloaded Paper $LVER build #$BNUM"
    fi
    ;;

  fabric)
    if [ -f "$SERVER/fabric-server-launch.jar" ]; then
      JAR_NAME="fabric-server-launch.jar"
      JAVA_MC_VER=$(cat "$SCRIPT_DIR/.mc_java_ver" 2>/dev/null || echo "$VER")
      log "Fabric already installed — skipping install"
    else
      FAPI="https://meta.fabricmc.net/v2"
      if [ "$VER" = "latest" ]; then
        VER=$(curl -sL "$FAPI/versions/game?limit=1" | jq -r '.[0].version')
      fi
      LOADER=$(curl -sL "$FAPI/versions/$VER" | jq -r '.[0].loader.version')
      JAVA_NEED=$(mc_java_ver "$VER")
      JAVA_CMD=$(require_java "$JAVA_NEED")
      JAVA_MC_VER="$VER"
      set_stage "install"
      log "Installing Fabric $VER with loader $LOADER (Java $JAVA_NEED)"
      curl -sL -o fabric-installer.jar "https://maven.fabricmc.net/net/fabricmc/fabric-installer/1.1.0/fabric-installer-1.1.0.jar"
      "$JAVA_CMD" -jar fabric-installer.jar server -mcversion "$VER" -loader "$LOADER" -downloadMinecraft -nointeraction >> "$LOG" 2>&1
      JAR_NAME="fabric-server-launch.jar"
      rm -f fabric-installer.jar 2>/dev/null || true
      echo "$JAVA_MC_VER" > "$SCRIPT_DIR/.mc_java_ver"
      log "Fabric $VER installed"
    fi
    ;;

  forge)
    if [ -f "$SERVER/run.sh" ]; then
      JAR_NAME="run.sh"
      JAVA_MC_VER=$(cat "$SCRIPT_DIR/.mc_java_ver" 2>/dev/null || echo "$VER")
      log "Forge already installed — skipping install"
    else
      if [ "$VER" = "latest" ]; then
        MC_VER=$(curl -sL "https://launchermeta.mojang.com/mc/game/version_manifest.json" | jq -r '.latest.release')
      else
        MC_VER="$VER"
      fi
      set_stage "install"
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
      echo "$JAVA_MC_VER" > "$SCRIPT_DIR/.mc_java_ver"
      log "Forge $forge_ver installed"
    fi
    ;;

  curseforge)
    # Check if already installed — look for known start scripts or libraries dir
    CF_JAR_NAME=""
    for script in run.sh start.sh startserver.sh ServerStart.sh; do
      if [ -f "$SERVER/$script" ]; then
        CF_JAR_NAME="$script"
        break
      fi
    done
    [ -z "$CF_JAR_NAME" ] && [ -d "$SERVER/libraries" ] && \
      CF_JAR_NAME=$(find "$SERVER" -maxdepth 1 \( -name "server.jar" -o -name "minecraft_server*.jar" -o -name "forge-*-server.jar" -o -name "neoforge-*-server.jar" \) 2>/dev/null | head -1 | xargs -r basename)

    if [ -n "$CF_JAR_NAME" ]; then
      JAR_NAME="$CF_JAR_NAME"
      JAVA_MC_VER=$(cat "$SCRIPT_DIR/.mc_java_ver" 2>/dev/null || echo "")
      echo "$JVM" > "$SERVER/user_jvm_args.txt"
      log "CurseForge already installed ($JAR_NAME) — skipping download"
    else
      if [ -z "$MINEHOST_CF_URL" ]; then
        err "MINEHOST_CF_URL not set — provide the server pack URL during setup"
        exit 1
      fi
      log "Downloading CurseForge server pack..."
      if ! curl -sL -L --connect-timeout 30 --max-time 600 -o /tmp/cfpack.zip "$MINEHOST_CF_URL"; then
        err "Download failed: $MINEHOST_CF_URL"
        exit 1
      fi
      set_stage "install"
      log "Extracting server pack..."
      unzip -q /tmp/cfpack.zip -d "$SERVER" 2>/dev/null || { err "Failed to extract zip"; exit 1; }
      rm -f /tmp/cfpack.zip

      echo "$JVM" > "$SERVER/user_jvm_args.txt"
      echo "eula=true" > "$SERVER/eula.txt"

      INSTALLER=$(find "$SERVER" -maxdepth 1 \( -name "forge-*-installer.jar" -o -name "neoforge-*-installer.jar" \) 2>/dev/null | head -1)
      if [ -n "$INSTALLER" ]; then
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

      for script in run.sh start.sh startserver.sh ServerStart.sh; do
        if [ -f "$SERVER/$script" ]; then
          chmod +x "$SERVER/$script"
          JAR_NAME="$script"
          break
        fi
      done

      if [ -z "$JAR_NAME" ] && [ -f "$SERVER/run.bat" ]; then
        UNIX_ARGS=$(find "$SERVER/libraries" -name "unix_args.txt" 2>/dev/null | head -1)
        if [ -n "$UNIX_ARGS" ]; then
          log "Generating run.sh from unix_args.txt"
          printf '#!/usr/bin/env bash\n"%s" @user_jvm_args.txt @"%s" "$@"\n' "$JAVA_CMD" "$UNIX_ARGS" > "$SERVER/run.sh"
          chmod +x "$SERVER/run.sh"
          JAR_NAME="run.sh"
        fi
      fi

      if [ -z "$JAR_NAME" ]; then
        FOUND_JAR=$(find "$SERVER" -maxdepth 1 \( -name "server.jar" -o -name "minecraft_server*.jar" -o -name "forge-*-server.jar" -o -name "neoforge-*-server.jar" \) 2>/dev/null | head -1)
        if [ -n "$FOUND_JAR" ]; then
          JAR_NAME=$(basename "$FOUND_JAR")
        else
          err "No server start method found. Contents: $(ls "$SERVER" | head -20 | tr '\n' ' ')"
          exit 1
        fi
      fi

      echo "$JAVA_MC_VER" > "$SCRIPT_DIR/.mc_java_ver"
      log "CurseForge server pack ready: $JAR_NAME"
    fi
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
# Export JAVA_HOME and prepend to PATH so run.sh scripts (Forge/NeoForge) pick up the right Java
if [ "$JAVA_CMD" != "java" ]; then
  JAVA_HOME="$(dirname "$(dirname "$JAVA_CMD")")"
  export JAVA_HOME
  export PATH="$(dirname "$JAVA_CMD"):$PATH"
  log "Java path: $JAVA_CMD | JAVA_HOME: $JAVA_HOME"
fi
log "Java: $("$JAVA_CMD" -version 2>&1 | head -1)"

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

set_stage "starting"
echo "$CMD" > "$SCRIPT_DIR/.mc_cmd"
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

# ── TCP tunnel via playit.gg (bore fallback if download fails) ────────────────
PLAYIT_BIN="$SCRIPT_DIR/playit"
BORE_BIN="$SCRIPT_DIR/bore"
SERVER_IP_FILE="$SCRIPT_DIR/.server_ip"
PLAYIT_CLAIM_FILE="$SCRIPT_DIR/.playit_claim"

rm -f "$SERVER_IP_FILE" "$PLAYIT_CLAIM_FILE"

# Download playit if not present
if [ ! -f "$PLAYIT_BIN" ]; then
  log "Downloading playit.gg tunnel agent..."
  PLAYIT_VER=$(curl -sL --connect-timeout 5 \
    "https://api.github.com/repos/playit-cloud/playit-agent/releases/latest" \
    | grep -oP '"tag_name":\s*"\K[^"]+' | head -1)
  PLAYIT_VER="${PLAYIT_VER:-v0.17.1}"
  if curl -sL --connect-timeout 10 --max-time 120 -L \
    "https://github.com/playit-cloud/playit-agent/releases/download/${PLAYIT_VER}/playit-linux-amd64" \
    -o "$PLAYIT_BIN" && [ -s "$PLAYIT_BIN" ]; then
    chmod +x "$PLAYIT_BIN"
    log "playit ${PLAYIT_VER} downloaded"
  else
    rm -f "$PLAYIT_BIN"
    log "WARNING: playit download failed — trying bore fallback"
  fi
fi

# Extracts playit tunnel public address from its log output.
# Format: "public_addr => 127.0.0.1:25565"
_playit_extract_addr() {
  local logfile="$1"
  local addr
  addr=$(grep -oP '[a-zA-Z0-9.-]+\.(?:ply\.gg|joinmc\.link|playit\.gg):\d+' "$logfile" 2>/dev/null | head -1)
  [ -z "$addr" ] && addr=$(grep -oP '[^\s]+(?=\s*=>\s*(?:127\.0\.0\.1|localhost):\d+)' "$logfile" 2>/dev/null | head -1)
  echo "$addr"
}

if [ -f "$PLAYIT_BIN" ] && [ -n "${MINEHOST_PLAYIT_TOKEN:-}" ]; then
  # ── Fluxo A: token presente — túnel estático estável ────────────────────────
  # playit v0.17.1 is a TUI app — NEVER forward its raw output to $LOG (ANSI pollution).
  # Grep works directly on the raw log since addresses/URLs are literal text in the ANSI soup.
  log "Starting playit.gg tunnel (authenticated)..."
  PLAYIT_LOG="$SCRIPT_DIR/.playit.log"
  (
    while true; do
      rm -f "$SERVER_IP_FILE" "$PLAYIT_CLAIM_FILE"
      > "$PLAYIT_LOG"
      # Try --secret flag (v1.x CLI) with SECRET_KEY env var fallback (Docker compat)
      SECRET_KEY="$MINEHOST_PLAYIT_TOKEN" "$PLAYIT_BIN" --secret "$MINEHOST_PLAYIT_TOKEN" \
        > "$PLAYIT_LOG" 2>&1 &
      PLAYIT_PID=$!

      for i in $(seq 1 30); do
        sleep 2
        ADDR=$(_playit_extract_addr "$PLAYIT_LOG")
        if [ -n "$ADDR" ]; then
          echo "$ADDR" > "$SERVER_IP_FILE"
          echo "[$(date '+%H:%M:%S')] [MINEHOST] playit tunnel: $ADDR" >> "$LOG"
          tmux send-keys -t mc "say [MineHost] Endereco: $ADDR" C-m 2>/dev/null || true
          break
        fi
        # If playit ignored our secret and shows a claim URL instead, capture it
        CLAIM_URL=$(grep -oP '(?:https?://)?playit\.gg/claim/[a-zA-Z0-9]+' "$PLAYIT_LOG" 2>/dev/null | head -1)
        if [ -n "$CLAIM_URL" ] && [ ! -f "$PLAYIT_CLAIM_FILE" ]; then
          [[ "$CLAIM_URL" != http* ]] && CLAIM_URL="https://$CLAIM_URL"
          echo "$CLAIM_URL" > "$PLAYIT_CLAIM_FILE"
          echo "[$(date '+%H:%M:%S')] [MINEHOST] playit requer autenticacao: $CLAIM_URL" >> "$LOG"
          echo "[$(date '+%H:%M:%S')] [MINEHOST] Visite o link acima no painel MineHost para ativar o tunel" >> "$LOG"
        fi
      done

      if [ ! -f "$SERVER_IP_FILE" ] && [ ! -f "$PLAYIT_CLAIM_FILE" ]; then
        echo "[$(date '+%H:%M:%S')] [MINEHOST] WARN: playit nao conectou em 60s — verifique o dashboard playit.gg" >> "$LOG"
      fi

      # If claim pending, keep watching for tunnel address until playit exits
      if [ -f "$PLAYIT_CLAIM_FILE" ]; then
        while kill -0 $PLAYIT_PID 2>/dev/null; do
          sleep 3
          ADDR=$(_playit_extract_addr "$PLAYIT_LOG")
          if [ -n "$ADDR" ]; then
            echo "$ADDR" > "$SERVER_IP_FILE"
            rm -f "$PLAYIT_CLAIM_FILE"
            echo "[$(date '+%H:%M:%S')] [MINEHOST] playit tunnel ativo: $ADDR" >> "$LOG"
            tmux send-keys -t mc "say [MineHost] Endereco: $ADDR" C-m 2>/dev/null || true
            break
          fi
        done
      fi

      wait $PLAYIT_PID 2>/dev/null
      rm -f "$SERVER_IP_FILE"
      echo "[$(date '+%H:%M:%S')] [MINEHOST] playit tunnel dropped — reconnecting in 5s..." >> "$LOG"
      sleep 5
    done
  ) &

elif [ -f "$PLAYIT_BIN" ]; then
  # ── Fluxo B: sem token — aguarda claim do usuário para ativar túnel ──────────
  log "Starting playit.gg tunnel (unauthenticated — waiting for claim)..."
  PLAYIT_LOG="$SCRIPT_DIR/.playit.log"
  (
    while true; do
      rm -f "$SERVER_IP_FILE" "$PLAYIT_CLAIM_FILE"
      > "$PLAYIT_LOG"
      "$PLAYIT_BIN" > "$PLAYIT_LOG" 2>&1 &
      PLAYIT_PID=$!

      # Phase 1: wait up to 60s for claim URL or direct tunnel address
      TUNNELED=false
      for i in $(seq 1 60); do
        sleep 1
        ADDR=$(_playit_extract_addr "$PLAYIT_LOG")
        if [ -n "$ADDR" ]; then
          echo "$ADDR" > "$SERVER_IP_FILE"
          rm -f "$PLAYIT_CLAIM_FILE"
          echo "[$(date '+%H:%M:%S')] [MINEHOST] playit tunnel: $ADDR" >> "$LOG"
          tmux send-keys -t mc "say [MineHost] Endereco: $ADDR" C-m 2>/dev/null || true
          TUNNELED=true
          break
        fi
        CLAIM_URL=$(grep -oP '(?:https?://)?playit\.gg/claim/[a-zA-Z0-9]+' "$PLAYIT_LOG" 2>/dev/null | head -1)
        if [ -n "$CLAIM_URL" ] && [ ! -f "$PLAYIT_CLAIM_FILE" ]; then
          [[ "$CLAIM_URL" != http* ]] && CLAIM_URL="https://$CLAIM_URL"
          echo "$CLAIM_URL" > "$PLAYIT_CLAIM_FILE"
          echo "[$(date '+%H:%M:%S')] [MINEHOST] playit claim URL: $CLAIM_URL" >> "$LOG"
          echo "[$(date '+%H:%M:%S')] [MINEHOST] Visite o link acima no painel MineHost para ativar o tunel" >> "$LOG"
        fi
      done

      if [ "$TUNNELED" = false ] && [ ! -f "$PLAYIT_CLAIM_FILE" ]; then
        echo "[$(date '+%H:%M:%S')] [MINEHOST] WARN: playit sem claim URL em 60s — reiniciando agente..." >> "$LOG"
      fi

      # Phase 2: if claim pending, keep watching until tunnel is established
      if [ "$TUNNELED" = false ] && [ -f "$PLAYIT_CLAIM_FILE" ]; then
        while kill -0 $PLAYIT_PID 2>/dev/null; do
          sleep 3
          ADDR=$(_playit_extract_addr "$PLAYIT_LOG")
          if [ -n "$ADDR" ]; then
            echo "$ADDR" > "$SERVER_IP_FILE"
            rm -f "$PLAYIT_CLAIM_FILE"
            echo "[$(date '+%H:%M:%S')] [MINEHOST] playit tunnel ativo: $ADDR" >> "$LOG"
            tmux send-keys -t mc "say [MineHost] Endereco: $ADDR" C-m 2>/dev/null || true
            break
          fi
        done
      fi

      wait $PLAYIT_PID 2>/dev/null
      rm -f "$SERVER_IP_FILE"
      echo "[$(date '+%H:%M:%S')] [MINEHOST] playit encerrou — reiniciando em 5s..." >> "$LOG"
      sleep 5
    done
  ) &

else
  # ── Bore fallback: playit indisponível ───────────────────────────────────────
  if [ ! -f "$BORE_BIN" ]; then
    log "Downloading bore TCP tunnel (playit unavailable)..."
    BORE_VER=$(curl -sL --connect-timeout 5 "https://api.github.com/repos/ekzhang/bore/releases/latest" \
      | grep '"tag_name"' | grep -oP 'v\K[0-9.]+' | head -1)
    BORE_VER="${BORE_VER:-0.5.0}"
    curl -sL "https://github.com/ekzhang/bore/releases/download/v${BORE_VER}/bore-v${BORE_VER}-x86_64-unknown-linux-musl.tar.gz" \
      | tar -xz -C "$SCRIPT_DIR" 2>/dev/null
    [ -f "$BORE_BIN" ] && chmod +x "$BORE_BIN" && log "bore $BORE_VER downloaded"
  fi

  if [ -f "$BORE_BIN" ]; then
    BORE_LOG="$SCRIPT_DIR/.bore.log"
    (
      LAST_BORE_PORT=""
      while true; do
        rm -f "$SERVER_IP_FILE"
        > "$BORE_LOG"

        PORT_ARG=""
        [ -n "$LAST_BORE_PORT" ] && PORT_ARG="--port $LAST_BORE_PORT"

        "$BORE_BIN" local 25565 --to bore.pub $PORT_ARG > "$BORE_LOG" 2>&1 &
        BORE_PID=$!

        for i in $(seq 1 20); do
          sleep 1
          ADDR=$(grep -oP 'bore\.pub:\d+' "$BORE_LOG" 2>/dev/null | head -1)
          if [ -n "$ADDR" ]; then
            NEW_PORT="${ADDR##*:}"
            echo "$ADDR" > "$SERVER_IP_FILE"
            if [ -n "$LAST_BORE_PORT" ] && [ "$NEW_PORT" != "$LAST_BORE_PORT" ]; then
              echo "[$(date '+%H:%M:%S')] [MINEHOST] Server IP changed: $ADDR — players can connect!" >> "$LOG"
              tmux send-keys -t mc "say [MineHost] Endereco atualizado: $ADDR — reconecte-se!" C-m 2>/dev/null || true
            else
              echo "[$(date '+%H:%M:%S')] [MINEHOST] Server IP: $ADDR — players can connect!" >> "$LOG"
            fi
            LAST_BORE_PORT="$NEW_PORT"
            break
          fi
        done

        [ ! -f "$SERVER_IP_FILE" ] && \
          echo "[$(date '+%H:%M:%S')] [MINEHOST] WARN: bore did not connect in 20s — retrying..." >> "$LOG"

        wait $BORE_PID 2>/dev/null
        rm -f "$SERVER_IP_FILE"
        echo "[$(date '+%H:%M:%S')] [MINEHOST] bore tunnel dropped — reconnecting in 2s..." >> "$LOG"
        sleep 2
      done
    ) &
  else
    log "bore not available — no TCP tunnel (players cannot connect externally)"
  fi
fi

# Keep script alive
tail -f "$LOG"

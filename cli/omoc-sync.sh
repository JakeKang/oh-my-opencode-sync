#!/usr/bin/env bash
set -euo pipefail

# oh-my-opencode-sync (CLI)
# - Safe, read-only path detection (NO opencode doctor)
# - XDG first (macOS/Linux), macOS Library fallback, Windows AppData fallback
# - Env override supported
# - Full/Selective backup & restore
# - Refuses "meta-only" archives
# - Safe restore mode (backs up existing targets before overwrite)
# - Progress + elapsed time for backup/restore (step-based, optional tar progress via pv if available)

APP="oh-my-opencode-sync (CLI)"
ARCHIVE_PREFIX="omoc-snapshot"
OS="$(uname)"
HOME_DIR="${HOME}"
MODE="${1:-}"  # --diag | --dry-run | (empty)

# ----------------------------
# Helpers
# ----------------------------
ts() { date +"%Y%m%d-%H%M%S"; }
now_s() { date +%s; }

pick_first_existing() {
  for p in "$@"; do
    if [ -n "${p:-}" ] && [ -d "$p" ]; then
      echo "$p"
      return 0
    fi
  done
  echo "${1:-}"
}

copy_dir_contents() {
  local SRC="$1"
  local DST="$2"
  mkdir -p "$DST"
  cp -R "$SRC"/. "$DST"/
}

dir_size_bytes() {
  local P="$1"
  if [ -d "$P" ]; then
    # mac: -sk works too; use -sk for portability, convert to bytes
    local kb
    kb="$(du -sk "$P" 2>/dev/null | awk '{print $1}' || echo 0)"
    echo $((kb * 1024))
  else
    echo 0
  fi
}

dir_size_h() {
  local P="$1"
  if [ -d "$P" ]; then
    du -sh "$P" 2>/dev/null | awk '{print $1}' || echo "?"
  else
    echo "-"
  fi
}

fmt_elapsed() {
  local s="$1"
  local m=$((s/60))
  local r=$((s%60))
  printf "%dm%02ds" "$m" "$r"
}

progress_step() {
  local cur="$1"
  local total="$2"
  local label="$3"
  printf "\r[%d/%d] %s" "$cur" "$total" "$label"
}


# ----------------------------
# Optional deps installer (pv)
# ----------------------------
install_optional_deps() {
  echo ""
  echo "Optional dependency: pv (shows tar progress)"
  if command -v pv >/dev/null 2>&1; then
    echo "✅ pv already installed: $(command -v pv)"
    return 0
  fi

  echo "pv not found."
  read -r -p "Install pv now? [Y/n]: " ANS || true
  case "${ANS:-Y}" in
    n|N) echo "Skipping."; return 0 ;;
  esac

  if [[ "$OS" == "Darwin" ]]; then
    if ! command -v brew >/dev/null 2>&1; then
      echo "❌ Homebrew not found. Install Homebrew first, then run: brew install pv"
      return 1
    fi
    echo "Running: brew install pv"
    brew install pv
    return $?
  fi

  if [[ "$OS" == "Linux" ]]; then
    if command -v apt-get >/dev/null 2>&1; then
      echo "Running: sudo apt-get update && sudo apt-get install -y pv"
      sudo apt-get update
      sudo apt-get install -y pv
      return $?
    elif command -v dnf >/dev/null 2>&1; then
      echo "Running: sudo dnf install -y pv"
      sudo dnf install -y pv
      return $?
    elif command -v yum >/dev/null 2>&1; then
      echo "Running: sudo yum install -y pv"
      sudo yum install -y pv
      return $?
    elif command -v pacman >/dev/null 2>&1; then
      echo "Running: sudo pacman -S --noconfirm pv"
      sudo pacman -S --noconfirm pv
      return $?
    elif command -v zypper >/dev/null 2>&1; then
      echo "Running: sudo zypper install -y pv"
      sudo zypper install -y pv
      return $?
    else
      echo "❌ No supported package manager found."
      echo "Install pv manually (examples):"
      echo "  - Debian/Ubuntu: sudo apt-get install pv"
      echo "  - Fedora: sudo dnf install pv"
      echo "  - Arch: sudo pacman -S pv"
      return 1
    fi
  fi

  # Windows Git Bash/MSYS
  if [[ "$OS" == MINGW* || "$OS" == CYGWIN* || "$OS" == MSYS* ]]; then
    echo "Windows shell detected."
    echo "If you use MSYS2, install with:"
    echo "  pacman -S pv"
    echo "If you use Chocolatey (PowerShell):"
    echo "  choco install pv"
    return 0
  fi

  echo "Unsupported OS for auto-install. Please install pv manually."
  return 1
}

# ----------------------------
# XDG base dirs (works on macOS too)
# ----------------------------
XDG_CFG_BASE="${XDG_CONFIG_HOME:-$HOME_DIR/.config}"
XDG_DATA_BASE="${XDG_DATA_HOME:-$HOME_DIR/.local/share}"
XDG_CACHE_BASE="${XDG_CACHE_HOME:-$HOME_DIR/.cache}"

# ----------------------------
# Detect paths (NO opencode doctor usage)
# ----------------------------
CONFIG=""
DATA=""
CACHE=""

# 1) Env override (highest priority)
if [ -n "${OPENCODE_CONFIG_DIR:-}" ]; then CONFIG="$OPENCODE_CONFIG_DIR"; fi
if [ -n "${OPENCODE_DATA_DIR:-}" ]; then DATA="$OPENCODE_DATA_DIR"; fi
if [ -n "${OPENCODE_CACHE_DIR:-}" ]; then CACHE="$OPENCODE_CACHE_DIR"; fi

# 2) XDG defaults (if not overridden)
if [ -z "${CONFIG:-}" ]; then CONFIG="${XDG_CFG_BASE}/opencode"; fi
if [ -z "${DATA:-}" ]; then DATA="${XDG_DATA_BASE}/opencode"; fi
if [ -z "${CACHE:-}" ]; then CACHE="${XDG_CACHE_BASE}/opencode"; fi

# 3) macOS fallback
if [[ "$OS" == "Darwin" ]]; then
  MAC_BASE="$HOME_DIR/Library/Application Support"
  MAC_CBASE="$HOME_DIR/Library/Caches"
  if [ ! -d "$CONFIG" ]; then
    CONFIG="$(pick_first_existing "$MAC_BASE/opencode" "$MAC_BASE/OpenCode" "$MAC_BASE/oh-my-opencode" "$CONFIG")"
  fi
  if [ ! -d "$DATA" ]; then
    DATA="$(pick_first_existing "$MAC_BASE/opencode" "$MAC_BASE/OpenCode" "$MAC_BASE/oh-my-opencode" "$DATA")"
  fi
  if [ ! -d "$CACHE" ]; then
    CACHE="$(pick_first_existing "$MAC_CBASE/opencode" "$MAC_CBASE/OpenCode" "$MAC_CBASE/oh-my-opencode" "$CACHE")"
  fi
fi

# 4) Windows fallback (Git Bash/MSYS/Cygwin)
if [[ "$OS" == MINGW* || "$OS" == CYGWIN* || "$OS" == MSYS* ]]; then
  if [ ! -d "$CONFIG" ]; then
    CONFIG="$(pick_first_existing "${APPDATA:-}/opencode" "${APPDATA:-}/OpenCode" "${APPDATA:-}/oh-my-opencode" "$CONFIG")"
  fi
  if [ ! -d "$DATA" ]; then
    DATA="$(pick_first_existing "${APPDATA:-}/opencode" "${APPDATA:-}/OpenCode" "${APPDATA:-}/oh-my-opencode" "$DATA")"
  fi
  if [ ! -d "$CACHE" ]; then
    CACHE="$(pick_first_existing "${LOCALAPPDATA:-}/opencode/Cache" "${LOCALAPPDATA:-}/OpenCode/Cache" "${LOCALAPPDATA:-}/oh-my-opencode/Cache" "${LOCALAPPDATA:-}/opencode" "$CACHE")"
  fi
fi

WORKSPACE_OPENCODE=""
if [ -d ".opencode" ]; then
  WORKSPACE_OPENCODE="$(pwd)/.opencode"
fi

show_detected() {
  echo "Detected:"
  echo " - config : ${CONFIG:-<empty>} $([ -n "${CONFIG:-}" ] && [ -d "$CONFIG" ] && echo "(exists, $(dir_size_h "$CONFIG"))" || echo "(missing)")"
  echo " - data   : ${DATA:-<empty>}   $([ -n "${DATA:-}" ] && [ -d "$DATA" ] && echo "(exists, $(dir_size_h "$DATA"))" || echo "(missing)")"
  echo " - cache  : ${CACHE:-<empty>}  $([ -n "${CACHE:-}" ] && [ -d "$CACHE" ] && echo "(exists, $(dir_size_h "$CACHE"))" || echo "(missing)")"
  echo " - workspace .opencode: ${WORKSPACE_OPENCODE:-<none>} $([ -n "${WORKSPACE_OPENCODE:-}" ] && echo "(exists, $(dir_size_h "$WORKSPACE_OPENCODE"))" || echo "(missing)")"
  echo ""
  echo "XDG base:"
  echo " - XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-<default:$HOME_DIR/.config>}"
  echo " - XDG_DATA_HOME=${XDG_DATA_HOME:-<default:$HOME_DIR/.local/share>}"
  echo " - XDG_CACHE_HOME=${XDG_CACHE_HOME:-<default:$HOME_DIR/.cache>}"
  echo ""
  echo "Override (optional, highest priority):"
  echo "  OPENCODE_CONFIG_DIR=... OPENCODE_DATA_DIR=... OPENCODE_CACHE_DIR=..."
}

# ----------------------------
# Backup
# ----------------------------
do_backup() {
  local INC_CONFIG="$1"
  local INC_DATA="$2"
  local INC_CACHE="$3"
  local INC_WS="$4"

  local start
  start="$(now_s)"

  local T TMP OUT
  T="$(ts)"
  TMP="${ARCHIVE_PREFIX}-${T}"
  OUT="${ARCHIVE_PREFIX}-${T}.tar.gz"

  mkdir -p "$TMP"
  local added=0
  local steps_total=0
  [[ "$INC_CONFIG" == "1" && -d "$CONFIG" ]] && steps_total=$((steps_total+1))
  [[ "$INC_DATA" == "1" && -d "$DATA" ]] && steps_total=$((steps_total+1))
  [[ "$INC_CACHE" == "1" && -d "$CACHE" ]] && steps_total=$((steps_total+1))
  [[ "$INC_WS" == "1" && -d ".opencode" ]] && steps_total=$((steps_total+1))
  steps_total=$((steps_total+2))  # meta + tar
  local step=0

  if [[ "$INC_CONFIG" == "1" && -d "$CONFIG" ]]; then
    step=$((step+1)); progress_step "$step" "$steps_total" "Copying config..."
    copy_dir_contents "$CONFIG" "$TMP/config"
    added=1
  fi
  if [[ "$INC_DATA" == "1" && -d "$DATA" ]]; then
    step=$((step+1)); progress_step "$step" "$steps_total" "Copying data..."
    copy_dir_contents "$DATA" "$TMP/data"
    added=1
  fi
  if [[ "$INC_CACHE" == "1" && -d "$CACHE" ]]; then
    step=$((step+1)); progress_step "$step" "$steps_total" "Copying cache..."
    copy_dir_contents "$CACHE" "$TMP/cache"
    added=1
  fi
  if [[ "$INC_WS" == "1" && -d ".opencode" ]]; then
    step=$((step+1)); progress_step "$step" "$steps_total" "Copying workspace .opencode..."
    mkdir -p "$TMP/workspace/.opencode"
    copy_dir_contents ".opencode" "$TMP/workspace/.opencode"
    added=1
  fi

  step=$((step+1)); progress_step "$step" "$steps_total" "Writing meta.json..."
  cat > "$TMP/meta.json" <<EOF
{
  "tool":"oh-my-opencode-sync",
  "created":"$T",
  "os":"$OS",
  "host":"$(hostname)",
  "cwd":"$(pwd)",
  "xdg":{
    "config_home":"${XDG_CONFIG_HOME:-$HOME_DIR/.config}",
    "data_home":"${XDG_DATA_HOME:-$HOME_DIR/.local/share}",
    "cache_home":"${XDG_CACHE_HOME:-$HOME_DIR/.cache}"
  },
  "detected_paths":{
    "config":"$CONFIG",
    "data":"$DATA",
    "cache":"$CACHE",
    "workspace_opencode":"${WORKSPACE_OPENCODE:-}"
  }
}
EOF

  if [[ "$added" != "1" ]]; then
    echo ""
    rm -rf "$TMP"
    echo "❌ No backup targets found. (Only meta would be created, refusing)"
    show_detected
    echo ""
    echo "Fix:"
    echo "  1) Ensure opencode has created its storage directories (run opencode at least once)."
    echo "  2) If your opencode uses XDG, verify the XDG_* vars above."
    echo "  3) Or set OPENCODE_*_DIR env vars to the real directories."
    echo "  4) Or run inside a project folder that has .opencode/ for workspace backup."
    exit 1
  fi

  if [[ "$MODE" == "--dry-run" ]]; then
    echo ""
    echo "🟡 DRY-RUN: would create $OUT with:"
    [ -d "$TMP/config" ] && echo " - config/"
    [ -d "$TMP/data" ] && echo " - data/"
    [ -d "$TMP/cache" ] && echo " - cache/"
    [ -d "$TMP/workspace/.opencode" ] && echo " - workspace/.opencode/"
    echo " - meta.json"
    rm -rf "$TMP"
    exit 0
  fi

  step=$((step+1)); progress_step "$step" "$steps_total" "Creating tar.gz..."
  # Optional progress: if pv exists, pipe tar output
  if command -v pv >/dev/null 2>&1; then
    # Estimate size from tmp dir
    local total_bytes
    total_bytes="$(dir_size_bytes "$TMP")"
    tar -cf - "$TMP" | pv -s "$total_bytes" | gzip > "$OUT"
  else
    tar -czf "$OUT" "$TMP"
  fi

  rm -rf "$TMP"
  local end elapsed
  end="$(now_s)"
  elapsed=$((end - start))
  echo ""
  echo "✅ Backup created: $OUT (elapsed: $(fmt_elapsed "$elapsed"))"
  echo "Verify: tar -tzf \"$OUT\" | head -80"
}

# ----------------------------
# Restore (with Safe Mode)
# ----------------------------
do_restore() {
  local FILE="$1"
  local INC_CONFIG="$2"
  local INC_DATA="$3"
  local INC_CACHE="$4"
  local INC_WS="$5"
  local SAFE_MODE="$6"  # 1 or 0

  local start
  start="$(now_s)"

  if [ ! -f "$FILE" ]; then
    echo "File not found: $FILE"
    exit 1
  fi

  # Determine extracted root dir name
  local ROOTDIR
  ROOTDIR="$(tar -tf "$FILE" | head -1 | cut -f1 -d"/")"
  if [ -z "${ROOTDIR:-}" ]; then
    echo "Invalid archive (no root dir): $FILE"
    exit 1
  fi

  local steps_total=4
  [[ "$INC_CONFIG" == "1" ]] && steps_total=$((steps_total+1))
  [[ "$INC_DATA" == "1" ]] && steps_total=$((steps_total+1))
  [[ "$INC_CACHE" == "1" ]] && steps_total=$((steps_total+1))
  [[ "$INC_WS" == "1" ]] && steps_total=$((steps_total+1))
  local step=0

  # Safe mode backup folder
  local SAFEDIR=""
  if [[ "$SAFE_MODE" == "1" ]]; then
    SAFEDIR=".omoc-safe-restore-$(ts)"
  fi

  step=$((step+1)); progress_step "$step" "$steps_total" "Extracting archive..."
  tar -xzf "$FILE"

  # helper: safe backup existing dir before overwrite
  safe_backup_existing() {
    local TARGET="$1"
    local LABEL="$2"
    if [[ "$SAFE_MODE" == "1" && -e "$TARGET" ]]; then
      mkdir -p "$SAFEDIR"
      local base
      base="$(basename "$TARGET")"
      local dst="$SAFEDIR/${LABEL}-${base}"
      # Move is fast and preserves permissions; creates rollback point
      mv "$TARGET" "$dst"
    else
      rm -rf "$TARGET"
    fi
  }

  # Restore per component
  if [[ "$INC_CONFIG" == "1" && -d "$ROOTDIR/config" ]]; then
    step=$((step+1)); progress_step "$step" "$steps_total" "Restoring config..."
    mkdir -p "$(dirname "$CONFIG")"
    safe_backup_existing "$CONFIG" "config"
    mv "$ROOTDIR/config" "$CONFIG"
  fi
  if [[ "$INC_DATA" == "1" && -d "$ROOTDIR/data" ]]; then
    step=$((step+1)); progress_step "$step" "$steps_total" "Restoring data..."
    mkdir -p "$(dirname "$DATA")"
    safe_backup_existing "$DATA" "data"
    mv "$ROOTDIR/data" "$DATA"
  fi
  if [[ "$INC_CACHE" == "1" && -d "$ROOTDIR/cache" ]]; then
    step=$((step+1)); progress_step "$step" "$steps_total" "Restoring cache..."
    mkdir -p "$(dirname "$CACHE")"
    safe_backup_existing "$CACHE" "cache"
    mv "$ROOTDIR/cache" "$CACHE"
  fi
  if [[ "$INC_WS" == "1" && -d "$ROOTDIR/workspace/.opencode" ]]; then
    step=$((step+1)); progress_step "$step" "$steps_total" "Restoring workspace .opencode..."
    safe_backup_existing ".opencode" "workspace"
    mv "$ROOTDIR/workspace/.opencode" ".opencode"
  fi

  step=$((step+1)); progress_step "$step" "$steps_total" "Cleaning up..."
  rm -rf "$ROOTDIR"

  local end elapsed
  end="$(now_s)"
  elapsed=$((end - start))
  echo ""
  echo "✅ Restore completed (elapsed: $(fmt_elapsed "$elapsed"))"
  if [[ "$SAFE_MODE" == "1" ]]; then
    echo "🛡️  Safe restore backup saved at: $SAFEDIR"
    echo "    (Contains the previous directories moved aside before overwrite.)"
  fi
}

# ----------------------------
# Menu
# ----------------------------
menu_select() {
  echo "Select items (space separated):"
  echo "  1) config"
  echo "  2) data"
  echo "  3) cache"
  echo "  4) workspace .opencode"
  read -r -p "Enter (e.g. 1 2 4): " CHOICES || true
  local c=0 d=0 ca=0 w=0
  for n in $CHOICES; do
    case "$n" in
      1) c=1 ;;
      2) d=1 ;;
      3) ca=1 ;;
      4) w=1 ;;
    esac
  done
  if [[ "$c" == "0" && "$d" == "0" && "$ca" == "0" && "$w" == "0" ]]; then
    c=1; d=1
  fi
  echo "$c $d $ca $w"
}

ask_safe_mode() {
  read -r -p "Safe restore mode? (backs up existing targets) [Y/n]: " ANS || true
  case "${ANS:-Y}" in
    n|N) echo "0" ;;
    *) echo "1" ;;
  esac
}

if [[ "$MODE" == "--diag" ]]; then
  echo "====== $APP (DIAGNOSTIC) ======"
  show_detected
  echo ""
  echo "Quick checks:"
  echo "  ls -la \"${XDG_CFG_BASE}/opencode\""
  echo "  ls -la \"${XDG_DATA_BASE}/opencode\""
  echo "  ls -la \"${XDG_CACHE_BASE}/opencode\""
  if [[ "$OS" == "Darwin" ]]; then
    echo "  ls -la \"$HOME/Library/Application Support\" | egrep -i \"opencode|open.*code\""
    echo "  ls -la \"$HOME/Library/Caches\" | egrep -i \"opencode|open.*code\""
  fi
  exit 0
fi

while true; do
  echo ""
  echo "====== $APP ======"
  show_detected
  echo ""
  echo "1) Full Backup (config+data+cache+workspace)"
  echo "2) Full Restore (config+data+cache+workspace) [SAFE MODE]"
  echo "3) Selective Backup"
  echo "4) Selective Restore [SAFE MODE]"
  echo "9) Install optional deps (pv)"
  echo "0) Exit"
  read -r -p "Choose: " MENU || true

  case "${MENU:-}" in
    1) do_backup 1 1 1 1 ;;
    2)
      read -r -p "Backup tar.gz path: " FILE
      SAFE="$(ask_safe_mode)"
      do_restore "$FILE" 1 1 1 1 "$SAFE"
      ;;
    3)
      read -r c d ca w < <(menu_select)
      do_backup "$c" "$d" "$ca" "$w"
      ;;
    4)
      read -r -p "Backup tar.gz path: " FILE
      read -r c d ca w < <(menu_select)
      SAFE="$(ask_safe_mode)"
      do_restore "$FILE" "$c" "$d" "$ca" "$w" "$SAFE"
      ;;
    9) install_optional_deps ;;
    0) exit 0 ;;
  esac
done

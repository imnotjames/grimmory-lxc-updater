#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: MickLesk (CanbiZ)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/grimmory-tools/grimmory
# Modified by dalenjohnson. Forked by databoy2k for Grimmory 3.x

APP="Grimmory"
var_tags="${var_tags:-books;library}"
var_cpu="${var_cpu:-3}"
var_ram="${var_ram:-6144}"
var_disk="${var_disk:-10}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors


function normalize_grimmory_release() {
  local release
  release="$(get_latest_github_release "grimmory-tools/grimmory")"
  release="${release#v}"

  if [[ -z "$release" ]]; then
    msg_error "Unable to determine the latest Grimmory release"
    return 1
  fi

  GRIMMORY_VERSION="v${release}"
  GRIMMORY_VERSION_CLEAN="${release}"
  GRIMMORY_REVISION="unknown"
}

function setup_libarchive_link() {
  local LIBARCHIVE_TARGET=""
  local CANDIDATE

  for CANDIDATE in \
    /usr/lib/*/libarchive.so.13 \
    /lib/*/libarchive.so.13 \
    /usr/lib/libarchive.so.13; do
    if [[ -e "$CANDIDATE" ]]; then
      LIBARCHIVE_TARGET="$CANDIDATE"
      break
    fi
  done

  if [[ -z "$LIBARCHIVE_TARGET" ]]; then
    msg_error "libarchive.so.13 was not found after installing libarchive13"
    return 1
  fi

  mkdir -p /usr/lib
  if [[ -e /usr/lib/libarchive.so && ! -L /usr/lib/libarchive.so ]]; then
    msg_warn "/usr/lib/libarchive.so already exists and is not a symlink; leaving it unchanged"
  elif [[ ! -e /usr/lib/libarchive.so ]]; then
    ln -s "$LIBARCHIVE_TARGET" /usr/lib/libarchive.so
  fi
}

function ensure_env_kv() {
  local FILE="$1"
  local KEY="$2"
  local VALUE="$3"

  mkdir -p "$(dirname "$FILE")"
  touch "$FILE"

  if grep -qE "^${KEY}=" "$FILE"; then
    sed -i "s|^${KEY}=.*|${KEY}=${VALUE}|" "$FILE"
  else
    echo "${KEY}=${VALUE}" >> "$FILE"
  fi
}

function upsert_service_line() {
  local FILE="$1"
  local MATCH_REGEX="$2"
  local LINE="$3"
  local TMP

  if ! grep -q '^\[Service\]$' "$FILE"; then
    msg_error "Unable to update $FILE: missing [Service] section"
    return 1
  fi

  TMP="$(mktemp)"
  awk -v regex="$MATCH_REGEX" -v line="$LINE" '
    BEGIN { in_service=0; added=0 }
    /^\[Service\]$/ {
      print
      if (!added) {
        print line
        added=1
      }
      in_service=1
      next
    }
    /^\[/ { in_service=0 }
    in_service && $0 ~ regex { next }
    { print }
  ' "$FILE" > "$TMP"
  cat "$TMP" > "$FILE"
  rm -f "$TMP"
}


function run_long_command() {
  local NAME="$1"
  shift
  local LOG_FILE="/tmp/grimmory-${NAME}.log"
  local PID
  local RC
  local OLD_HUP_TRAP
  local OLD_ERREXIT="off"

  msg_info "Running ${NAME} (log: ${LOG_FILE})"
  rm -f "$LOG_FILE"

  # community-scripts installs a SIGHUP trap. Angular builds can be quiet for long
  # stretches, and in some LXC/helper contexts the child process gets HUP'd before
  # it can print a real build error. Ignore HUP only while this long command runs.
  OLD_HUP_TRAP="$(trap -p HUP || true)"
  case "$-" in
    *e*) OLD_ERREXIT="on" ;;
  esac

  trap '' HUP

  (
    trap '' HUP
    echo "[$(date -Is)] Command: $*"
    echo "[$(date -Is)] MemTotal: $(awk '/^MemTotal:/ {printf "%d MB", $2/1024}' /proc/meminfo 2>/dev/null || true)"
    echo "[$(date -Is)] SwapTotal: $(awk '/^SwapTotal:/ {printf "%d MB", $2/1024}' /proc/meminfo 2>/dev/null || true)"
    echo "[$(date -Is)] Disk free at /opt/grimmory: $(df -h /opt/grimmory 2>/dev/null | awk 'NR==2 {print $4 " free of " $2}' || true)"
    exec nohup "$@" </dev/null
  ) >"$LOG_FILE" 2>&1 &
  PID=$!

  while kill -0 "$PID" >/dev/null 2>&1; do
    sleep 15
    echo -n "."
  done
  echo

  # Do not let set -e / ERR trap short-circuit our log printing.
  set +e
  wait "$PID"
  RC=$?
  if [[ "$OLD_ERREXIT" == "on" ]]; then
    set -e
  fi

  if [[ -n "$OLD_HUP_TRAP" ]]; then
    eval "$OLD_HUP_TRAP"
  else
    trap - HUP
  fi

  if [[ "$RC" -ne 0 ]]; then
    msg_warn "${NAME} failed with exit code ${RC}; showing the last 200 log lines"
    tail -n 200 "$LOG_FILE" || true
    return "$RC"
  fi

  msg_ok "${NAME} completed"
}

function setup_kepubify() {
  local OLD_PATH="/opt/booklore_storage/data/tools/kepubify"
  local NEW_PATH="/usr/local/bin/kepubify"
  local ARCH
  local URL

  ARCH="$(dpkg --print-architecture)"
  case "$ARCH" in
    amd64) URL="https://github.com/pgaskin/kepubify/releases/latest/download/kepubify-linux-64bit" ;;
    arm64) URL="https://github.com/pgaskin/kepubify/releases/latest/download/kepubify-linux-arm64" ;;
    *)
      msg_error "Unsupported architecture: $ARCH"
      return 1
      ;;
  esac

  mkdir -p /usr/local/bin

  # Fail clearly if a previous bad install created a directory here
  if [[ -d "$NEW_PATH" ]]; then
    msg_error "Invalid kepubify install detected at $NEW_PATH. It is a directory, not a binary."
    return 1
  fi

  # Migrate from old location if present and valid
  if [[ -f "$OLD_PATH" && -x "$OLD_PATH" && ! -f "$NEW_PATH" ]]; then
    if "$OLD_PATH" --help >/dev/null 2>&1; then
      msg_info "Migrating kepubify to /usr/local/bin"
      mv "$OLD_PATH" "$NEW_PATH"
      chmod 0755 "$NEW_PATH"
    else
      msg_warn "Skipping migration: invalid kepubify binary at $OLD_PATH"
    fi
  fi

  # If not installed → ask user
  if [[ -f "$NEW_PATH" ]]; then
    msg_info "Updating Kepubify"
  else
    if command -v whiptail >/dev/null 2>&1; then
      if ! whiptail \
        --backtitle "Proxmox VE Helper Scripts" \
        --title "KEPUBIFY" \
        --yesno "Kepubify not found.\n\nInstall it for Kobo Sync support?" 10 60; then
        msg_info "Skipping Kepubify"
        return 0
      fi
    else
      read -r -p "Kepubify not found. Install it? [y/N]: " reply
      [[ "$reply" =~ ^[Yy]$ ]] || return 0
    fi
    msg_info "Installing Kepubify"
  fi

  # Download latest
  if ! wget -q "$URL" -O /tmp/kepubify; then
    msg_error "Failed to download Kepubify"
    return 1
  fi

  # Install
  if ! install -m 0755 -T /tmp/kepubify "$NEW_PATH"; then
    rm -f /tmp/kepubify
    msg_error "Failed to install Kepubify"
    return 1
  fi

  rm -f /tmp/kepubify

  if [[ ! -f "$NEW_PATH" || ! -x "$NEW_PATH" ]]; then
    msg_error "Kepubify install verification failed: binary missing or not executable"
    return 1
  fi

  if ! command -v kepubify >/dev/null 2>&1; then
    msg_error "Kepubify install verification failed: not found in PATH"
    return 1
  fi

  msg_ok "Kepubify ready"
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  # Installation check (Bypassed for repair):
  # if [[ ! -d /opt/booklore && ! -d /opt/grimmory ]]; then
  #   msg_error "No BookLore or ${APP} Installation Found!"
  #   exit
  # fi

  # --- FORCE REINSTALL ENABLED ---
  JAVA_VERSION="25"
  setup_java
  NODE_VERSION="24"
  setup_nodejs
  setup_mariadb
  setup_yq
  ensure_dependencies ffmpeg libarchive13
  setup_kepubify
  
  # Grimmory 3.x native archive support expects libarchive.so to resolve.
  setup_libarchive_link

  EXISTING_BOOKLORE_PORT="$(grep -E '^BOOKLORE_PORT=' /opt/booklore_storage/.env 2>/dev/null | tail -n1 | cut -d= -f2- || true)"

  # Resolve the release once and use it for download, build metadata, and systemd runtime metadata.
  normalize_grimmory_release

  # Service stop:
  msg_info "Stopping Service"
  if [[ -d /opt/grimmory ]]; then
    systemctl stop grimmory || true
  else
    systemctl stop booklore || true
  fi
  msg_ok "Stopped Service"

  # Env var migration:
  if grep -qE "^BOOKLORE_(DATA_PATH|BOOKDROP_PATH|BOOKS_PATH|PORT)=" /opt/booklore_storage/.env 2>/dev/null; then
    msg_info "Migrating old environment variables"
    sed -i 's/^BOOKLORE_DATA_PATH=/APP_PATH_CONFIG=/g' /opt/booklore_storage/.env
    sed -i 's/^BOOKLORE_BOOKDROP_PATH=/APP_BOOKDROP_FOLDER=/g' /opt/booklore_storage/.env
    sed -i '/^BOOKLORE_BOOKS_PATH=/d' /opt/booklore_storage/.env
    sed -i '/^BOOKLORE_PORT=/d' /opt/booklore_storage/.env
    msg_ok "Migrated old environment variables"
  fi

  # Backup:
  msg_info "Backing up old installation"
  rm -rf /opt/grimmory_bak /opt/booklore_bak
  if [[ -d /opt/booklore ]]; then
    mv /opt/booklore /opt/booklore_bak
  elif [[ -d /opt/grimmory ]]; then
    cp -a /opt/grimmory /opt/grimmory_bak
  fi
  msg_ok "Backed up old installation"

  # Wipe existing grimmory dir before fresh deploy
  msg_info "Downloading fresh source code (${GRIMMORY_VERSION})"
  rm -rf /opt/grimmory
  mkdir -p /opt/grimmory

  # Fetch the latest jar file
  JAR_PATH=$(mktemp)

  JAR_URL="https://github.com/grimmory-tools/grimmory/releases/download/${GRIMMORY_VERSION}/grimmory.jar"
  curl -fsSL "${JAR_URL}" -o "${JAR_PATH}"

  if [[ -z "$JAR_PATH" ]]; then
    msg_error "Backend JAR not found"
    exit
  fi
  cp "$JAR_PATH" /opt/grimmory/dist/app.jar
  msg_ok "Built Backend"

  # Nginx removal:
  if systemctl is-active --quiet nginx 2>/dev/null; then
    msg_info "Removing Nginx (no longer needed)"
    systemctl disable --now nginx >/dev/null 2>&1 || true
    $STD apt-get purge -y nginx nginx-common
    msg_ok "Removed Nginx"
  fi

  # Grimmory still reads BOOKLORE_PORT in application.yaml.
  ensure_env_kv /opt/booklore_storage/.env BOOKLORE_PORT "${EXISTING_BOOKLORE_PORT:-6060}"

  if [[ -f /etc/systemd/system/booklore.service && ! -f /etc/systemd/system/grimmory.service ]]; then
    mv /etc/systemd/system/booklore.service /etc/systemd/system/grimmory.service
  fi

  # Service file migration:
  if [[ ! -f /etc/systemd/system/grimmory.service ]]; then
    msg_error "grimmory.service not found"
    exit
  fi

  JAVA_TOOL_OPTIONS="-XX:+UseShenandoahGC -XX:ShenandoahGCHeuristics=compact -XX:+UseCompactObjectHeaders -XX:MaxRAMPercentage=60.0 -XX:InitialRAMPercentage=8.0 -XX:+ExitOnOutOfMemoryError -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/tmp/heapdump.hprof -XX:MaxMetaspaceSize=256m -XX:ReservedCodeCacheSize=48m -Xss512k -XX:CICompilerCount=2 -XX:+UnlockExperimentalVMOptions -XX:+UseStringDeduplication -XX:ShenandoahUncommitDelay=5000 -XX:ShenandoahGuaranteedGCInterval=30000 -XX:MaxDirectMemorySize=256m --enable-native-access=ALL-UNNAMED --enable-preview"

  upsert_service_line /etc/systemd/system/grimmory.service '^EnvironmentFile=.*booklore_storage/\.env' 'EnvironmentFile=-/opt/booklore_storage/.env'
  SERVICE_APP_VERSION_LINE="Environment=\"APP_VERSION=${GRIMMORY_VERSION}\""
  SERVICE_APP_REVISION_LINE="Environment=\"APP_REVISION=${GRIMMORY_REVISION}\""
  SERVICE_JAVA_TOOL_OPTIONS_LINE="Environment=\"JAVA_TOOL_OPTIONS=${JAVA_TOOL_OPTIONS}\""

  upsert_service_line /etc/systemd/system/grimmory.service '^Environment="?APP_VERSION=' "$SERVICE_APP_VERSION_LINE"
  upsert_service_line /etc/systemd/system/grimmory.service '^Environment="?APP_REVISION=' "$SERVICE_APP_REVISION_LINE"
  upsert_service_line /etc/systemd/system/grimmory.service '^Environment="?JAVA_TOOL_OPTIONS=' "$SERVICE_JAVA_TOOL_OPTIONS_LINE"
  upsert_service_line /etc/systemd/system/grimmory.service '^WorkingDirectory=' 'WorkingDirectory=/opt/grimmory/dist'
  upsert_service_line /etc/systemd/system/grimmory.service '^ExecStart=' 'ExecStart=/usr/bin/java --enable-native-access=ALL-UNNAMED --enable-preview -jar /opt/grimmory/dist/app.jar'
  systemctl daemon-reload
  systemctl disable --now booklore.service >/dev/null 2>&1 || true

  # Start + cleanup:
  msg_info "Starting Service"
  systemctl enable --now grimmory.service

  sleep 2
  if ! systemctl is-active --quiet grimmory.service; then
    journalctl -u grimmory.service -n 80 --no-pager || true
    msg_error "Grimmory service failed to start. Backups were retained."
    exit 1
  fi

  rm -rf /opt/grimmory_bak /opt/booklore_bak
  msg_ok "Started Service"
  msg_ok "Updated successfully!"
  exit
}

start
build_container
description
update_script "$@"

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:6060${CL}"

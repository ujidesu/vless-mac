#!/bin/bash

# ----- VARIABLES -----
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_PATH="/opt/homebrew/etc/xray/config.json"
PROXY_HOST="127.0.0.1"
PROXY_PORT="1080"
INTERFACES=()
CONFIGURED_INTERFACES=()
# Relative paths are for people who enjoy debugging from the wrong directory.
INI_FILE="${SCRIPT_DIR}/config.ini"

# ----- COLORS -----
RED="\033[0;31m"
GREEN="\033[0;32m"
BLUE="\033[0;34m"
NC="\033[0m"
YELLOW="\033[1;33m"

# ----- METHODS -----
log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"; }
ok()   { echo -e "${GREEN}✔ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
err()  { echo -e "${RED}✖ $1${NC}"; }

ask() {
  local prompt="$1"
  local var_name="$2"
  local default="${3:-}"

  if [ -n "$default" ]; then
    if [ "$default" -eq 1 ]; then
      echo -n "${prompt} (y/n) [default: yes]: "
    else
      echo -n "${prompt} (y/n) [default: no]: "
    fi
  else
    echo -n "${prompt} (y/n): "
  fi

  read -r ANSWER < /dev/tty

  case "$ANSWER" in
    y|Y) eval "$var_name=1" ;;
    n|N) eval "$var_name=0" ;;
    "")
      if [ -n "$default" ]; then
        eval "$var_name=$default"
      else
        echo "Please enter y or n"
        ask "$prompt" "$var_name" "$default"
        return
      fi
      ;;
    *)
      echo "Please enter y or n"
      ask "$prompt" "$var_name" "$default"
      return
      ;;
  esac
}

is_service_exists() {
  networksetup -listallnetworkservices | tail -n +2 | grep -Fxq "$1"
}

load_network_services() {
  local service

  INTERFACES=()

  while IFS= read -r service; do
    [ -z "$service" ] && continue
    [[ "$service" == \** ]] && continue

    INTERFACES+=("$service")
  done < <(networksetup -listallnetworkservices | tail -n +2)
}

choose_from_list() {
  local prompt="$1"
  shift
  local options=("$@")
  local count="${#options[@]}"
  local choice

  if [ "$count" -eq 0 ]; then
    return 1
  fi

  if [ "$count" -eq 1 ]; then
    CHOSEN_INDEX=0
    return 0
  fi

  echo
  echo "$prompt"
  local i=0
  while [ $i -lt "$count" ]; do
    printf "  %d) %s\n" "$((i + 1))" "${options[$i]}"
    i=$((i + 1))
  done

  while true; do
    echo -n "Choose server [1-$count]: "
    read -r choice < /dev/tty

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
      CHOSEN_INDEX=$((choice - 1))
      return 0
    fi

    echo "Invalid choice"
  done
}

url_decode() {
  local data="${1//+/ }"
  printf '%b' "${data//%/\\x}"
}

# ----- CLEANUP -----
cleanup() {
  echo
  log "Disabling proxy..."
  for IFACE in "${CONFIGURED_INTERFACES[@]}"; do
    if is_service_exists "$IFACE"; then
      networksetup -setsocksfirewallproxystate "$IFACE" off 2>/dev/null
    fi
  done

  if [ -n "${XRAY_PID:-}" ] && kill -0 "$XRAY_PID" 2>/dev/null; then
    kill -TERM "$XRAY_PID" 2>/dev/null
    wait "$XRAY_PID" 2>/dev/null
  fi
}
trap cleanup EXIT

# ----- REQUIREMENTS -----
command -v brew >/dev/null || { err "brew not installed"; exit 1; }

command -v xray >/dev/null || {
  log "Installing xray..."
  brew install xray || { err "failed to install xray"; exit 1; }
}

command -v jq >/dev/null || {
  log "Installing jq..."
  brew install jq || { err "failed to install jq"; exit 1; }
}

# ----- FETCH SUB -----
if [ "$1" == "--reset" ]; then
  rm -f "$INI_FILE"
  ok "Config was cleared"
  shift
fi

if [ -f "$INI_FILE" ]; then
  source "$INI_FILE"
fi

if [ -z "$SUB_URL" ]; then
  SUB_URL="$1"
  if [ -z "$SUB_URL" ]; then
    read -rp "Enter subscription URL: " SUB_URL
    [ -z "$SUB_URL" ] && { err "no subscription URL provided"; exit 1; }
  fi
fi

log "Fetching subscription..."
RAW=$(curl -fsSL "$SUB_URL") || { err "curl failed"; exit 1; }
[ -z "$RAW" ] && { err "empty response from server"; exit 1; }

DECODED=$(echo "$RAW" | base64 --decode 2>/dev/null) || { err "decode failed"; exit 1; }

CONFIGS=()
for line in $(echo "$DECODED" | grep '^vless://'); do
  CONFIGS+=("$line")
done

[ "${#CONFIGS[@]}" -eq 0 ] && { err "No valid vless configs provided from server"; exit 1; }

# ----- BUILD CHOICE LIST -----
SERVER_LABELS=()

for CONFIG in "${CONFIGS[@]}"; do
  BASE_PART="${CONFIG%%\?*}"
  AFTER_HASH="${CONFIG#*#}"

  UUID_TMP=$(echo "$BASE_PART" | sed -E 's|^vless://([^@]+)@.*|\1|')
  HOST_TMP=$(echo "$BASE_PART" | sed -E 's|^vless://[^@]+@([^:]+):.*|\1|')
  PORT_TMP=$(echo "$BASE_PART" | sed -E 's|^vless://[^@]+@[^:]+:([0-9]+).*$|\1|')

  if [ "$AFTER_HASH" != "$CONFIG" ]; then
    NAME_TMP=$(url_decode "$AFTER_HASH")
  else
    NAME_TMP=""
  fi

  if [ -z "$NAME_TMP" ]; then
    NAME_TMP="${HOST_TMP}:${PORT_TMP}"
  fi

  SERVER_LABELS+=("${NAME_TMP} (${HOST_TMP}:${PORT_TMP})")
done

choose_from_list "Multiple servers found:" "${SERVER_LABELS[@]}" || {
  err "failed to choose server"
  exit 1
}

CONFIG="${CONFIGS[$CHOSEN_INDEX]}"
ok "Chosen server: ${SERVER_LABELS[$CHOSEN_INDEX]}"
log "Config: $CONFIG"

# ----- PARSE BASE -----
BASE_PART="${CONFIG%%\?*}"
QUERY_AND_TAG="${CONFIG#*\?}"
QUERY="${QUERY_AND_TAG%%#*}"

UUID=$(echo "$BASE_PART" | sed -E 's|^vless://([^@]+)@.*|\1|')
HOST=$(echo "$BASE_PART" | sed -E 's|^vless://[^@]+@([^:]+):.*|\1|')
PORT=$(echo "$BASE_PART" | sed -E 's|^vless://[^@]+@[^:]+:([0-9]+).*$|\1|')

get_param() {
  echo "$QUERY" | tr '&' '\n' | grep "^$1=" | cut -d= -f2-
}

SNI=$(get_param "sni")
PBK=$(get_param "pbk")
SID=$(get_param "sid")
FLOW=$(get_param "flow")
TYPE=$(get_param "type")
SECURITY=$(get_param "security")
FP=$(get_param "fp")
SPX=$(get_param "spx")

# fallback names
[ -z "$PBK" ] && PBK=$(get_param "publicKey")
[ -z "$SID" ] && SID=$(get_param "shortId")
[ -z "$FP" ] && FP=$(get_param "fingerprint")
[ -z "$SPX" ] && SPX=$(get_param "spiderX")

# defaults
[ -z "$SNI" ] && SNI="$HOST"
[ -z "$TYPE" ] && TYPE="tcp"
[ -z "$SECURITY" ] && SECURITY="reality"
[ -n "$SPX" ] && SPX=$(url_decode "$SPX")
[ -z "$FP" ] && FP="chrome"
[ -z "$SPX" ] && SPX="/"

[ -z "$UUID" ] || [ -z "$HOST" ] || [ -z "$PORT" ] || [ -z "$PBK" ] || [ -z "$SID" ] && {
  err "failed to parse subscription"
  exit 1
}

# ----- CONFIG -----
mkdir -p "$(dirname "$CONFIG_PATH")"

if [ -f "$INI_FILE" ]; then
  source "$INI_FILE"
else
  ask "Do you want to block obvious ad urls with proxy?" BLOCK_ADS 1
  ask "Privite IPs go direct?" PRIVITE_DIRECT 1
  cat > "$INI_FILE" <<EOF
SUB_URL=$SUB_URL
BLOCK_ADS=$BLOCK_ADS
PRIVITE_DIRECT=$PRIVITE_DIRECT
EOF
fi

add_rule() {
  local rule="$1"
  if [ -n "$RULES" ]; then
    RULES="${RULES},"
  fi
  RULES="${RULES}${rule}"
}

RULES=""

if [ "${PRIVITE_DIRECT:-1}" -eq 1 ]; then
  add_rule '
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "direct"
      }'
fi

if [ "${BLOCK_ADS:-1}" -eq 1 ]; then
  add_rule '
      {
        "type": "field",
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "block"
      }'
fi

add_rule '
      {
        "type": "field",
        "ip": [
          "10.0.99.107",
          "192.168.1.1",
          "10.0.99.229",
          "10.3.143.170",
          "93.190.206.157",
          "93.190.206.169",
          "192.168.1.37",
          "192.168.1.38",
          "192.168.1.44",
          "192.168.1.100",
          "93.190.206.163"
        ],
        "outboundTag": "direct"
      }
    '

add_rule '
      {
        "type": "field",
        "domain": [
          "domain:karelia.pro",
          "domain:vk.com",
          "regexp:\\.karelia.pro$",
          "regexp:\\.citylink.pro$"
        ],
        "outboundTag": "direct"
      }
      '

cat > "$CONFIG_PATH" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PROXY_PORT,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": { "udp": true },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$HOST",
            "port": $PORT,
            "users": [
              {
                "id": "$UUID",
                "encryption": "none",
                "flow": "$FLOW"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "$TYPE",
        "security": "$SECURITY",
        "realitySettings": {
          "serverName": "$SNI",
          "publicKey": "$PBK",
          "shortId": "$SID",
          "fingerprint": "$FP",
          "spiderX": "$SPX"
        }
      }
    },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [${RULES}]
  }
}
EOF

ok "config written → $CONFIG_PATH"

log "Testing xray config..."
xray run -test -c "$CONFIG_PATH" >/dev/null || {
  err "xray config is invalid"
  exit 1
}
ok "xray config is valid"

if lsof -nP -iTCP:"$PROXY_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  err "$PROXY_HOST:$PROXY_PORT is already in use"
  # Yes, print the owner. Guessing which tunnel stole the port is how juniors lose afternoons.
  lsof -nP -iTCP:"$PROXY_PORT" -sTCP:LISTEN || true
  exit 1
fi

wait_for_xray() {
  local attempt=0

  while [ "$attempt" -lt 50 ]; do
    if ! kill -0 "$XRAY_PID" 2>/dev/null; then
      wait "$XRAY_PID"
      return 1
    fi

    if lsof -nP -a -p "$XRAY_PID" -iTCP:"$PROXY_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      return 0
    fi

    attempt=$((attempt + 1))
    sleep 0.1
  done

  return 1
}

# ----- START XRAY -----
log "Starting xray..."
xray run -c "$CONFIG_PATH" & XRAY_PID=$!

wait_for_xray || {
  err "xray did not start listening on $PROXY_HOST:$PROXY_PORT"
  exit 1
}
ok "xray is listening on $PROXY_HOST:$PROXY_PORT"

# ----- ENABLE SYSTEM PROXY -----
load_network_services

[ "${#INTERFACES[@]}" -eq 0 ] && {
  err "no enabled macOS network services found"
  exit 1
}

log "Enabling system proxy..."

for IFACE in "${INTERFACES[@]}"; do
  if is_service_exists "$IFACE"; then
    networksetup -setsocksfirewallproxy "$IFACE" "$PROXY_HOST" "$PROXY_PORT"
    networksetup -setsocksfirewallproxystate "$IFACE" on \
      && {
        CONFIGURED_INTERFACES+=("$IFACE")
        ok "$IFACE → $PROXY_HOST:$PROXY_PORT"
      }
  fi
done

if command -v scutil >/dev/null && scutil --proxy | grep -q "SOCKSEnable : 1"; then
  ok "macOS effective SOCKS proxy is enabled"
else
  warn "macOS effective SOCKS proxy is still disabled; an active VPN/tunnel service may be ignoring networksetup"
fi

listen_for_exit() {
  while true; do
    if ! read -rsn1 key < /dev/tty 2>/dev/null; then
      break
    fi
    case "$key" in
      q|Q)
        kill -TERM "$XRAY_PID" 2>/dev/null
        break
        ;;
    esac
  done
}

warn "Press 'q' to quit"

listen_for_exit & LISTENER_PID=$!
wait "$XRAY_PID"

kill "$LISTENER_PID" 2>/dev/null

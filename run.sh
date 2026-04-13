#!/bin/bash

# ----- VARIABLES -----
CONFIG_PATH="/opt/homebrew/etc/xray/config.json"
PROXY_HOST="127.0.0.1"
PROXY_PORT="1080"
INTERFACES=("Wi-Fi", "Ethernet", "iPhone USB")
INI_FILE="./config.ini"

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
  local default="${3:-}"   # 1 = yes (enabled), 0 = no (disabled)

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
    y|Y)
      eval "$var_name=1"
      ;;
    n|N)
      eval "$var_name=0"
      ;;
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

is_service_exists() { networksetup -listallnetworkservices | tail -n +2 | grep -Fxq "$1"; }

# ----- CLEANUP -----
cleanup() {
  echo
  log "Disabling proxy..."
  for IFACE in "${INTERFACES[@]}"; do
    if is_service_exists "$IFACE"; then
      networksetup -setsocksfirewallproxystate "$IFACE" off 2>/dev/null
    fi
  done
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
fi


if [ -f "$INI_FILE" ]; then
  source "$INI_FILE"
fi

# Ask for subscription URL (saved to ini)
if [ -z "$SUB_URL" ]; then
  SUB_URL="$1"
  if [ -z "$SUB_URL" ]; then
    read -rp "Enter subscription URL: " SUB_URL
    [ -z "$SUB_URL" ] && { err "no subscription URL provided"; exit 1; }
  fi
fi

log "Fetching subscription..."
RAW=$(curl -s "$SUB_URL") || { err "curl failed"; exit 1; }
[ -z "$RAW" ] && { err "empty response from server"; exit 1; }

DECODED=$(echo "$RAW" | base64 --decode 2>/dev/null) \
  || { err "decode failed"; exit 1; }

CONFIG=$(echo "$DECODED" | grep '^vless://' | head -n1)
[ -z "$CONFIG" ] && { err "no valid config provided from server"; exit 1; }

log "Config: $CONFIG"

# ----- PARSE BASE -----
UUID=$(echo "$CONFIG" | sed -E 's|vless://([^@]+)@.*|\1|')
HOST=$(echo "$CONFIG" | sed -E 's|vless://[^@]+@([^:]+):.*|\1|')
PORT=$(echo "$CONFIG" | sed -E 's|.*:([0-9]+)\?.*|\1|')

# ----- PARSE QUERY -----
QUERY=$(echo "$CONFIG" | cut -d'?' -f2)

get_param() {
  echo "$QUERY" | tr '&' '\n' | grep "^$1=" | cut -d= -f2
}

SNI=$(get_param "sni")
PBK=$(get_param "pbk")
SID=$(get_param "sid")
FLOW=$(get_param "flow")

# fallback names (some subs use different keys)
[ -z "$PBK" ] && PBK=$(get_param "publicKey")
[ -z "$SID" ] && SID=$(get_param "shortId")

# defaults
[ -z "$SNI" ] && SNI="$HOST"

[ -z "$UUID" ] || [ -z "$HOST" ] || [ -z "$PORT" ] || [ -z "$PBK" ] || [ -z "$SID" ] && {
  err "failed to parse subscription..."
  exit 1
}

# ----- CONFIG -----
mkdir -p "$(dirname "$CONFIG_PATH")"

# building rules
if [ -f "$INI_FILE" ]; then
  source "$INI_FILE"
else
  ask "Do you want to block obvious ad urls with proxy?" BLOCK_ADS 1
  ask "Block private IPs (LAN antileak)?" BLOCK_PRIVATE 1
  cat > "$INI_FILE" <<EOF
SUB_URL=$SUB_URL
BLOCK_ADS=$BLOCK_ADS
BLOCK_PRIVATE=$BLOCK_PRIVATE
EOF
fi

# Build rules
add_rule() {
  local rule="$1"
  if [ -n "$RULES" ]; then
    RULES="${RULES},"
  fi
  RULES="${RULES}${rule}"
}

RULES=""

if [ "$BLOCK_PRIVATE" -eq 1 ]; then
  add_rule '
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      }'
fi

if [ "$BLOCK_ADS" -eq 1 ]; then
  add_rule '
      {
        "type": "field",
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "block"
      }'
fi

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
        "destOverride": ["http","tls"]
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
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "$SNI",
          "publicKey": "$PBK",
          "shortId": "$SID"
        }
      }
    },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [${RULES}]
  }
}
EOF

ok "config written → $CONFIG_PATH"


# ----- ENABLE SYSTEM PROXY -----
log "Enabling system proxy..."

is_service_exists() {
  networksetup -listallnetworkservices | tail -n +2 | grep -Fxq "$1"
}

for IFACE in "${INTERFACES[@]}"; do
  if is_service_exists "$IFACE"; then
    networksetup -setsocksfirewallproxy "$IFACE" "$PROXY_HOST" "$PROXY_PORT"
    networksetup -setsocksfirewallproxystate "$IFACE" on \
      && ok "$IFACE → $PROXY_HOST:$PROXY_PORT"
  fi
done

# ----- START XRAY -----

# exit key listener
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

log "Starting xray..."
xray -c "$CONFIG_PATH" & XRAY_PID=$!
warn "Press 'q' to quit"

listen_for_exit & LISTENER_PID=$!
wait $XRAY_PID

# kill listener if xray exits first
kill $LISTENER_PID 2>/dev/null

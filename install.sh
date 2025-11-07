#!/usr/bin/env bash
set -euo pipefail

# ===== Config =====
IMAGE="nynyjk/eioubc:n4"
REGION="${REGION:-us-central1}"
SERVICE="n4vpnssh"

TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

WSPATH="/n4vpn"
PORT="8080"
TIMEOUT="3600"       # 1 hour
MIN_INSTANCES="1"
CPU="2"
MEMORY="2Gi"

# ===== Helpers =====
abort(){ echo "Error: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || abort "Missing dependency: $1"; }

yangon_time() {
  TZ="Asia/Yangon" date +"%I:%M %p, %d %b %Y (MMT)"
}

tg_send() {
  local text="$1"
  [[ -z "$TELEGRAM_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && { echo "Skip Telegram (token/chat_id not set)"; return 0; }
  curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    --data "parse_mode=HTML" \
    --data "disable_web_page_preview=true" >/dev/null
}

# ===== Checks =====
need gcloud; need curl
gcloud --version >/dev/null || abort "gcloud not initialized"
PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
[[ -z "$PROJECT" || "$PROJECT" == "(unset)" ]] && abort "gcloud project not set. Run: gcloud config set project <PROJECT_ID>"

START_TIME="$(yangon_time)"
echo "Deploying Cloud Run service: $SERVICE to $REGION ..."

# ===== Deploy =====
gcloud run deploy "$SERVICE" \
  --image "$IMAGE" \
  --region "$REGION" \
  --platform managed \
  --allow-unauthenticated \
  --execution-environment gen2 \
  --min-instances "$MIN_INSTANCES" \
  --cpu "$CPU" \
  --memory "$MEMORY" \
  --timeout "$TIMEOUT" \
  --port "$PORT" \
  --set-env-vars "WSPATH=${WSPATH}"

URL="$(gcloud run services describe "$SERVICE" --region "$REGION" --format='value(status.url)')" || abort "Failed to get service URL"
HOST="${URL#https://}"
END_TIME="$(yangon_time)"

# ===== Telegram message (Mono + Quote) =====
read -r -d '' MSG <<EOF
☁️ <b>Google Cloud / Cloud Run SSH</b>

<blockquote><b>Payload</b></blockquote>
<pre><code>GET ${WSPATH} HTTP/1.1
Host: ${HOST}
Connection: Upgrade
Upgrade: Websocket
User-Agent: Googlebot/2.1 (+http://www.google.com/bot.html)[crlf][crlf]</code></pre>

<blockquote><b>host&amp;port/username&amp;pass</b></blockquote>
<pre><code>192.168.100.1:443@n4vpn-n4:n4</code></pre>

<blockquote><b>Proxy&amp;Port</b></blockquote>
<pre><code>vpn.googleapis.com:443</code></pre>

<blockquote><b>SNI</b></blockquote>
<pre><code>vpn.googleapis.com</code></pre>

You Can Use Your Country SNI (or) Host.

<b>Start:</b> ${START_TIME}
<b>End:</b> ${END_TIME}
EOF

tg_send "$MSG"

echo "Done ✅  URL = $URL"

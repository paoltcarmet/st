#!/usr/bin/env bash
set -euo pipefail

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

# Convert time to Yangon
yangon_time() {
  TZ="Asia/Yangon" date +"%I:%M %p, %d %b %Y (MMT)"
}

tg_send() {
  local text="$1"
  curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    --data "parse_mode=HTML" \
    --data "disable_web_page_preview=true" >/dev/null
}

echo "Deploying Cloud Run SSH..."

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

URL="$(gcloud run services describe "$SERVICE" --region "$REGION" --format='value(status.url)')"
HOST="${URL#https://}"

START_TIME="$(yangon_time)"
END_TIME="$(yangon_time)"

read -r -d '' MSG <<EOF
☁️ <b>Google Cloud / Cloud Run SSH</b>

<blockquote><b>Payload</b></blockquote>
<pre><code>GET ${WSPATH} HTTP/1.1
Host: ${HOST}
Connection: Upgrade
Upgrade: Websocket
User-Agent: Googlebot/2.1 (+http://www.google.com/bot.html)[crlf][crlf]</code></pre>

<blockquote><b>host&port/username&pass</b></blockquote>
<pre><code>192.168.100.1:443@n4vpn-n4:n4</code></pre>

<blockquote><b>Proxy&Port</b></blockquote>
<pre><code>vpn.googleapis.com:443</code></pre>

<blockquote><b>SNI</b></blockquote>
<pre><code>vpn.googleapis.com</code></pre>

You can use your country SNI or host.

<b>Start:</b> ${START_TIME}
<b>End:</b> ${END_TIME}
EOF

tg_send "$MSG"

echo "Done! Telegram sent."
echo "URL = $URL"

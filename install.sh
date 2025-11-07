#!/usr/bin/env bash
# vl.sh — Cloud Run SSH deploy + Telegram notify (Mono + Quote UI)
set -euo pipefail

# ===== Config (env override-able) =====
IMAGE="${IMAGE:-nynyjk/eioubc:n4}"
REGION="${REGION:-us-central1}"
SERVICE="${SERVICE:-n4vpnssh}"

CPU="${CPU:-2}"
MEMORY="${MEMORY:-2Gi}"
TIMEOUT="${TIMEOUT:-3600}"          # seconds
MIN_INSTANCES="${MIN_INSTANCES:-1}"
PORT="${PORT:-8080}"
WSPATH="${WSPATH:-/n4vpn}"

# Duration from Start → End (default = 5 hours)
DURATION_HOURS="${DURATION_HOURS:-5}"

# Telegram (env required)
TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# ===== Helpers =====
abort(){ echo "Error: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || abort "Missing dependency: $1"; }

# Time helpers (Asia/Yangon)
yangon_now_epoch(){ TZ="Asia/Yangon" date +%s; }
yangon_fmt_epoch(){ TZ="Asia/Yangon" date -d "@$1" "+%-I:%M %p,%-d.%-m.%Y(ASIA/YANGON)"; }

html_escape(){ sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

tg_send(){
  local text="$1"
  if [[ -z "$TELEGRAM_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
    echo "Skip Telegram (token/chat_id not set)"; return 0
  fi
  local resp code body

  # Try HTML mode
  resp="$(curl -sS -w '\n%{http_code}' -X POST \
      "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${text}" \
      --data "parse_mode=HTML" \
      --data "disable_web_page_preview=true")"

  code="$(echo "$resp" | tail -n1)"
  body="$(echo "$resp" | sed '$d')"

  [[ "$code" == "200" ]] && { echo "Telegram sent (HTML)"; return 0; }

  # Retry on 429
  if [[ "$code" == "429" ]]; then
    echo "Rate limit (429), retrying…"
    sleep 2
    resp="$(curl -sS -w '\n%{http_code}' -X POST \
        "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${text}" \
        --data "parse_mode=HTML" \
        --data "disable_web_page_preview=true")"
    code="$(echo "$resp" | tail -n1)"
    [[ "$code" == "200" ]] && { echo "Telegram sent after retry"; return 0; }
  fi

  echo "HTML send failed ($code): $body"
  echo "Trying plain text fallback…"

  # plain fallback
  plain="$(echo "$text" | sed 's/<[^>]*>//g')"
  resp="$(curl -sS -w '\n%{http_code}' -X POST \
      "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${plain}" \
      --data "disable_web_page_preview=true")"

  code="$(echo "$resp" | tail -n1)"
  [[ "$code" == "200" ]] && { echo "Telegram sent (plain)"; return 0; }

  echo "Telegram failed final ($code): $(echo "$resp" | sed '$d')"
}

enable_api(){
  local api="$1"
  echo "• Ensuring API enabled: $api"
  gcloud services enable "$api" --quiet >/dev/null 2>&1 \
    || gcloud services enable "$api" --quiet
}

# ===== Checks =====
need gcloud; need curl
gcloud --version >/dev/null || abort "gcloud not initialized"

PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
[[ -z "$PROJECT" || "$PROJECT" == "(unset)" ]] && abort "Run: gcloud config set project <PROJECT_ID>"

# ===== Enable APIs =====
enable_api "run.googleapis.com"

# ===== Time Calculation =====
START_TS="$(yangon_now_epoch)"
END_TS="$(( START_TS + DURATION_HOURS * 3600 ))"

START_TIME="$(yangon_fmt_epoch "$START_TS")"
END_TIME="$(yangon_fmt_epoch "$END_TS")"

# ===== Deploy Cloud Run =====
echo "Deploying ${SERVICE} to ${REGION}…"

gcloud run deploy "$SERVICE" \
  --image "$IMAGE" \
  --region "$REGION" \
  --platform managed \
  --execution-environment gen2 \
  --allow-unauthenticated \
  --min-instances "$MIN_INSTANCES" \
  --cpu "$CPU" \
  --memory "$MEMORY" \
  --timeout "$TIMEOUT" \
  --port "$PORT" \
  --set-env-vars "WSPATH=${WSPATH}"

URL="$(gcloud.run services describe "$SERVICE" --region "$REGION" --format='value(status.url)')" || abort "Failed to read URL"
HOST="${URL#https://}"

# ===== Payload =====
PAYLOAD="GET ${WSPATH} HTTP/1.1
Host: ${HOST}
Connection: Upgrade
Upgrade: Websocket
User-Agent: Googlebot/2.1 (+http://www.google.com/bot.html)[crlf][crlf]"

PAYLOAD_ESCAPED="$(echo "$PAYLOAD" | html_escape)"

# ===== Telegram Message =====
read -r -d '' MSG <<EOF || true
☁️ <b>Google Cloud / Cloud Run SSH</b>

<blockquote><b>Payload</b></blockquote>
<pre><code>${PAYLOAD_ESCAPED}</code></pre>

<blockquote><b>host&amp;port/username&amp;pass</b></blockquote>
<pre><code>192.168.100.1:443@n4vpn-n4:n4</code></pre>

<blockquote><b>Proxy&amp;Port</b></blockquote>
<pre><code>vpn.googleapis.com:443</code></pre>

<blockquote><b>SNI</b></blockquote>
<pre><code>vpn.googleapis.com</code></pre>

You can use your country SNI or host.

<b>URL:</b> ${URL}

<b>Start:</b> ${START_TIME}
<b>End:</b> ${END_TIME}
EOF

tg_send "$MSG"

echo "✅ Done! URL = $URL"

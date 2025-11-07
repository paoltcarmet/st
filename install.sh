#!/usr/bin/env bash
# vl.sh — Cloud Run SSH deploy + Telegram notify (Mono + Quote UI)
set -euo pipefail

# ===== Config (env override-able) =====
IMAGE="${IMAGE:-nynyjk/eioubc:n4}"
REGION="${REGION:-us-central1}"
SERVICE="${SERVICE:-n4vpnssh}"

CPU="${CPU:-2}"
MEMORY="${MEMORY:-2Gi}"
TIMEOUT="${TIMEOUT:-3600}"       # seconds
MIN_INSTANCES="${MIN_INSTANCES:-1}"
PORT="${PORT:-8080}"

WSPATH="${WSPATH:-/n4vpn}"

# Telegram (provide via env when calling)
TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# ===== Helpers =====
abort(){ echo "Error: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || abort "Missing dependency: $1"; }
yangon_time(){ TZ="Asia/Yangon" date +"%I:%M %p, %d %b %Y (MMT)"; }
html_escape(){ sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

tg_send(){
  local text="$1"
  if [[ -z "$TELEGRAM_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
    echo "Skip Telegram (token/chat_id not set)"; return 0
  fi

  # 1) Try HTML
  local resp code body
  resp="$(curl -sS -w '\n%{http_code}' -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${text}" \
      --data "parse_mode=HTML" \
      --data "disable_web_page_preview=true")"
  code="$(echo "$resp" | tail -n1)"; body="$(echo "$resp" | sed '$d')"
  if [[ "$code" == "200" ]]; then echo "Telegram sent (HTML)."; return 0; fi

  # 2) Retry once on 429
  if [[ "$code" == "429" ]]; then
    echo "Telegram rate-limited (429). Retrying in 2s..."
    sleep 2
    resp="$(curl -sS -w '\n%{http_code}' -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${text}" \
        --data "parse_mode=HTML" \
        --data "disable_web_page_preview=true")"
    code="$(echo "$resp" | tail -n1)"; body="$(echo "$resp" | sed '$d')"
    if [[ "$code" == "200" ]]; then echo "Telegram sent after retry."; return 0; fi
  fi

  echo "HTML send failed (HTTP $code): $body"
  echo "Falling back to plain text…"

  # 3) Plain text fallback
  local plain
  plain="$(echo "$text" | sed 's/<[^>]*>//g')"
  resp="$(curl -sS -w '\n%{http_code}' -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${plain}" \
      --data "disable_web_page_preview=true")"
  code="$(echo "$resp" | tail -n1)"; body="$(echo "$resp" | sed '$d')"
  if [[ "$code" == "200" ]]; then
    echo "Telegram sent (plain)."; return 0
  else
    echo "Telegram failed (plain) HTTP $code: $body"
    return 0   # don't break the deploy pipeline
  fi
}

enable_api(){
  local api="$1"
  echo "• Ensuring API enabled: $api"
  gcloud services enable "$api" --quiet >/dev/null 2>&1 || gcloud services enable "$api" --quiet
}

# ===== Checks =====
need gcloud; need curl
gcloud --version >/dev/null || abort "gcloud not initialized"
PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
[[ -z "$PROJECT" || "$PROJECT" == "(unset)" ]] && abort "Run: gcloud config set project <PROJECT_ID>"

# ===== Enable required APIs =====
enable_api "run.googleapis.com"
# If you need Artifact Registry for images, also enable:
# enable_api "artifactregistry.googleapis.com"

# ===== Deploy =====
START_TIME="$(yangon_time)"
echo "Deploying ${SERVICE} → ${REGION} …"

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

URL="$(gcloud run services describe "$SERVICE" --region "$REGION" --format='value(status.url)')" || abort "Failed to get service URL"
HOST="${URL#https://}"
END_TIME="$(yangon_time)"

# ===== Build payload blocks =====
PAYLOAD="GET ${WSPATH} HTTP/1.1
Host: ${HOST}
Connection: Upgrade
Upgrade: Websocket
User-Agent: Googlebot/2.1 (+http://www.google.com/bot.html)[crlf][crlf]"
PAYLOAD_ESCAPED="$(echo "$PAYLOAD" | html_escape)"

# ===== Telegram message (Mono + Quote) =====
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

You Can Use Your Country SNI (or) Host.

<b>URL:</b> ${URL}

<b>Start:</b> ${START_TIME}
<b>End:</b> ${END_TIME}
EOF

tg_send "$MSG"

echo "Done ✅  URL = $URL"

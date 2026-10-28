#!/usr/bin/env bash
# Production Secrets. Git holds this script and the names; values never.
# Provider keys arrive on stdin as KEY=value lines (any subset; a re-run
# replaces the given ones). Internal secrets are generated here once and kept
# on every later run: regenerating them would break the database and sessions.
#   scp infra/server/secrets.sh outegro-prod:/tmp/
#   <KEY=value lines> | ssh outegro-prod 'sudo bash /tmp/secrets.sh; rm /tmp/secrets.sh'
set -euo pipefail
umask 077
k() { k3s kubectl "$@"; }
NS=outegro
k create namespace "$NS" --dry-run=client -o yaml | k apply -f - >/dev/null

declare -A in=()
while IFS='=' read -r key value; do
  [ -n "$key" ] && in["$key"]="$value"
done

put() { # namespace name args… — create or replace
  local ns=$1 name=$2; shift 2
  k -n "$ns" create secret generic "$name" "$@" --dry-run=client -o yaml | k apply -f - >/dev/null
  echo "secret $ns/$name set"
}
once() { # namespace name args… — create only if missing
  local ns=$1 name=$2; shift 2
  if k -n "$ns" get secret "$name" >/dev/null 2>&1; then echo "secret $ns/$name kept"; return; fi
  k -n "$ns" create secret generic "$name" "$@" >/dev/null
  echo "secret $ns/$name created"
}
has() { for key in "$@"; do [ -n "${in[$key]:-}" ] || return 1; done; }
hex() { openssl rand -hex "$1"; }

# Provider keys.
if has CLOUDFLARE_API_TOKEN; then
  put cert-manager cloudflare-api-token --from-literal=api-token="${in[CLOUDFLARE_API_TOKEN]}"
fi
if has R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT; then
  put "$NS" r2-backups \
    --from-literal=ACCESS_KEY_ID="${in[R2_ACCESS_KEY_ID]}" \
    --from-literal=ACCESS_SECRET_KEY="${in[R2_SECRET_ACCESS_KEY]}" \
    --from-literal=ENDPOINT="${in[R2_ENDPOINT]}"
fi
if has RESEND_API_KEY; then
  put "$NS" notifications-providers \
    --from-literal=RESEND_API_KEY="${in[RESEND_API_KEY]}" \
    --from-literal=TELEGRAM_BOT_TOKEN="${in[TELEGRAM_BOT_TOKEN]:-}"
fi
if has GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET; then
  put "$NS" google-oauth \
    --from-literal=GOOGLE_CLIENT_ID="${in[GOOGLE_CLIENT_ID]}" \
    --from-literal=GOOGLE_CLIENT_SECRET="${in[GOOGLE_CLIENT_SECRET]}"
fi
if has LAVA_API_KEY; then
  put "$NS" lava --from-literal=LAVA_API_KEY="${in[LAVA_API_KEY]}"
fi
# Education's assistant (ADR-010): the MiniMax key, read only by edu-backend.
if has MINIMAX_API_KEY; then
  put "$NS" edu-assist --from-literal=MINIMAX_API_KEY="${in[MINIMAX_API_KEY]}"
fi
# Atelier (atelier.outegro.dev, owner-only): the owner's Codex login (auth.json
# of his ChatGPT subscription, base64) and optional Claude / MiniMax keys, read
# only by llm-gateway. The Codex file is copied once into its volume: Codex
# refreshes the token there, so a re-run replaces only the seed.
if has ATELIER_CODEX_AUTH_B64; then
  put "$NS" atelier-codex --from-literal=auth.json="$(printf '%s' "${in[ATELIER_CODEX_AUTH_B64]}" | base64 -d)"
fi
if has ATELIER_MINIMAX_API_KEY || has ATELIER_CLAUDE_CODE_OAUTH_TOKEN; then
  put "$NS" atelier-llm \
    --from-literal=MINIMAX_API_KEY="${in[ATELIER_MINIMAX_API_KEY]:-}" \
    --from-literal=CLAUDE_CODE_OAUTH_TOKEN="${in[ATELIER_CLAUDE_CODE_OAUTH_TOKEN]:-}"
fi

# Generated once, never rotated by a re-run.
once "$NS" platform-internal --from-literal=INTERNAL_API_TOKEN="$(hex 32)"
once "$NS" auth-signing \
  --from-literal=JWT_PRIVATE_KEY="$(openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 2>/dev/null)" \
  --from-literal=LOGIN_CODE_PEPPER="$(hex 32)"
once "$NS" pg-auth --type=kubernetes.io/basic-auth \
  --from-literal=username=auth --from-literal=password="$(hex 24)"
once "$NS" pg-notifications --type=kubernetes.io/basic-auth \
  --from-literal=username=notifications --from-literal=password="$(hex 24)"
once "$NS" pg-payments --type=kubernetes.io/basic-auth \
  --from-literal=username=payments --from-literal=password="$(hex 24)"
once "$NS" pg-battleship --type=kubernetes.io/basic-auth \
  --from-literal=username=battleship --from-literal=password="$(hex 24)"
once "$NS" pg-edu --type=kubernetes.io/basic-auth \
  --from-literal=username=edu --from-literal=password="$(hex 24)"
once "$NS" pg-wallet --type=kubernetes.io/basic-auth \
  --from-literal=username=wallet --from-literal=password="$(hex 24)"
# Roulette (ADR-012): three databases, a Valkey of its own, the seed chain's
# root (whoever reads it knows every outcome) and the bonus's hash pepper.
once "$NS" pg-roulette --type=kubernetes.io/basic-auth \
  --from-literal=username=roulette --from-literal=password="$(hex 24)"
once "$NS" pg-fair-roll --type=kubernetes.io/basic-auth \
  --from-literal=username=fair_roll --from-literal=password="$(hex 24)"
once "$NS" pg-daily --type=kubernetes.io/basic-auth \
  --from-literal=username=daily --from-literal=password="$(hex 24)"
once "$NS" valkey-roulette --from-literal=password="$(hex 32)"
once "$NS" fair-roll --from-literal=FAIR_ROLL_ROOT="$(hex 32)"
once "$NS" daily-bonus --from-literal=DAILY_HASH_PEPPER="$(hex 32)"
once "$NS" pg-atelier --type=kubernetes.io/basic-auth \
  --from-literal=username=atelier --from-literal=password="$(hex 24)"
# Service tokens between atelier-backend and its llm-gateway, TeX and browser.
once "$NS" atelier-internal \
  --from-literal=LLM_GATEWAY_TOKEN="$(hex 32)" \
  --from-literal=ATELIER_TEX_TOKEN="$(hex 32)" \
  --from-literal=ATELIER_BROWSER_TOKEN="$(hex 32)"
# Signs the owner's device cookie on cv.outegro.dev: their own opens of a CV
# link do not count as the recruiter's.
once "$NS" atelier-cv --from-literal=CV_OWNER_COOKIE_SECRET="$(hex 32)"
once "$NS" valkey --from-literal=password="$(hex 32)"
once "$NS" rabbitmq --from-literal=username=outegro --from-literal=password="$(hex 32)"
# Telegram echoes it on every webhook call (X-Telegram-Bot-Api-Secret-Token).
once "$NS" telegram-webhook --from-literal=TELEGRAM_WEBHOOK_SECRET="$(hex 32)"

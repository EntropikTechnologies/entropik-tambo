#!/bin/bash
# Local-only wrapper around Tambo's own self-hosting scripts (scripts/cloud/*).
# Uses the repo one level up (entropik-tambo) as the Tambo source, generates secrets in
# ../docker.env, then delegates to Tambo's start / init scripts.
#
# Usage:
#   ./run-local.sh setup   clone + create docker.env with generated secrets
#   ./run-local.sh up      build + start web, api, postgres, minio
#   ./run-local.sh init    run DB migrations (after `up`)
#   ./run-local.sh logs    tail logs
#   ./run-local.sh down    stop the stack (data kept)
#   ./run-local.sh reset   stop and delete all Tambo data volumes
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/.." && pwd)"
ENV_FILE="$SRC/docker.env"

set_var() { # set_var KEY VALUE  (replace the KEY=... line in docker.env)
  local key="$1" val="$2"
  sed -i.bak "s|^${key}=.*|${key}=${val}|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
}

cmd_setup() {
  if [ ! -d "$SRC/.git" ]; then
    git clone --depth 1 https://github.com/tambo-ai/tambo.git "$SRC"
  fi
  (cd "$SRC" && ./scripts/cloud/tambo-setup.sh >/dev/null)

  # Only generate secrets once, so re-running setup never rotates them.
  if grep -q "^API_KEY_SECRET=your-api-key-secret" "$ENV_FILE"; then
    set_var POSTGRES_PASSWORD "$(openssl rand -hex 12)"
    set_var API_KEY_SECRET "$(openssl rand -hex 16)"
    set_var PROVIDER_KEY_SECRET "$(openssl rand -hex 16)"
    set_var NEXTAUTH_SECRET "$(openssl rand -hex 16)"
  fi

  # Reuse OPENAI_API_KEY from the shell if present.
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    set_var OPENAI_API_KEY "$OPENAI_API_KEY"
    set_var FALLBACK_OPENAI_API_KEY "$OPENAI_API_KEY"
    set_var EXTRACTION_OPENAI_API_KEY "$OPENAI_API_KEY"
  fi

  echo
  echo "docker.env: $ENV_FILE"
  echo "Still to fill in by hand:"
  echo "  - FALLBACK_OPENAI_API_KEY (and OPENAI_API_KEY) if not exported in your shell"
  echo "  - a login method: GOOGLE_CLIENT_ID/SECRET or GITHUB_CLIENT_ID/SECRET"
  echo "    (OAuth callback base: http://localhost:8260), or RESEND_API_KEY + EMAIL_FROM_DEFAULT"
}

require_env() {
  [ -f "$ENV_FILE" ] || { echo "Run ./run-local.sh setup first" >&2; exit 1; }
}

case "${1:-}" in
  setup) cmd_setup ;;
  up)    require_env; (cd "$SRC" && ./scripts/cloud/tambo-start.sh) ;;
  init)  require_env; (cd "$SRC" && ./scripts/cloud/init-database.sh) ;;
  logs)  require_env; (cd "$SRC" && ./scripts/cloud/tambo-logs.sh) ;;
  down)  require_env; (cd "$SRC" && ./scripts/cloud/tambo-stop.sh) ;;
  reset) require_env; (cd "$SRC" && docker compose --env-file docker.env down -v) ;;
  *) sed -n '2,14p' "$0"; exit 1 ;;
esac

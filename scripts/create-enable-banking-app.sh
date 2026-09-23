#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: environment file not found: $ENV_FILE" >&2
  echo "Copy .env.example to .env and add your Enable Banking token." >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a
source "$ENV_FILE"
set +a

: "${ENABLE_BANKING_TOKEN:?Error: ENABLE_BANKING_TOKEN is missing from $ENV_FILE}"

APP_NAME="${ENABLE_BANKING_APP_NAME:-My app}"
APP_ENVIRONMENT="${ENABLE_BANKING_ENVIRONMENT:-SANDBOX}"
CERTIFICATE_FILE="${ENABLE_BANKING_CERTIFICATE_FILE:-$PROJECT_DIR/public.crt}"
PRIVATE_KEY_FILE="${ENABLE_BANKING_PRIVATE_KEY_FILE:-$PROJECT_DIR/private.key}"
CERTIFICATE_DAYS="${ENABLE_BANKING_CERTIFICATE_DAYS:-365}"
CERTIFICATE_SUBJECT="${ENABLE_BANKING_CERTIFICATE_SUBJECT:-/C=XX/O=My app/CN=localhost}"
REDIRECT_URL="${ENABLE_BANKING_REDIRECT_URL:-https://localhost:13579/callback}"

if [[ "$APP_ENVIRONMENT" == "PRODUCTION" ]]; then
  : "${ENABLE_BANKING_DESCRIPTION:?Error: ENABLE_BANKING_DESCRIPTION is required for PRODUCTION}"
  : "${ENABLE_BANKING_GDPR_EMAIL:?Error: ENABLE_BANKING_GDPR_EMAIL is required for PRODUCTION}"
  : "${ENABLE_BANKING_PRIVACY_URL:?Error: ENABLE_BANKING_PRIVACY_URL is required for PRODUCTION}"
  : "${ENABLE_BANKING_TERMS_URL:?Error: ENABLE_BANKING_TERMS_URL is required for PRODUCTION}"
fi

if [[ "$CERTIFICATE_FILE" != /* ]]; then
  CERTIFICATE_FILE="$PROJECT_DIR/$CERTIFICATE_FILE"
fi

if [[ "$PRIVATE_KEY_FILE" != /* ]]; then
  PRIVATE_KEY_FILE="$PROJECT_DIR/$PRIVATE_KEY_FILE"
fi

if [[ ! -f "$CERTIFICATE_FILE" ]]; then
  command -v openssl >/dev/null 2>&1 || {
    echo "Error: openssl is required to create the certificate." >&2
    exit 1
  }

  echo "Certificate not found; generating $CERTIFICATE_FILE"

  umask 077
  if [[ ! -f "$PRIVATE_KEY_FILE" ]]; then
    openssl genrsa -out "$PRIVATE_KEY_FILE" 4096 >/dev/null 2>&1
  fi

  openssl req -new -x509 -sha256 \
    -days "$CERTIFICATE_DAYS" \
    -key "$PRIVATE_KEY_FILE" \
    -out "$CERTIFICATE_FILE" \
    -subj "$CERTIFICATE_SUBJECT" \
    >/dev/null 2>&1

  chmod 600 "$PRIVATE_KEY_FILE"
  chmod 644 "$CERTIFICATE_FILE"
  echo "Created private key: $PRIVATE_KEY_FILE"
  echo "Created certificate: $CERTIFICATE_FILE"
fi

if [[ ! -f "$CERTIFICATE_FILE" ]]; then
  echo "Error: certificate file not found: $CERTIFICATE_FILE" >&2
  exit 1
fi

command -v curl >/dev/null 2>&1 || {
  echo "Error: curl is required." >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || {
  echo "Error: jq is required to encode the certificate JSON safely." >&2
  exit 1
}

payload="$(jq -n \
  --arg name "$APP_NAME" \
  --rawfile certificate "$CERTIFICATE_FILE" \
  --arg environment "$APP_ENVIRONMENT" \
  --arg redirect_url "$REDIRECT_URL" \
  --arg description "${ENABLE_BANKING_DESCRIPTION:-}" \
  --arg gdpr_email "${ENABLE_BANKING_GDPR_EMAIL:-}" \
  --arg privacy_url "${ENABLE_BANKING_PRIVACY_URL:-}" \
  --arg terms_url "${ENABLE_BANKING_TERMS_URL:-}" \
  '{
    name: $name,
    certificate: $certificate,
    environment: $environment,
    redirect_urls: [$redirect_url]
  }
  + (if $environment == "PRODUCTION" then {
      description: $description,
      gdpr_email: $gdpr_email,
      privacy_url: $privacy_url,
      terms_url: $terms_url
    } else {} end)')"

echo "Creating Enable Banking app: $APP_NAME"

curl --fail-with-body --silent --show-error \
  --request POST \
  --header "Authorization: Bearer $ENABLE_BANKING_TOKEN" \
  --header "Content-Type: application/json" \
  --data "$payload" \
  https://enablebanking.com/api/applications

echo

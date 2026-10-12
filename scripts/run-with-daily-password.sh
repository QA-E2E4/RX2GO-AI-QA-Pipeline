#!/usr/bin/env bash
set -euo pipefail

SUITE="${1:-smoke}"
ENVIRONMENT="${2:-HOT}"
MUTATING="${3:-false}"

case "$ENVIRONMENT" in
  HOT|ADM|BRANCH) ;;
  *) echo "Unknown environment: $ENVIRONMENT (use HOT|ADM|BRANCH)" >&2; exit 2 ;;
esac

DAILY_PASSWORD_WAS_SET="${RX2GO_DAILY_PASSWORD+x}"
APP_PASSWORD_WAS_SET="${RX2GO_APP_PASSWORD+x}"

if [[ "$ENVIRONMENT" == "ADM" ]]; then
  read -r -s -p "Enter today's Rx2GO gateway password from Telegram: " RX2GO_DAILY_PASSWORD
  echo
  export RX2GO_GATEWAY_LOGIN="admin"
  export RX2GO_DAILY_PASSWORD
fi

if [[ -z "${RX2GO_APP_LOGIN:-}" ]]; then
  read -r -p "Enter Rx2GO application login: " RX2GO_APP_LOGIN
  echo
fi
if [[ -z "${RX2GO_APP_LOGIN:-}" ]]; then
  echo "RX2GO_APP_LOGIN is required" >&2
  exit 2
fi

if [[ -z "${RX2GO_APP_PASSWORD:-}" ]]; then
  read -r -s -p "Enter Rx2GO application password: " RX2GO_APP_PASSWORD
  echo
fi

export RX2GO_APP_LOGIN
export RX2GO_APP_PASSWORD
export TEST_ENV="$ENVIRONMENT"
export RUN_MUTATING_TESTS="$MUTATING"

cleanup() {
  if [[ "$ENVIRONMENT" == "ADM" && -z "$DAILY_PASSWORD_WAS_SET" ]]; then
    unset RX2GO_DAILY_PASSWORD
    unset RX2GO_GATEWAY_LOGIN
  fi
  if [[ -z "$APP_PASSWORD_WAS_SET" ]]; then
    unset RX2GO_APP_PASSWORD
  fi
}
trap cleanup EXIT

case "$SUITE" in
  smoke) npm run test:smoke ;;
  tickets) npm run test:tickets ;;
  all) npm test ;;
  *) echo "Unknown suite: $SUITE (use smoke|tickets|all)" >&2; exit 2 ;;
esac

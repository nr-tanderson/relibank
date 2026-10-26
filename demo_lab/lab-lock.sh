#!/usr/bin/env bash
set -euo pipefail
: "${TFSTATE_STORAGE_ACCOUNT:?}"
: "${TFSTATE_CONTAINER:?}"
: "${TFSTATE_KEY:?}"
lock_blob="${TFSTATE_KEY}.operation-lock"
lease=$(az storage blob lease acquire --account-name "$TFSTATE_STORAGE_ACCOUNT" --container-name "$TFSTATE_CONTAINER" --blob-name "$lock_blob" --auth-mode login --lease-duration -1 --query leaseId -o tsv)
cleanup() {
  az storage blob lease release --account-name "$TFSTATE_STORAGE_ACCOUNT" --container-name "$TFSTATE_CONTAINER" --blob-name "$lock_blob" --auth-mode login --lease-id "$lease" -o none || true
}
trap cleanup EXIT
"$@"
#!/usr/bin/env bash
# Teardown. Takes an argument, because the two levels are not interchangeable.
#
#   (no argument)  Delete the EKS cluster and stop the containers. The LocalStack state
#                  under ./data/localstack survives, so the next start resumes from the
#                  resources that already exist.
#   --purge-data   Additionally delete ./data/localstack. Slower to come back, roughly 20
#                  minutes of re-downloading the k3d, registry and nginx binaries, but a
#                  genuine clean slate.
#
# ── Why --purge-data had to become an explicit option ────────────────────────
# This used to be `docker compose down -v` and nothing else. The -v flag removes named
# volumes, but ./data/localstack is a BIND MOUNT and survived untouched, and with
# PERSISTENCE=1 set in docker-compose.yml every emulated resource came straight back on the
# next start. "I destroyed everything and the old ALB is still there" traces to exactly
# this.
. "$(dirname "$0")/lib.sh"

PURGE=0
if [ "${1:-}" = "--purge-data" ]; then PURGE=1; fi

echo "=== Tearing down ${PROJECT_NAME} ==="

echo ">>> Deleting EKS cluster ${CLUSTER_NAME}..."
aws_ eks delete-cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true

echo ">>> Stopping containers..."
docker compose down -v

if [ "$PURGE" -eq 1 ]; then
  # A confirmation prompt rather than a bare rm: this also removes the cached LocalStack
  # licence and the downloaded k3d and nginx binaries, which is a long wait to trigger by
  # accident from a mistyped make target.
  echo ""
  echo "About to DELETE ./data/localstack: every persisted LocalStack resource, plus the"
  echo "cached k3d, registry and nginx binaries (roughly 20 minutes to re-download)."
  printf "Type yes to confirm: "
  read -r CONFIRM
  if [ "$CONFIRM" = "yes" ]; then
    rm -rf ./data/localstack
    echo ">>> Deleted."
  else
    echo ">>> Skipped. State kept."
  fi
else
  echo ""
  echo ">>> ./data/localstack KEPT. PERSISTENCE=1 will restore the emulated resources."
  echo "    For a true clean slate:  make purge"
fi

echo "=== Teardown completed ==="

#!/usr/bin/env bash
# Move GITHUB_TOKEN from .env into AWS Secrets Manager.
#
# Separate from bootstrap.sh because it is the one step you re-run on its own: rotating a
# token should not mean re-waiting on a cluster that is already up.
#
#   .env  ->  Secrets Manager  ->  k8s Secret git-credentials  ->  Tekton
#    here        here                bootstrap.sh step 5
#
# .env is the only place a token is typed by hand, and it is gitignored. If the cluster is
# already running this script refreshes the in-cluster Secret too, so a rotation is one
# command rather than two.
. "$(dirname "$0")/lib.sh"

require_tool aws curl

wait_localstack

echo "=== Ingesting secrets into AWS Secrets Manager ==="
echo ">>> Target:   ${SECRET_NAME_GITHUB}"
echo ">>> Endpoint: ${AWS_ENDPOINT}"

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo ""
  echo "WARNING: GITHUB_TOKEN is empty in .env. Storing a placeholder so the rest of the" >&2
  echo "         lab can run. The Tekton git push step will refuse to run, with an" >&2
  echo "         explicit error, until a real token carrying repo write scope is set." >&2
  GITHUB_TOKEN="dummy_token_for_local_testing"
fi

if aws_ secretsmanager describe-secret --secret-id "$SECRET_NAME_GITHUB" >/dev/null 2>&1; then
  echo ">>> Secret exists, updating value..."
  aws_ secretsmanager put-secret-value \
    --secret-id "$SECRET_NAME_GITHUB" --secret-string "$GITHUB_TOKEN" >/dev/null
else
  echo ">>> Creating secret..."
  aws_ secretsmanager create-secret \
    --name "$SECRET_NAME_GITHUB" --secret-string "$GITHUB_TOKEN" >/dev/null
fi
echo ">>> Stored (value not echoed)."

# Refresh the in-cluster copy if there is a cluster to refresh. Silently skipped on a first
# run, when this script executes before bootstrap.sh has created anything.
if command -v kubectl >/dev/null 2>&1 && kubectl get ns tekton-pipelines >/dev/null 2>&1; then
  echo ">>> Cluster is up, refreshing the git-credentials Secret..."
  kubectl -n tekton-pipelines create secret generic git-credentials \
    --from-literal=token="$GITHUB_TOKEN" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo ">>> Refreshed. In-flight PipelineRuns keep the old value; new ones get this one."
else
  echo ">>> No cluster yet. bootstrap.sh will materialise the in-cluster Secret."
fi

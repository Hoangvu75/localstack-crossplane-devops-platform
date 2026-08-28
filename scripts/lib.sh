# Sourced by every script in this directory. Not a lifecycle step, not executable.
#
# Exists because three separate bugs all had the same root cause: each script read
# AWS_ENDPOINT / PROJECT_NAME from the environment, but nothing ever put them there.
# Only the secrets step sourced .env, and `make` runs every target in a fresh
# shell, so AWS_ACCESS_KEY_ID never reached `aws` in the other steps: they failed with
# "Unable to locate credentials" on a machine with no ~/.aws/credentials.
#
# Usage, first two lines of every script:
#   . "$(dirname "$0")/lib.sh"

set -eo pipefail

# Every script uses repo-relative paths (kubectl apply -f gitops/...), so anchor the
# working directory instead of requiring the caller to be in the repo root.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# `tr -d '\r'` is not cosmetic on Windows: .env edited in Notepad or VS Code with CRLF
# endings sourced directly gives every value a trailing carriage return, and
# "us-east-1\r" reaches the AWS CLI as an invalid region with an unreadable error.
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1090
  . <(tr -d '\r' < .env)
  set +a
fi

export AWS_ENDPOINT="${AWS_ENDPOINT:-http://localhost:4566}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-mock_access_key}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-mock_secret_key}"

export PROJECT_NAME="${PROJECT_NAME:-learn-crossplane}"
export CLUSTER_NAME="${PROJECT_NAME}-dev"
export GITHUB_BRANCH="${GITHUB_BRANCH:-main}"

# Must match spec.generators[].git.repoURL and spec.template.spec.source.repoURL in
# gitops/bootstrap/appset.yaml CHARACTER FOR CHARACTER. ArgoCD matches a repository
# credential to a repo by string comparison on the URL, so a missing .git suffix or an
# embedded username silently produces "repository not accessible" on a private repo.
export GITHUB_REPO="${GITHUB_REPO:-github.com/Hoangvu75/localstack-crossplane-devops-platform.git}"
export GITHUB_REPO_URL="https://${GITHUB_REPO}"
export SECRET_NAME_GITHUB="${PROJECT_NAME}/github-token"

# Every AWS call in this repo goes through LocalStack. Wrapping it once keeps the
# --endpoint-url/--region pair out of thirty call sites.
aws_() {
  aws --endpoint-url "$AWS_ENDPOINT" --region "$AWS_DEFAULT_REGION" "$@"
}

require_tool() {
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: '$t' not found in PATH." >&2; exit 1; }
  done
}

# Both lifecycle scripts talk to LocalStack immediately, and `make all` starts the
# container milliseconds earlier, so both need this. It used to live only in the EKS step,
# which left the secrets step racing a container that was still booting: the AWS call
# failed with an endpoint connection error that read like a configuration problem.
#
# $1 = service name to require in the health payload (default: any running gateway).
wait_localstack() {
  local svc="${1:-}" attempt=0 pattern
  if [ -n "$svc" ]; then
    pattern="\"${svc}\":\"(available|running)\""
  else
    pattern='"(services|version)"'
  fi
  # tr strips whitespace so the match works whether LocalStack pretty-prints the JSON or
  # returns it compact. A previous version grepped for '"eks": "available"' with a space
  # and spun forever against a healthy container.
  until curl -s "${AWS_ENDPOINT}/_localstack/health" | tr -d '[:space:]' | grep -qE "$pattern"; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 60 ]; then
      echo "ERROR: LocalStack did not become ready after 3 minutes." >&2
      echo "       Health payload:" >&2
      curl -s "${AWS_ENDPOINT}/_localstack/health" >&2 || true
      echo "" >&2
      if [ -n "$svc" ]; then
        echo "       ${svc} is a Pro service: check LOCALSTACK_PAT in .env." >&2
      fi
      return 1
    fi
    sleep 3
  done
}

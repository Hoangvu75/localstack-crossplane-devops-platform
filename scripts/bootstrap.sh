#!/usr/bin/env bash
# The whole imperative bootstrap, in one readable sequence. Idempotent: safe to re-run at
# any point, and re-running is the recovery path when a step failed halfway.
#
# ── Why these steps and no others ────────────────────────────────────────────
# Everything here exists because of a chicken-and-egg problem, not convenience. The test
# applied to each: could a controller already running in the cluster do this instead? If
# yes, it belongs in gitops/ and it is not here.
#
#   1. Cluster           nothing can run in-cluster before a cluster exists
#   2. Crossplane        the IaC engine; an engine cannot reconcile its own installation
#   3. Providers         the ProviderConfig CRD ships INSIDE the provider package, so a
#                        GitOps sync of it races the package install. ArgoCD also manages
#                        this directory afterwards (gitops/infrastructure/provider), which
#                        is what gives it self-heal — this run is only the cold start.
#   4. ArgoCD            the bootstrap paradox: ArgoCD cannot sync its own installation
#   5. git-credentials   a token in git is a token published
#   6. ApplicationSet    the single handover point; after this, git is in charge
#
# What is deliberately NOT here any more: ALB target registration and the CloudFront and
# Route53 wiring. Both need runtime values, both used to be one-shot host scripts you had
# to remember to re-run, and both are now a CronJob declared in
# gitops/platform/localstack-wiring/ that reconciles them on a two-minute loop.
. "$(dirname "$0")/lib.sh"

require_tool docker aws kubectl helm

CROSSPLANE_VERSION="1.16.0"

echo "=============================================================="
echo " Bootstrapping ${PROJECT_NAME}"
echo "=============================================================="

# ── 1. LocalStack and the EKS cluster ────────────────────────────────────────
echo ""
echo ">>> [1/6] LocalStack and the EKS cluster"

docker compose up -d localstack

echo "    waiting for the eks service to report available..."
wait_localstack eks

if aws_ eks describe-cluster --name "$CLUSTER_NAME" >/dev/null 2>&1; then
  echo "    cluster ${CLUSTER_NAME} already exists"
else
  # ── Why the subnets are discovered rather than written down ──────────────
  # This call used to pass the literal subnetIds=subnet-mock-1,subnet-mock-2. LocalStack
  # validates subnet ids against its own EC2 service and rejects invented ones:
  #     An error occurred (InvalidParameterException) when calling the CreateCluster
  #     operation: The subnet ID subnet-mock-2 does not exist
  #
  # The subnets CANNOT come from gitops/infrastructure/networking/, and that is the part
  # worth understanding. Those manifests are reconciled by Crossplane, which runs as a
  # Deployment INSIDE this cluster, so the cluster must exist before its own VPC can be
  # created. A control plane cannot provision the thing that hosts it.
  #
  # So the cluster sits in the account default VPC (172.31.0.0/16, created by LocalStack
  # at startup) while everything Crossplane manages lives in 10.0.0.0/16. On LocalStack
  # that split is metadata only: the k3d containers sit on a Docker network and pay no
  # attention to either CIDR. On real AWS you would create the cluster VPC in a separate
  # bootstrap stack and pass its subnet ids here instead — see README section 7.
  DEFAULT_VPC=$(aws_ ec2 describe-vpcs --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "")
  if [ -z "$DEFAULT_VPC" ] || [ "$DEFAULT_VPC" = "None" ]; then
    echo "ERROR: LocalStack reports no default VPC. It normally creates one at startup." >&2
    echo "       Check:  aws --endpoint-url ${AWS_ENDPOINT} ec2 describe-vpcs" >&2
    exit 1
  fi

  # EKS requires at least two subnets in different availability zones. The default VPC is
  # given one subnet per AZ, so the first two are always in different zones.
  BOOT_SUBNETS=$(aws_ ec2 describe-subnets --filters "Name=vpc-id,Values=${DEFAULT_VPC}" \
    --query 'Subnets[0:2].SubnetId' --output text 2>/dev/null | tr '\t' ',')
  if [ "$(echo "$BOOT_SUBNETS" | tr ',' '\n' | grep -c .)" -lt 2 ]; then
    echo "ERROR: fewer than two subnets in default VPC ${DEFAULT_VPC}." >&2
    echo "       Got: ${BOOT_SUBNETS:-none}" >&2
    exit 1
  fi

  echo "    creating cluster ${CLUSTER_NAME} in ${DEFAULT_VPC}"
  echo "    bootstrap subnets: ${BOOT_SUBNETS}"
  aws_ eks create-cluster \
    --name "$CLUSTER_NAME" \
    --role-arn "arn:aws:iam::000000000000:role/eks-cluster-role" \
    --resources-vpc-config "subnetIds=${BOOT_SUBNETS}" >/dev/null
  echo "    waiting for ACTIVE. On a first run LocalStack downloads k3d, docker-registry"
  echo "    and nginx into ./data/localstack first, so this takes 5-15 minutes."
  aws_ eks wait cluster-active --name "$CLUSTER_NAME"
fi

aws_ eks update-kubeconfig --name "$CLUSTER_NAME" >/dev/null
CLUSTER_ARN=$(aws_ eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.arn' --output text)

# The reported endpoint is addressed for the Docker network and carries a CA bundle for a
# certificate the host does not trust. From the host the API server is on a published port.
#
# The port is read rather than hardcoded: LocalStack allocates external ports from the
# 4510-4559 range, and 4510 is only the one it usually hands out first. The OpenTofu lab
# hardcoded 4510 and got away with it, right up until a second Pro service takes it.
CLUSTER_ENDPOINT=$(aws_ eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.endpoint' --output text)
API_PORT=$(echo "$CLUSTER_ENDPOINT" | sed -nE 's|.*:([0-9]+)/?$|\1|p')
API_PORT="${API_PORT:-4510}"
echo "    api server: ${CLUSTER_ENDPOINT} maps to https://127.0.0.1:${API_PORT} from the host"

kubectl config set-cluster "$CLUSTER_ARN" \
  --server="https://127.0.0.1:${API_PORT}" \
  --insecure-skip-tls-verify=true >/dev/null
# Leaving the CA bundle alongside --insecure-skip-tls-verify makes kubectl refuse to run:
# "specifying a root certificates file with the insecure flag is not allowed".
kubectl config unset "clusters.${CLUSTER_ARN}.certificate-authority-data" >/dev/null 2>&1 || true

if ! kubectl wait --for=condition=Ready nodes --all --timeout=300s >/dev/null; then
  echo "ERROR: no node reached Ready. Check 'docker ps' for the k3d containers and" >&2
  echo "       'kubectl cluster-info' for reachability of https://127.0.0.1:${API_PORT}." >&2
  exit 1
fi
echo "    nodes ready"

# ── Without this, nothing the lab installs can ever be scheduled ────────────
# LocalStack starts a single-node k3d cluster and leaves the k3s server carrying
#     node-role.kubernetes.io/control-plane=true:NoSchedule
# There is no second node, because nothing here calls `aws eks create-nodegroup`. So
# every workload without a matching toleration is unschedulable forever. kube-system
# pods (CoreDNS, metrics-server, local-path-provisioner) tolerate it and run, which
# makes the cluster look perfectly healthy.
#
# The symptom is two layers away from the cause. `helm --wait` sits until its timeout
# and then reports:
#     Error: context deadline exceeded
# naming neither the taint nor the pods. Only `kubectl -n crossplane-system describe
# pod` says what actually happened:
#     0/1 nodes are available: 1 node(s) had untolerated taint
#     {node-role.kubernetes.io/control-plane: true}
#
# The sibling learn-opensible lab never hit this: it created an EKS nodegroup, so LocalStack
# added untainted k3d agent containers and workloads landed there.
#
# Removing the taint is the right trade here rather than adding a nodegroup: a nodegroup
# means two more containers on a box that already has to run SigNoz/ClickHouse, and
# scheduling on the control plane is what every single-node local cluster does (kind,
# minikube and plain k3d all do it by default). If you want the more AWS-shaped topology,
# call `aws eks create-nodegroup` here instead and drop this.
#
# The trailing "-" is kubectl taint remove syntax. It errors when the taint is absent, so
# this has to swallow failure to stay idempotent across re-runs.
echo "    removing the control-plane NoSchedule taint (single-node cluster)"
kubectl taint nodes --all node-role.kubernetes.io/control-plane- >/dev/null 2>&1 || true
# Clusters older than k8s 1.24 spell it "master". Harmless when absent.
kubectl taint nodes --all node-role.kubernetes.io/master- >/dev/null 2>&1 || true

# Assert, because a silent failure here costs five minutes at the next helm --wait.
REMAINING=$(kubectl get nodes -o jsonpath='{.items[*].spec.taints[*].key}' 2>/dev/null | tr ' ' '\n' | grep -c "node-role.kubernetes.io" || true)
if [ "${REMAINING:-0}" -gt 0 ]; then
  echo "ERROR: a node-role NoSchedule taint survived. Nothing will schedule." >&2
  echo "       kubectl get nodes -o jsonpath='{.items[*].spec.taints}'" >&2
  exit 1
fi

# ── 2. Crossplane ────────────────────────────────────────────────────────────
echo ""
echo ">>> [2/6] Crossplane ${CROSSPLANE_VERSION}"

# ── Why the version is pinned ────────────────────────────────────────────────
# Unpinned, the chart resolves to the latest, which is now v2.x. Crossplane v2 REMOVED
# native patch-and-transform Composition, and
# gitops/infrastructure/compositions/composition-aws.yaml uses spec.resources, so it would
# be rejected outright. v1.17 deprecated it, v2.0 deleted it.
#
# 1.16.0 is the last release where spec.resources is fully supported. To move to v2, both
# halves have to happen together:
#   1. crossplane beta convert pipeline-composition \
#        gitops/infrastructure/compositions/composition-aws.yaml -o composition-aws.yaml
#   2. install the function it then depends on:
#        xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.7.0
helm repo add crossplane-stable https://charts.crossplane.io/stable --force-update >/dev/null 2>&1 || true
helm repo update crossplane-stable >/dev/null
helm upgrade --install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system --create-namespace \
  --version "${CROSSPLANE_VERSION}" --wait --timeout 5m >/dev/null
echo "    engine installed"

# ── 3. Providers and ProviderConfig ──────────────────────────────────────────
echo ""
echo ">>> [3/6] Upbound AWS providers"

kubectl apply -f gitops/infrastructure/provider/secret-credentials.yaml >/dev/null
kubectl apply -f gitops/infrastructure/provider/provider-aws.yaml >/dev/null

# ── Why this wait exists, and why it is not a wait on pods ───────────────────
# provider-config.yaml declares kind ProviderConfig, whose CRD ships inside the
# provider-family-aws package. Applying it immediately, as the old step 02 did, fails:
#     error: resource mapping not found for kind "ProviderConfig" ...
#     ensure CRDs are installed first
# and set -e aborts the run. The package needs 1-3 minutes to pull from xpkg.upbound.io,
# install a ProviderRevision, and register its CRDs.
#
# The old probe was wrong twice over: it ran AFTER the apply, and a provider pod reaching
# Ready does not mean its CRDs are served. condition=Healthy on the Provider object is the
# signal that the revision is active.
# ── Why this is a progress loop and not `kubectl wait` ──────────────────────
# It was `kubectl wait --for=condition=Healthy provider --all --timeout=600s`, which is
# both too short and silent. Measured on a cold cache: containerd pulls the eight
# provider images (200-400 MB each) SERIALLY, one starting roughly every two minutes, so
# the whole set needs 15-20 minutes. At 600s the run died with five of eight Healthy and
#     timed out waiting for the condition on providers/provider-aws-ec2
# while the node sat at 6% CPU and 28% memory. Nothing was wrong; the deadline was.
#
# The loop prints x/y as it goes, because ten minutes of no output is indistinguishable
# from a hang and invites killing a healthy run. The failure message distinguishes "still
# pulling" from "actually broken", since ContainerCreating means only that the pull has
# not finished.
#
# ec2, iam and s3 are consistently last: they carry by far the most CRDs.
echo "    waiting for Healthy. Eight images, 200-400 MB each, pulled serially by"
echo "    containerd -- budget 15-20 minutes on a cold cache."
PROV_DEADLINE=1800
PROV_WAITED=0
while true; do
  PTOT=$(kubectl get providers.pkg.crossplane.io --no-headers 2>/dev/null | wc -l | tr -d ' ')
  POK=$(kubectl get providers.pkg.crossplane.io --no-headers 2>/dev/null | awk '$2=="True" && $3=="True"' | wc -l | tr -d ' ')
  if [ "${PTOT:-0}" -gt 0 ] && [ "$POK" = "$PTOT" ]; then
    echo "    all ${PTOT} providers Healthy after ${PROV_WAITED}s"
    break
  fi
  if [ "$PROV_WAITED" -ge "$PROV_DEADLINE" ]; then
    echo "ERROR: ${POK}/${PTOT} providers Healthy after ${PROV_DEADLINE}s." >&2
    kubectl get providers.pkg.crossplane.io >&2
    echo "" >&2
    echo "       This is not necessarily broken. Check whether images are still coming:" >&2
    echo "         kubectl -n crossplane-system get pods" >&2
    echo "       ContainerCreating means the pull is still running -- just re-run this" >&2
    echo "       script, it is idempotent and picks up where this left off." >&2
    echo "       A CrashLoopBackOff or ImagePullBackOff is the real failure:" >&2
    echo "         kubectl -n crossplane-system describe pod -l pkg.crossplane.io/provider" >&2
    exit 1
  fi
  echo "    ${POK}/${PTOT} Healthy (${PROV_WAITED}s elapsed)"
  sleep 30
  PROV_WAITED=$((PROV_WAITED + 30))
done

until kubectl get crd providerconfigs.aws.upbound.io >/dev/null 2>&1; do sleep 2; done
kubectl wait --for=condition=Established crd/providerconfigs.aws.upbound.io --timeout=120s >/dev/null
kubectl apply -f gitops/infrastructure/provider/provider-config.yaml >/dev/null

# The four LocalStack toggles are snake_case in the CRD. In camelCase they are pruned
# silently and every S3 call then addresses a virtual-hosted URL. Assert, do not hope.
# The localstack-wiring CronJob re-checks this on every loop.
#
# The resource name is fully qualified, not the bare "providerconfig": once the providers
# are installed, both providerconfigs and providerconfigusages match that prefix and
# kubectl refuses with "error: you must specify only one resource". The count then comes
# back 0 and this assertion fires against a ProviderConfig that is completely correct.
TOGGLES=$(kubectl get providerconfigs.aws.upbound.io default -o json | grep -c 'skip_[a-z_]*": true' || true)
if [ "${TOGGLES}" -lt 4 ]; then
  echo "ERROR: expected 4 skip_ toggles on providerconfig/default, found ${TOGGLES}." >&2
  echo "       They were pruned by the API server. Check for camelCase field names in" >&2
  echo "       gitops/infrastructure/provider/provider-config.yaml." >&2
  exit 1
fi
echo "    providers Healthy, ProviderConfig applied, ${TOGGLES} toggles verified"

# ── 4. ArgoCD ────────────────────────────────────────────────────────────────
echo ""
echo ">>> [4/6] ArgoCD v2.13.2"

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -n argocd -f gitops/bootstrap/argocd/install-v2.13.2.yaml >/dev/null
kubectl -n argocd wait --for=condition=Available deployment/argocd-server --timeout=300s >/dev/null
echo "    server available"

# ── The two files that used to sit here doing nothing ───────────────────────
# gitops/bootstrap/argocd/server-params-cm.yaml and nodeport-svc.yaml were copied over
# from the sibling lab but never applied by anything, so the ArgoCD UI had no route in
# at all and port-forward was the only way to reach it.
#
# They have to be applied in this order and AFTER the install, because the install
# manifest ships its own argocd-cmd-params-cm and would overwrite the override.
#
#   server-params-cm  sets server.insecure=true, which is what makes argocd-server
#                     listen plain HTTP on 8080. Without it the NodePort below targets a
#                     port that speaks TLS, and the ALB health check gets a protocol
#                     error rather than a 200.
#   nodeport-svc      exposes that port as NodePort 30081, which is a contract with the
#                     target group in gitops/infrastructure/loadbalancer/alb-argocd.yaml.
echo "    applying server.insecure and the NodePort service"
kubectl apply -f gitops/bootstrap/argocd/server-params-cm.yaml >/dev/null
# Excludes Tekton PipelineRun/TaskRun from ArgoCD entirely. Without it ArgoCD prunes
# running builds about 45 seconds in, because they are created at runtime and are not in
# git. See the file for the full story.
kubectl apply -f gitops/bootstrap/argocd/resource-exclusions-cm.yaml >/dev/null
kubectl apply -f gitops/bootstrap/argocd/nodeport-svc.yaml >/dev/null

# argocd-server reads cmd-params only at startup, so the ConfigMap alone changes nothing
# until the pod is replaced.
kubectl -n argocd rollout restart deployment/argocd-server >/dev/null
kubectl -n argocd rollout restart statefulset/argocd-application-controller >/dev/null
kubectl -n argocd rollout status deployment/argocd-server --timeout=180s >/dev/null
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=180s >/dev/null
echo "    server restarted with plain HTTP on NodePort 30081"

# ── 5. The credential that connects CI to CD ─────────────────────────────────
echo ""
echo ">>> [5/6] git-credentials Secret"

# gitops/platform/tekton/ci/task-git-update-workloads.yaml mounts a Secret named
# git-credentials to push updated image tags back to git. Nothing created it: the name
# appeared exactly once in the whole repository, on the line that consumed it.
#
# The secrets step puts the token in Secrets Manager, which is the right place, because git
# holds no secrets. But Secrets Manager is not readable from a Tekton step without AWS
# tooling and credentials in the pod, so the token is materialised into the cluster once,
# here, at the only point in the lifecycle that already has both AWS access and kubectl.
#
# Symptom this fixes: the pipeline ran green, images reached ECR, and ArgoCD kept deploying
# the previous tag forever, because the push step took its else branch and printed
# "Skipping git push".
TOKEN=$(aws_ secretsmanager get-secret-value --secret-id "$SECRET_NAME_GITHUB" \
  --query SecretString --output text 2>/dev/null || echo "")

if [ -z "$TOKEN" ] || [ "$TOKEN" = "dummy_token_for_local_testing" ]; then
  echo "    WARNING: no usable token in Secrets Manager (${SECRET_NAME_GITHUB})." >&2
  echo "             The Tekton git push step will fail with an explicit error until you" >&2
  echo "             set GITHUB_TOKEN in .env and re-run: make secrets && make bootstrap" >&2
  echo "             Everything else works." >&2
else
  # The namespace does not exist yet, because ArgoCD creates it when it syncs the tekton
  # Application, so create it here rather than depending on sync ordering.
  kubectl create namespace tekton-ci --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # dry-run piped to apply rather than create secret, so re-running rotates the value
  # instead of failing with AlreadyExists.
  kubectl -n tekton-ci create secret generic git-credentials \
    --from-literal=token="$TOKEN" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "    created in tekton-ci (value not echoed)"

  # ── ArgoCD repository credential ──────────────────────────────────────
  # Required whenever the repo is PRIVATE, which this one is. Without it the git files
  # generator cannot list gitops/*/*/config.yaml, so it returns an empty result and the
  # ApplicationSet creates zero Applications. Nothing errors in a way you would notice:
  # `kubectl get applicationset` shows the object as present and healthy, and the only
  # signal is that `kubectl -n argocd get applications` stays empty.
  #
  # The label is what makes ArgoCD read the Secret at all; a correctly shaped Secret
  # without it is ignored.
  #
  # username=x-access-token is the GitHub convention for authenticating with a PAT over
  # HTTPS. Any non-empty username works, but this one is what GitHub documents.
  kubectl -n argocd create secret generic repo-${PROJECT_NAME} \
    --from-literal=type=git \
    --from-literal=url="${GITHUB_REPO_URL}" \
    --from-literal=username=x-access-token \
    --from-literal=password="$TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n argocd label secret repo-${PROJECT_NAME} \
    argocd.argoproj.io/secret-type=repository --overwrite >/dev/null
  echo "    ArgoCD repository credential created for ${GITHUB_REPO_URL}"
fi

# ── 6. Handover ──────────────────────────────────────────────────────────────
echo ""
echo ">>> [6/6] ApplicationSet, git takes over from here"

kubectl apply -f gitops/bootstrap/appset.yaml >/dev/null

# The git generator polls, so zero Applications immediately after the apply is normal.
# Zero after 60 seconds is not, and it is the signature of a repo the generator cannot
# read: wrong branch, or a private repo with no credential. Checked here because the
# alternative is discovering it twenty minutes later when nothing has deployed.
echo "    applied, waiting for the git generator to produce Applications..."
APP_COUNT=0
for _ in $(seq 1 12); do
  APP_COUNT=$(kubectl -n argocd get applications --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "${APP_COUNT}" -gt 0 ]; then break; fi
  sleep 5
done

if [ "${APP_COUNT}" -eq 0 ]; then
  echo "" >&2
  echo "WARNING: the ApplicationSet generated 0 Applications after 60s. The generator" >&2
  echo "         cannot read the repository. The three causes, in order of likelihood:" >&2
  echo "" >&2
  echo "  1. Branch mismatch. The appset asks for revision \"main\"; check what exists:" >&2
  echo "       git branch --show-current  &&  git ls-remote --heads origin" >&2
  echo "  2. Nothing pushed yet. ArgoCD reads GitHub, never this working copy." >&2
  echo "  3. Private repo, bad or missing credential:" >&2
  echo "       kubectl -n argocd logs deploy/argocd-applicationset-controller --tail=30" >&2
  echo "" >&2
else
  echo "    ${APP_COUNT} Applications generated"
fi

ADMIN_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A")

cat <<INFO

==============================================================
 Bootstrap complete. Nothing else is imperative.
==============================================================

ArgoCD    kubectl -n argocd port-forward svc/argocd-server 8080:80
          http://localhost:8080   admin / ${ADMIN_PASS}

From here the cluster converges on its own. The localstack-wiring CronJob registers the
ALB target and patches the CloudFront origin and Route53 alias every two minutes, so the
entry URLs appear without another command.

Watch it:   make status
INFO

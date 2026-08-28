# learn-crossplane — AWS + Crossplane DevOps Platform on LocalStack

An end-to-end Kubernetes-native DevOps platform **running entirely on a local machine**:

- **Infrastructure as Code** — declared as Kubernetes custom resources with **Crossplane**, continuously reconciled.
- **Continuous Integration** — Kubernetes-native pipelines, triggers and dashboard with **Tekton**.
- **Continuous Delivery** — pull-based GitOps with **ArgoCD**, one ApplicationSet.
- **Microservices** — six services on EKS, served via ALB → CloudFront.
- **Observability** — **OpenTelemetry Operator + Collector + SigNoz** for traces, logs and metrics.
- **Zero cloud cost** — every AWS service emulated by **LocalStack Pro**.

This is the second lab in a pair. The first, `learn-opensible`, builds the same platform with
OpenTofu + Ansible + AWS CodeBuild. Where the two differ this README says so — those
differences are the point of the exercise, and §6.1 is the honest list of places where
Crossplane made things *harder* than Terraform did.

---

## 0. Architecture Overview

```mermaid
flowchart TD
    subgraph Host["Developer Machine"]
        ENV[".env (GITHUB_TOKEN, LOCALSTACK_PAT)"]
        SCRIPTS["scripts/*.sh · Makefile"]
    end

    subgraph LS["LocalStack Pro Gateway (:4566)"]
        LSEKS["LocalStack EKS (k3d cluster)"]
        AWS_S3["S3 (CI/CD artifacts)"]
        AWS_ECR["ECR (6 repositories)"]
        AWS_NET["VPC · Subnets · IGW · RouteTables · SG"]
        AWS_ALB["ALB + TargetGroup (:30080)"]
        AWS_CF["CloudFront distribution"]
        AWS_R53["Route53 (learn-crossplane.internal)"]
        AWS_SM["Secrets Manager (GitHub PAT)"]
    end

    subgraph K8S["EKS Cluster"]
        subgraph CP["crossplane-system"]
            CP_CORE["Crossplane 1.16.0"]
            UP_AWS["Upbound AWS providers<br/>s3 · ecr · ec2 · elbv2 · iam · cloudfront · route53"]
            PC["ProviderConfig to http://localstack:4566"]
        end

        subgraph TEKTON["tekton-pipelines + tekton-ci"]
            TEK_PIPE["Pipeline: git-clone, build+push, git-update"]
            TEK_TRIG["EventListener + github/CEL interceptors"]
            TEK_DASH["Dashboard (:9097)"]
            TEK_SEC["Secret: git-credentials"]
        end

        subgraph ARGO["argocd"]
            APPSET["One ApplicationSet"]
        end

        subgraph PLAT["Platform"]
            NGX["ingress-nginx (:30080)"]
            CERT["cert-manager"]
            PANDA["redpanda (Kafka)"]
            OTEL["otel-operator + collector"]
            SIG["signoz"]
        end

        subgraph APPS["devops-apps"]
            WEB["web (:3000)"]
            REST["rest-service (:4000)"]
            METRICS["cpu :4001 · memory :4002<br/>disk :4003 · history :4004"]
        end
    end

    ENV -->|"00 ingest secret"| AWS_SM
    SCRIPTS -->|"01 bootstrap cluster"| LSEKS
    SCRIPTS -->|"02 install engine, wait Healthy"| CP
    AWS_SM -->|"03 materialise token"| TEK_SEC
    SCRIPTS -->|"03 bootstrap GitOps"| ARGO
    AWS_ALB -->|"04 patch runtime DNS name"| AWS_CF
    AWS_ALB -->|"04 patch alias record"| AWS_R53

    APPSET -->|"sync infrastructure CRs"| CP
    UP_AWS -->|"reconcile, correct drift"| LS
    APPSET -->|"sync Tekton"| TEKTON
    APPSET -->|"sync platform"| PLAT
    APPSET -->|"sync workloads"| APPS

    TEK_PIPE -->|"build, push images"| AWS_ECR
    TEK_PIPE -->|"commit new image tags"| APPSET

    AWS_ALB -->|"NodePort :30080"| NGX
    NGX --> WEB
    NGX --> REST
```

Four flows, in order:

1. **Bootstrap** — steps 00 to 04 are imperative on purpose. §3.3 explains which parts cannot be GitOps, and why.
2. **IaC** — ArgoCD syncs `gitops/infrastructure/`; Crossplane reconciles it into LocalStack and corrects drift.
3. **CI/CD** — a commit runs the Tekton pipeline, which pushes images to ECR and then **writes the new tags back to git**; ArgoCD deploys them.
4. **Request** — browser → CloudFront → ALB → ingress-nginx → web / rest-service → the four metric services → Redpanda.

---

## 1. Why Tekton instead of CodeBuild

The trigger is the reason. LocalStack's CodeBuild cannot start a build from a git push
without mocking SNS and Lambda, so `learn-opensible` always kicked builds off by hand.

| | AWS CodeBuild on LocalStack | Tekton |
| :--- | :--- | :--- |
| **Execution** | LocalStack's own container wrapper | native Pods and CRDs (`Task`, `Pipeline`, `PipelineRun`) |
| **Trigger** | needs SNS/Lambda mocking | `EventListener` + `TriggerBinding` + interceptors, built in |
| **Definition** | `buildspec.yml` | declarative Kubernetes YAML, managed by GitOps like everything else |
| **UI** | LocalStack container logs | Dashboard with per-step logs and a pipeline graph |
| **Portability** | AWS only | any Kubernetes cluster |

**What this lab does and does not deliver on that promise.** The trigger machinery is real
and wired: interceptors filter the event, a `TriggerTemplate` creates the `PipelineRun`. But
an `EventListener` on a laptop is not reachable from GitHub, and nothing here registers a
webhook on the GitHub side. So the trigger is **still manual today**: `make run-ci` starts a
run. §8.2 covers the three ways to make it genuinely automatic, the loop prevention that
becomes mandatory the moment you do, and the curl that exercises the interceptor chain.

---

## 2. Repository Structure

```
learn-crossplane/
├── apps/                                Source and Dockerfiles (6 microservices)
│   ├── web/                             Next.js 14 frontend        node:20-alpine    :3000
│   ├── rest-service/                    Go API gateway             distroless        :4000
│   ├── cpu-service/                     TypeScript / Node          node:20-alpine    :4001
│   ├── memory-service/                  Python                     python:3.12-slim  :4002
│   ├── disk-service/                    Java / Maven               temurin:21-jre    :4003
│   └── history-service/                 Python Kafka consumer      python:3.12-slim  :4004
├── gitops/                              GitOps single source of truth
│   ├── bootstrap/                       Applied once, by hand
│   │   ├── argocd/                      ArgoCD v2.13.2
│   │   └── appset.yaml                  the one ApplicationSet, discovers every config.yaml
│   ├── infrastructure/                  Crossplane managed resources
│   │   ├── provider/                    wave 1   Upbound providers, credentials, ProviderConfig
│   │   ├── iam/                         wave 1   platform role and policy
│   │   ├── compositions/                wave 1   XRD, Composition, example claim
│   │   ├── networking/                  wave 2   VPC, subnets, IGW, route tables, SG + rules
│   │   ├── storage/                     wave 2   S3 artifacts bucket (versioning, SSE, lifecycle)
│   │   ├── registry/                    wave 2   6 ECR repositories + lifecycle policies
│   │   ├── loadbalancer/                wave 2   ALB, TargetGroup (:30080), HTTP listener
│   │   └── cdn-dns/                     wave 3   CloudFront, Route53 zone and record
│   ├── platform/
│   │   ├── ingress-nginx/               wave 0   NodePort 30080
│   │   ├── cert-manager/                wave 5   issues the OTel operator webhook cert
│   │   ├── localstack-wiring/           wave 4   CronJob: ALB target + CF/Route53 wiring
│   │   ├── tekton/                      wave 8   Pipelines, Triggers, Dashboard (all vendored)
│   │   ├── redpanda/                    wave 12  Kafka-compatible queue
│   │   ├── otel-operator/               wave 15  injects auto-instrumentation agents
│   │   ├── signoz/                      wave 22  observability backend
│   │   └── otel-collector/              wave 24  cluster telemetry pipeline
│   └── workloads/
│       ├── _shared/                     wave 30  Namespace, Ingress, Instrumentation
│       └── <service>/                   wave 35  Deployment, Service, Kustomization
├── scripts/                             Four files. See §3.3 for why not fewer, and not more
│   ├── lib.sh                           Sourced by all: loads .env, anchors cwd, aws_() helper
│   ├── secrets.sh                       GITHUB_TOKEN into AWS Secrets Manager
│   ├── bootstrap.sh                     Cluster, Crossplane, providers, ArgoCD, ApplicationSet
│   └── destroy.sh                       Teardown (--purge-data for a clean slate)
├── docker-compose.yml                   LocalStack Pro
├── Makefile                             One-command lifecycle
└── PROJECT_RULES.md                     Safety rules and the CRD-pruning traps
```

Adding a component is: create a directory and a five-field `config.yaml`
(`name`, `namespace`, `manifestPath`, `syncWave`, `prune`). No script edit, no hand-written
Application.

---

## 3. Getting Started

### 3.1 Prerequisites

- Docker Desktop
- A **LocalStack Pro** auth token — EKS, ECR and CloudFront are Pro-only
- A **GitHub PAT with `repo` write scope** — the pipeline pushes image tags back
- `awscli`, `kubectl`, `helm`, `git`, `curl`
- A POSIX shell. On Windows use Git Bash or WSL — the scripts are bash, not PowerShell.

### 3.2 Environment setup

```bash
cp .env.example .env
```

```env
LOCALSTACK_PAT=your_localstack_pro_token
GITHUB_TOKEN=your_github_token
```

Then push this repository to GitHub. **ArgoCD and the Tekton pipeline both clone from
GitHub, never from your working copy** — the repo URL is set in `gitops/bootstrap/appset.yaml`
and `gitops/platform/tekton/ci/pipeline.yaml`. Local edits do nothing until they are pushed.

### 3.3 What runs imperatively, and why

`scripts/` holds four files, two of which are a library and a teardown. That is deliberate,
and the test applied to every candidate was: **could a controller already running in the
cluster do this instead?** If yes, it belongs in `gitops/` and it is not a script.

Two things failed that test for a long time and have since moved into the cluster as the
`localstack-wiring` CronJob: ALB target registration and the CloudFront/Route53 wiring. Both
need values that only exist at runtime, which is why they started out as scripts — but
"needs a runtime value" argues for a *controller*, not for a script you have to remember to
re-run. As a CronJob they are declared in git, versioned with everything else, and
self-healing on a two-minute loop.

What is left cannot move, because of a chicken-and-egg problem rather than convenience:

| Step | Why not GitOps |
| :--- | :--- |
| EKS cluster | Nothing can run in-cluster before a cluster exists. |
| ArgoCD install | The bootstrap paradox: ArgoCD cannot sync its own installation. |
| Crossplane + providers | The `ProviderConfig` CRD ships *inside* the provider package. Until the package is Healthy the kind does not exist, and any Application referencing it fails, so the cold start waits on `condition=Healthy` before applying. ArgoCD adopts the directory afterwards, which is what gives it self-heal. |
| `git-credentials` Secret | Read from Secrets Manager. A token in git is a token published. |

And what moved into the cluster:

| Now handled by | Job |
| :--- | :--- |
| `gitops/platform/localstack-wiring/` | Registers `<node-ip>:30080` in the ALB target group (k3d gives the node a new IP on every recreation), patches the CloudFront origin and Route53 alias from the ALB status, and re-asserts that the ProviderConfig toggles survived schema validation. Every two minutes, comparing before every write. |

Everything else is discovered from `gitops/` by the ApplicationSet.

**On prune and blast radius.** Each `config.yaml` sets `prune` per component. `ingress-nginx`
and `infrastructure/provider` use `prune: false` — pruning either takes down the whole
cluster network or the whole IaC control plane. The `devops-apps` Namespace instead carries a
resource-level `argocd.argoproj.io/sync-options: Prune=false`, so the Ingress and
Instrumentation next to it still prune normally. Disabling prune for a whole Application to
protect one resource is the wrong level: it deadlocks an Ingress rename against the nginx
admission webhook.

**On sync waves.** The numbers in §2 document intent; they do not enforce it. `sync-wave`
orders resources only when a *parent* Application syncs its children (app-of-apps). The
ApplicationSet controller creates all Applications simultaneously, so what actually produces
convergence is the `retry` block in the appset plus the fact that `bootstrap.sh` installs
Crossplane before ArgoCD exists. Waves *within* a single Application work normally.

---

## 4. Workflows & Execution

```bash
make all      # everything below, in order
```

Or step by step:

```bash
make up          # 1. start LocalStack Pro
make secrets     # 2. GITHUB_TOKEN into Secrets Manager (refreshes the in-cluster copy too)
make bootstrap   # 3. cluster, Crossplane, providers, ArgoCD, ApplicationSet
```

That is the whole lifecycle. After step 3 nothing else is imperative: ArgoCD syncs
everything under `gitops/`, and the `localstack-wiring` CronJob handles the two pieces of
state that need runtime values. There is no step to remember after the ALB appears.

`make bootstrap` is idempotent — re-running it is the recovery path when a step failed
halfway, and it is how you apply a rotated token.

Watching it converge (the slowest link is Crossplane reconciling the VPC, subnets and
security group before the ALB can exist):

```bash
make status      # providers, managed resources, applications, pods, CI, entry URLs
```

Other verbs:

```bash
make run-ci      # start a PipelineRun by hand
make destroy     # stop everything, keep ./data/localstack
make purge       # also delete ./data/localstack (prompts; ~20 min to rebuild)
```

`make status` reads the entry URLs out of the `localstack-wiring` log rather than querying
AWS itself, so whatever it prints is what the last reconcile actually saw.

---

## 5. Web UIs & Endpoints

| Component | Address | How |
| :--- | :--- | :--- |
| **ArgoCD** | `http://localhost:8080` | `kubectl -n argocd port-forward svc/argocd-server 8080:80` — user `admin`, password printed by step 03 |
| **Tekton Dashboard** | `http://localhost:9097` | `kubectl -n tekton-pipelines port-forward svc/tekton-dashboard 9097:9097` |
| **SigNoz** | `http://localhost:3301` | `kubectl -n signoz port-forward svc/signoz-frontend 3301:3301` |
| **Web app via ALB** | `http://<alb-dns>:4566/` | ALB DNS name printed by steps 04 and 05 |
| **Web app via CloudFront** | `http://<dist-id>.cloudfront.localhost.localstack.cloud:4566/` | printed by step 04 |
| **Tekton webhook** | `http://<alb-dns>:4566/tekton-webhook` | POST only; this is the URL to aim a tunnel at |
| **LocalStack gateway** | `http://localhost:4566` | |

The `:4566` is not optional — LocalStack binds nothing on port 80 and multiplexes every
emulated endpoint behind its gateway, routing by `Host` header.

Browser UIs use `port-forward` rather than an Ingress host because invented
`*.localhost.localstack.cloud` names never reach the cluster. §6.3.

---

## 6. LocalStack Limitations

### 6.1 Crossplane + LocalStack

| Symptom | Cause | Workaround |
| :--- | :--- | :--- |
| ProviderConfig accepted, but S3 calls go to `http://bucket.localstack:4566` | The CRD names its toggles in **snake_case** (`s3_use_path_style`, `skip_credentials_validation`, …). camelCase is pruned silently by the API server. | Use the exact CRD spelling. Step 02 asserts four toggles survived and aborts if not. |
| Endpoint host rewritten per service (`s3.localstack`, `ecr.localstack`) | The AWS SDK derives per-service hostnames unless told otherwise | `spec.endpoint.hostnameImmutable: true` |
| `no matches for kind "ProviderConfig"` during step 02 | The CRD ships inside the provider package and is not registered until it installs | Wait for `condition=Healthy` on the Provider, then for the CRD to be Established |
| ALB created with no subnets | `subnetIdRefs` does not exist on elbv2 `LB`. The AWS field is `subnets`, so the helper is `subnetRefs`. | Match the suffix to the AWS field name. `subnetIdRef` on `RouteTableAssociation` is correct because *its* field is `subnetId`. |
| CloudFront never created | `origin[].domainName` has no `*Ref`/`*Selector` — elbv2 `LB` is not wired as a reference target | the `localstack-wiring` CronJob patches the value; the appset lists the path under `ignoreDifferences` |
| CloudFront `Distribution` and Route53 `Zone`/`Record` rejected | `spec.forProvider.region` is **required**, even though both are global services | Set it. IAM is the one exception here — its CRDs have no `region` field at all, so adding one would be pruned. |
| `Route` stuck at `cannot resolve references` | `matchControllerRef: true` matches only resources composed by the same composite; these are standalone | Use a direct `gatewayIdRef`. |
| Composition rejected after a Crossplane upgrade | v2 removed native patch-and-transform (`spec.resources`) | Pinned to 1.16.0. Migration command is in step 02. |

**The general shape of it.** Crossplane's structural CRDs turn a typo into a silent no-op
where Terraform would have failed at `plan`. Every row above was a manifest that applied
cleanly and did nothing. `kubectl get managed` and its SYNCED column are what make this
tractable — see PROJECT_RULES §2.

### 6.2 ECR & EKS

| Symptom | Cause | Workaround |
| :--- | :--- | :--- |
| Registry host:port cannot be guessed | LocalStack allocates external ports from 4510–4559 | Query it: `aws ecr describe-repositories --query 'repositories[0].repositoryUri'` |
| `kubectl` TLS errors after `update-kubeconfig` | The reported endpoint is addressed for the Docker network and carries an untrusted CA | `kubectl config set-cluster --server=https://127.0.0.1:<port> --insecure-skip-tls-verify=true` **and unset** `certificate-authority-data` |
| `docker push` fails with `x509: certificate is valid for *.localhost.localstack.cloud` | The ECR host has four labels below the wildcard, and a TLS wildcard matches exactly one | Start the build daemon with `--insecure-registry <ecr-host>`. The k3d nodes get this from LocalStack automatically; a hand-started dind does not. |
| Node IP changes after cluster recreation | k3d reallocates container IPs | the `localstack-wiring` CronJob re-registers the target every two minutes |
| `Waiter ClusterActive failed ... matched expected path: "FAILED"`, plus `Timeout while waiting for EKS startup` in the LocalStack log | Reads like a slow machine; it is not. The default `K3S_IMAGE_TAG=1.36` resolves to a k3s that **dropped cgroup v1 support**, and the Docker Desktop WSL2 VM presents cgroup v1. The kubelet refuses to start and k3s exits ~3s in, so readiness polling times out at 150s. The k3d containers stay `Up` throughout, because the serverlb is a separate healthy nginx. | `K3S_IMAGE_TAG=v1.31.14-k3s1` in `docker-compose.yml` — the last line supporting cgroup v1. The real error is only visible in `docker logs k3d-<cluster>-server-0`. Host-wide alternative: give WSL2 cgroup v2 via `kernelCommandLine = cgroup_no_v1=all` in `%UserProfile%\.wslconfig`. |
| `helm --wait` ends in `Error: context deadline exceeded`, and pods sit `Pending` | LocalStack starts a **single-node** cluster and leaves `node-role.kubernetes.io/control-plane=true:NoSchedule` on the k3s server. Nothing calls `create-nodegroup`, so there is no untainted node. kube-system pods tolerate the taint and run, so the cluster looks healthy. The real message is only in `kubectl describe pod`: `1 node(s) had untolerated taint`. | `kubectl taint nodes --all node-role.kubernetes.io/control-plane-`, done by `bootstrap.sh` right after the nodes report Ready. The sibling lab avoided this by creating an EKS nodegroup, which gives untainted k3d agent containers. |
| `InvalidParameterException: The subnet ID subnet-mock-2 does not exist` on `create-cluster` | LocalStack validates subnet ids against its own EC2 service, so invented ids are rejected | discover them: the cluster goes in the account default VPC, because Crossplane runs *inside* this cluster and cannot provision the VPC that hosts it |
| `ImagePullBackOff` with `x509: certificate has expired` | LocalStack's cached certificate is valid ~90 days | Restart the container: `docker compose up -d localstack` |

### 6.3 ALB, CloudFront, Route53

| Symptom | Cause | Workaround |
| :--- | :--- | :--- |
| `http://<alb-dns>/` unreachable | Nothing is bound on port 80 | Append `:4566` |
| CloudFront returns blank responses | The origin defaults to port 80 | `customOriginConfig.httpPort: 4566` |
| CloudFront serves blank HTML in a browser while `curl` works | The proxy returns an uncompressed body with `Content-Encoding: gzip` | `compress: false` in `apps/web/next.config.js` |
| `www.learn-crossplane.internal` returns 200 with an empty body | **The gateway routes by its own static hostname patterns and never consults Route53 records** | Use the ALB or CloudFront domain directly |
| An Ingress host like `tekton.localhost.localstack.cloud` never reaches the cluster | Same cause — the gateway has no knowledge of an Ingress inside k3d | `port-forward`, or a path rule on the host-less Ingress reached through the ALB |

### 6.4 CSRF protection

The web app loads HTML but no CSS or JS (`403` on `/_next/static/*`). LocalStack's CSRF
mitigation rejects requests whose `Origin`/`Referer` is not allowlisted: a browser sends none
for the top-level document but one for every subresource, so the page renders unstyled and
never hydrates. `DISABLE_CORS_CHECKS=1` in `docker-compose.yml`. Local lab only — the check
has no AWS counterpart, so disabling it changes nothing about the emulated services.

### 6.5 DNS hijacking of real CDNs

LocalStack is the DNS server for containers it creates, including the k3d nodes, and answers
for domains it considers AWS-shaped. `registry.k8s.io` redirects image blobs to real
CloudFront, LocalStack intercepts `*.cloudfront.net` with its own certificate, and containerd
fails verification — `ImagePullBackOff` on ingress-nginx.

`DNS_NAME_PATTERNS_TO_RESOLVE_UPSTREAM` in `docker-compose.yml` forces those domains to real
upstream DNS. It does **not** affect emulated CloudFront
(`*.cloudfront.localhost.localstack.cloud`) or ECR.

This is also why every upstream manifest is vendored (PROJECT_RULES §7): a remote `kustomize`
base on a host that is not in that allowlist fails at sync time, inside the ArgoCD
repo-server, with an error that looks nothing like DNS.

---

## 7. Migrating to Real AWS

| # | Component | Change |
| :-- | :--- | :--- |
| 1 | **ProviderConfig** | Delete the whole `spec.endpoint` block and the four `skip_*` toggles. Turn `s3_use_path_style` off. |
| 2 | **Credentials** | Replace the `aws-creds` Secret with IRSA: annotate the provider ServiceAccount with a role ARN and set `source: IRSA`. Delete `secret-credentials.yaml` from git. |
| 3 | **Compositions** | Migrate to Crossplane v2: `crossplane beta convert pipeline-composition`, install `function-patch-and-transform`, then unpin the chart in step 02. |
| 4 | **CloudFront origin, Route53 alias** | Replace the `localstack-wiring` CronJob with a Composition that hops the ALB `status.atProvider.dnsName` through the composite, then delete `gitops/platform/localstack-wiring/` and the two `ignoreDifferences` entries with it. Also set `customOriginConfig.httpPort: 80`. |
| 5 | **Route53 alias zone id** | Use the ALB real canonical hosted zone id (us-east-1: `Z35SXDOTRQ7X7K`), and delegate the domain NS records. |
| 6 | **Security groups** | The rules in `networking/security-groups.yaml` become enforced. Narrow the `0.0.0.0/0` ingress and drop the blanket egress. |
| 7 | **ALB targets** | Switch `targetType` to `instance` and attach the target group to an Auto Scaling group. Then delete the imperative `register-targets` calls in steps 03 and 05. |
| 8 | **Multi-AZ NAT** | Add NAT gateways per AZ with dedicated route tables. |
| 9 | **TLS** | Issue ACM certificates in `us-east-1` for CloudFront, add an HTTPS listener, redirect HTTP. |
| 10 | **ECR immutability** | `imageTagMutability: IMMUTABLE`. Tags are already commit SHAs, so nothing else changes. |
| 11 | **Tekton registry auth** | Drop `--insecure-registry`, keep the `aws ecr get-login-password` login, and add the AWS CLI to the build image so it is no longer conditional. |
| 12 | **Webhook secret** | Add `secretRef` to the github interceptor (§8.2). Non-negotiable once the listener is public. |
| 13 | **GitHub token** | Revoke the development PAT; use a GitHub App or a dedicated CI secret. |
| 14 | **kubeconfig** | Remove `--insecure-skip-tls-verify` and restore the CA bundle. |
| 15 | **LocalStack-only flags** | Remove `DISABLE_CORS_CHECKS`, `DNS_NAME_PATTERNS_TO_RESOLVE_UPSTREAM`, `compress: false`. |

---

## 8. CI: how a push becomes a deployment

### 8.1 The pipeline

`gitops/platform/tekton/ci/pipeline.yaml`, three tasks over one shared PVC workspace:

1. **`git-clone`** — checks out the revision. It accepts a branch, a tag, **or a full commit
   SHA**, and detects which it was given. This matters: the `TriggerBinding` feeds it
   `body.head_commit.id`, and `git clone --branch <sha>` is not a thing — `--branch` accepts
   only a branch or a tag. That single mismatch meant every webhook-driven run died at step
   one, while manual runs, which pass `main`, worked perfectly.
2. **`monorepo-build-and-push`** — builds all six images in a privileged dind step and pushes
   them to LocalStack ECR tagged with the 7-character short SHA. Failures are collected per
   service and the task exits non-zero. It previously ended in
   `docker push … || echo "Pushed or simulated push"`, which made every push failure a green
   build; the missing images were then referenced by tag, synced, and surfaced as
   `ImagePullBackOff` three steps away from the actual error.
3. **`git-update-workloads`** — runs `kustomize edit set image` in each
   `gitops/workloads/<service>/` directory and pushes the commit. **This is the handover from
   CI to CD**: ArgoCD watches git, not ECR, so an image nobody wrote a tag for is an image
   nobody deploys.

The token comes from the `git-credentials` Secret created by step 03. If it is missing the
task fails loudly rather than skipping — the earlier version printed `Skipping git push` and
exited 0, so CI and CD were never actually connected and nothing said so.

One `kustomization.yaml` per service, so two concurrent builds cannot clobber each other.

### 8.2 Triggering — what works and what does not

**Works today:** `make run-ci` creates a `PipelineRun` directly. To exercise the
interceptors as well — which is what you want before wiring a real webhook — POST a
GitHub-shaped payload at the listener:

```bash
kubectl -n tekton-ci port-forward svc/el-ci-webhook-listener 8089:8080 &
curl -X POST http://127.0.0.1:8089 -H 'X-GitHub-Event: push' -H 'Content-Type: application/json' \
  -d '{"ref":"refs/heads/main","head_commit":{"id":"'"$(git rev-parse HEAD)"'","message":"test"},"repository":{"clone_url":"https://github.com/Hoangvu75/localstack-crossplane-devops-platform.git"}}'
```

All three fields matter: `X-GitHub-Event` satisfies the github interceptor, and `ref` plus
`head_commit.message` are what the CEL filter reads. Drop the message and the expression
errors instead of filtering.

**Does not work today:** GitHub calling the listener. It is not reachable from the internet
and no webhook is registered. Three ways to fix that, cheapest first:

| Option | How | Trade-off |
| :--- | :--- | :--- |
| **Tunnel** | `cloudflared tunnel --url http://<alb-dns>:4566/tekton-webhook`, then add the public URL as a webhook on the GitHub repo | Real push-based CI. **Add `secretRef` to the github interceptor first** — an open listener builds and pushes whatever anyone POSTs to it. |
| **Polling** | A `CronJob` comparing `origin/main` against the last built SHA and creating a `PipelineRun` on change. `gitops/platform/localstack-wiring/` is the template to copy: same shape, same RBAC pattern, one more `ClusterRole` rule for `pipelineruns`. | No inbound exposure. Latency equal to the poll interval. Must read the head commit message so `[skip ci]` still breaks the loop. |
| **Local git hook** | `.git/hooks/pre-push` running the curl above | Zero infrastructure. Only fires for pushes from your machine. |

**The loop, and why the filter is not optional.** The last task pushes a commit to `main`.
With a live webhook that push triggers a build, which pushes again — unbounded. Two things
stop it and both are required:

- the commit message carries `[skip ci]`;
- the CEL interceptor in `ci/triggers.yaml` reads it:

```
body.ref == 'refs/heads/main' && has(body.head_commit) && !body.head_commit.message.contains('[skip ci]')
```

The marker alone is decoration — before the filter existed, nothing read it. `has(...)`
guards branch-deletion and tag events, where `head_commit` is null and dereferencing
`.message` errors out instead of filtering.

When an event is accepted but no `PipelineRun` appears, the reason is only in the listener's
own log:

```bash
kubectl -n tekton-ci logs -l eventlistener=ci-webhook-listener --tail=50
```

---

## 9. Observability

### 9.1 The pipeline

Every pod ships to the OpenTelemetry Collector in the `observability` namespace, which fans
out to SigNoz. Applications hold no backend configuration: endpoint, protocol and batching
live in one `Instrumentation` CR (`gitops/workloads/_shared/instrumentation.yaml`), so
swapping the backend is one exporter change and no application redeploy.

### 9.2 Why SigNoz

Chosen over OpenObserve after running both in parallel on identical data. It wins on the
built-in Kubernetes screens and on "Instrumentation checks", which names missing metrics
outright rather than showing an empty panel. It is also by a wide margin the heaviest
component in the cluster — the ClickHouse StatefulSet dominates startup time, which is why it
sits at wave 22, before the Collector at 24, so the Collector logs are not full of connection
refusals while ClickHouse comes up.

### 9.3 Auto-instrumentation

A single pod annotation replaces the agent that used to be baked into each image:

```yaml
annotations:
  instrumentation.opentelemetry.io/inject-nodejs: "true"
```

The operator adds an init container, mounts the language agent, and sets the `OTEL_*`
variables from the `Instrumentation` CR. The image knows nothing about OpenTelemetry. Six
services, four languages (Node, Python, Java, Go), and only the annotation suffix differs —
Go is the exception, since it has no runtime agent, so `rest-service` is instrumented in code.

The ordering constraint is easy to miss: a pod that starts *before* the `Instrumentation` CR
exists comes up healthy and completely untraced, with no error anywhere. Hence `_shared` at
wave 30 and the services at 35.

---

## 10. Teardown

```bash
make destroy   # delete the cluster, stop the containers, KEEP ./data/localstack
make purge     # also delete ./data/localstack — prompts first
```

`make destroy` is not a clean slate. `PERSISTENCE=1` is set in `docker-compose.yml`
(LocalStack's TLS certificates expire after ~90 days and recreating everything takes ~20
minutes), and `./data/localstack` is a bind mount that `docker compose down -v` does not
touch, so every emulated resource comes back on the next `make up`. "I destroyed everything
and the old ALB is still there" is this, and `make purge` is the answer.

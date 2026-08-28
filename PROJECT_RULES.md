# PROJECT RULES — LocalStack + Crossplane DevOps Platform

## 1. Do not modify anything in `./data/`

`./data/localstack` is runtime state written by LocalStack Pro: the emulated resource
store, the cached licence, and downloaded binaries (k3d, docker-registry, nginx). No agent
or tool should read, write, edit or delete inside it. All edits belong in repository source
files.

To reset that state, use `make purge`, which prompts first.
`docker compose down -v` does **not** clear it — `./data/localstack` is a bind mount, not a
named volume.

## 2. Crossplane is the infrastructure control plane

Cloud resources (S3, ECR, VPC, ALB, CloudFront, Route53, IAM) are declared as Kubernetes
managed resources under `gitops/infrastructure/` and continuously reconciled against
LocalStack.

Diagnosis order, and it matters — the two columns mean different things:

```bash
kubectl get managed
```

| SYNCED | READY | Meaning |
| :--- | :--- | :--- |
| False | False | The request never reached AWS. A `*Selector` matched nothing, a referenced resource does not exist, or a field was pruned by the API server. |
| True | False | LocalStack received the request and rejected it, or the resource is still being created. |
| True | True | Reconciled. |

```bash
kubectl describe <kind>.<group> <name>   # the Events block carries the provider's error
```

### 2.1 Field names are not negotiable

The Upbound provider CRDs are structural schemas: **an unknown field is silently deleted,
not rejected.** A manifest with a misspelled field is accepted and does nothing. Three real
instances in this repo, all invisible until something downstream broke:

| Wrong | Right | How it failed |
| :--- | :--- | :--- |
| `s3UsePathStyle` (and the three `skip*` siblings) | `s3_use_path_style`, `skip_credentials_validation`, … | ProviderConfig accepted, toggles gone, every S3 call addressed virtual-hosted style |
| `subnetIdRefs` on elbv2 `LB` | `subnetRefs` | ALB created with no subnets, then failed |
| `domainNameSelector` on cloudfront `Distribution` | there is none — patch the value in | required `domainName` left empty, Distribution rejected |

Before adding a field, check the CRD rather than guessing from another resource:

```bash
kubectl explain lb.elbv2.aws.upbound.io.spec.forProvider --recursive | grep -i subnet
```

The reference-helper suffix follows the **AWS field name**, not a house style: `subnets`
gives `subnetRefs`, while `subnetId` gives `subnetIdRef`. Both spellings are correct, in
different resources.

### 2.2 `matchControllerRef` only works inside a Composition

It restricts candidates to resources composed by the same composite. Standalone managed
resources have no controller reference, so the selector matches nothing and the resource
sits at `cannot resolve references`. Use a direct `*Ref: {name: ...}`.

### 2.3 Crossplane version is pinned, deliberately

`scripts/bootstrap.sh` pins `1.16.0`. Crossplane **v2 removed native
patch-and-transform Composition**, and `gitops/infrastructure/compositions/composition-aws.yaml`
uses `spec.resources`. Unpinning the Helm chart installs v2 and that Composition stops
being valid. Migration path is documented in the script.

## 3. Secrets management

```
.env  ──(00)──▶  AWS Secrets Manager  ──(03)──▶  k8s Secret git-credentials  ──▶  Tekton
```

- `.env` is the only place a token is typed by hand, and it is gitignored.
- `scripts/secrets.sh` pushes `GITHUB_TOKEN` to `learn-crossplane/github-token`.
- `scripts/bootstrap.sh` (step 5) reads it back and creates the `git-credentials` Secret
  in `tekton-pipelines`. **This step is what connects CI to CD** — without it the pipeline
  builds images, pushes them to ECR, reports success, and never updates the image tags.
- `gitops/infrastructure/provider/secret-credentials.yaml` is in git on purpose: it holds
  `mock_access_key` / `mock_secret_key`, which LocalStack accepts and which are worthless
  anywhere else. Real credentials never go there — on real AWS this becomes IRSA.

After rotating the token, `make secrets` is enough: it updates Secrets Manager and, if the cluster is already up, refreshes the in-cluster Secret in the same run. In-flight PipelineRuns keep the old value.

## 4. Kubeconfig and network routing

| From | Kubernetes API | LocalStack |
| :--- | :--- | :--- |
| Host machine | `https://127.0.0.1:<port>`, `--insecure-skip-tls-verify` | `http://localhost:4566` |
| Inside the cluster (Crossplane providers, ArgoCD) | `https://kubernetes.default.svc` | `http://localstack:4566` |

`<port>` is allocated from LocalStack's 4510–4559 range. `scripts/bootstrap.sh`
reads it from `describe-cluster --query cluster.endpoint` instead of assuming 4510 — 4510
is only the port LocalStack usually hands out first.

The CA bundle must be **unset** when `--insecure-skip-tls-verify` is set, or kubectl
refuses to run at all.

## 5. ArgoCD and the ApplicationSet

- `manifestPath`, never `path`. `path` is a reserved key of the git files generator: it
  injects its own value and overrides yours. The symptom is Applications at `SYNC: Unknown`
  with `HEALTH: Healthy`, deploying nothing, with no error anywhere.
- **Sync waves between Applications do not order anything here.** `sync-wave` only applies
  when a parent Application syncs its children (app-of-apps). The ApplicationSet controller
  creates all Applications at once, so the wave numbers document intent and the `retry`
  block does the actual convergence. Waves *within* one Application work normally.
- Declared order: `0` ingress-nginx · `1` provider, iam, compositions · `2` networking,
  storage, registry, loadbalancer · `3` cdn-dns · `5` cert-manager · `8` tekton ·
  `12` redpanda · `15` otel-operator · `22` signoz · `24` otel-collector · `30` _shared ·
  `35` services.
- Two field paths are owned by the `localstack-wiring` CronJob, not by git, and are listed
  under `ignoreDifferences` in the appset: the CloudFront origin `domainName` and the
  Route53 `alias`. Removing those entries makes selfHeal overwrite the patched values with
  the placeholders every few minutes.

## 6. Runtime-valued state lives in a controller, not a script

Three things cannot be written down as a manifest, because their values are assigned at
creation time: the ALB target group membership (k3d gives the node a new container IP on
every recreation), the CloudFront origin domain, and the Route53 alias target.

All three are reconciled by the `localstack-wiring` CronJob in
`gitops/platform/localstack-wiring/`, every two minutes, comparing current state before
every write. They used to be one-shot host scripts, and the failure mode of that was
quiet: a stale ALB target shows up only as a 503, and there was nothing to notice that
the node IP had changed an hour ago.

**The rule this encodes:** "needs a runtime value" is an argument for a controller, not
for a script. `scripts/` is only for what cannot run inside the cluster at all — see
README §3.3 for the four survivors.

Deleting the directory is safe (nothing it created is owned by it), but the CloudFront
origin and the Route53 alias then stop tracking the ALB.

## 7. Upstream manifests are vendored, never fetched at sync time

Every third-party install manifest is committed at a pinned version: ArgoCD, ingress-nginx,
cert-manager, SigNoz, the OTel operator, and all four Tekton releases. Two reasons:
reproducibility, and LocalStack acting as DNS for the k3d nodes with an explicit
upstream-resolution allowlist in `docker-compose.yml` that a new remote host will not be on.

To bump a version, download the new file next to the old one, change the reference in
`kustomization.yaml`, and delete the old file in the same commit. Never hand-edit a
vendored manifest.

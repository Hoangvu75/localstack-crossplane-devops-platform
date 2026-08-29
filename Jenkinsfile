// ── The pipeline, as code, in the repo it builds ─────────────────────────────
// Jenkins knows this file exists because JCasC told it to: the job is declared in
// gitops/platform/jenkins/casc/jenkins.yaml with scriptPath('Jenkinsfile'). Nothing here
// was configured through the Jenkins UI, and nothing here survives being edited there.
//
// This replaces four Tekton objects -- a Pipeline and three Tasks. The shape is the same
// because the constraints are the same, and every non-obvious line below is a constraint
// that was paid for once already.
//
// Scripted rather than declarative: each service needs its own agent pod with its own
// cache volume, generated from a list. Declarative's `parallel` block wants its branches
// written out statically, which would mean six near-identical copies of the same
// twenty lines.

// appDir is the directory under apps/ AND the suffix of that service's cache PVC.
// repoSuffix is the ECR repository name after the project prefix. The two differ for
// exactly one service: apps/web publishes to learn-crossplane-web-app.
SERVICES = [
    [dir: 'web',             repo: 'web-app'],
    [dir: 'cpu-service',     repo: 'cpu-service'],
    [dir: 'memory-service',  repo: 'memory-service'],
    [dir: 'disk-service',    repo: 'disk-service'],
    [dir: 'rest-service',    repo: 'rest-service'],
    [dir: 'history-service', repo: 'history-service'],
]

REGISTRY = '000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:4566'
PROJECT  = 'learn-crossplane'
BRANCH   = 'main'

// ── One agent pod per service ────────────────────────────────────────────────
// How many run at once is NOT decided here. casc/jenkins.yaml sets containerCapStr: "2"
// on the Kubernetes cloud, and that is the throttle. Tekton had no such knob and the
// limit had to be smuggled in as a memory request, which was sized against the wrong
// resource and cost a whole pipeline -- see the note in casc/jenkins.yaml.
def buildService(svc, commitTag) {
    return {
        podTemplate(
            namespace: 'jenkins',
            serviceAccount: 'jenkins',
            containers: [
                containerTemplate(
                    name: 'dind',
                    image: 'docker:24.0.7-dind',
                    privileged: true,
                    // The dind image's entrypoint starts dockerd with defaults. We need
                    // it started with our own flags, so the container is held open and
                    // the daemon is launched by the build step instead.
                    command: 'sh',
                    args: '-c "trap : TERM INT; sleep infinity & wait"',
                    resourceRequestCpu: '1',
                    resourceRequestMemory: '2Gi',
                    resourceLimitCpu: '4',
                    resourceLimitMemory: '4Gi',
                ),
            ],
            volumes: [
                // Per-service cache. Two dockerd processes must never share one
                // /var/lib/docker, and these run concurrently -- a single shared claim
                // would serialise them and let the services evict each other's layers.
                persistentVolumeClaim(
                    mountPath: '/var/lib/docker',
                    claimName: "dind-cache-${svc.dir}",
                    readOnly: false,
                ),
            ],
        ) {
            node(POD_LABEL) {
                checkout scm
                container('dind') {
                    sh """
                        set -eu
                        APP_DIR='${svc.dir}'
                        FULL_IMAGE='${REGISTRY}/${PROJECT}-${svc.repo}:${commitTag}'
                    """ + '''
                        # ── --insecure-registry, and why Docker will not work without it ──
                        # The registry host is a FOUR-label subdomain of
                        # localhost.localstack.cloud. LocalStack serves a wildcard
                        # certificate for *.localhost.localstack.cloud, and a TLS wildcard
                        # matches exactly one label, so it does not cover this name. Docker
                        # tries HTTPS, fails verification, and will not fall back to
                        # plaintext on its own:
                        #
                        #     x509: certificate is valid for *.localhost.localstack.cloud,
                        #     not 000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud
                        #
                        # The k3d nodes do not hit this because LocalStack configures their
                        # containerd with the registry marked insecure when it creates the
                        # cluster. A daemon started by hand inside a pod gets none of that.

                        # ── --mtu is why this build takes minutes instead of an hour ──
                        # dockerd defaults its bridge to MTU 1500 and hands 1500 to every
                        # build container. This pod sits behind flannel VXLAN, whose 50
                        # bytes of encapsulation leave the pod eth0 at 1450. Anything
                        # between 1451 and 1500 bytes is silently dropped, and path MTU
                        # discovery does not survive the nesting here.
                        #
                        # The symptom is deceptive: DNS answers instantly because queries
                        # are small UDP, while every TLS handshake and bulk transfer
                        # stalls. `npm ci` for apps/web once took 47 minutes and exited 0
                        # with an empty node_modules. Nothing in that chain says MTU.
                        #
                        # Read from the interface rather than hardcoded, so a change in the
                        # CNI or its overhead does not silently reintroduce the stall.
                        POD_MTU=$(cat /sys/class/net/eth0/mtu 2>/dev/null || echo 1450)
                        REGISTRY_HOST="${FULL_IMAGE%%/*}"
                        echo ">>> [${APP_DIR}] dockerd (insecure: ${REGISTRY_HOST}, mtu: ${POD_MTU})"
                        dockerd-entrypoint.sh \
                            --insecure-registry "${REGISTRY_HOST}" \
                            --mtu="${POD_MTU}" >/tmp/dockerd.log 2>&1 &

                        # Bounded. An unbounded `until docker info` turns a daemon that
                        # failed to start into a build that hangs until the job timeout
                        # with no diagnostic.
                        i=0
                        until docker info >/dev/null 2>&1; do
                            i=$((i + 1))
                            if [ "$i" -gt 60 ]; then
                                echo "ERROR: [${APP_DIR}] dockerd did not come up in 60s:" >&2
                                tail -50 /tmp/dockerd.log >&2
                                exit 1
                            fi
                            sleep 1
                        done

                        echo ">>> [${APP_DIR}] building ${FULL_IMAGE}"

                        # ── No `|| true` below this line ──────────────────────
                        # This once ended in `docker push ... || echo "pushed or
                        # simulated"`, which turned any push failure into a green build.
                        # The pipeline reported success, the next stage wrote image tags
                        # for images that did not exist, ArgoCD synced them, and the pods
                        # went ImagePullBackOff -- three steps away from the real error.
                        docker build -t "${FULL_IMAGE}" "apps/${APP_DIR}"
                        docker push "${FULL_IMAGE}"
                        echo ">>> OK: ${FULL_IMAGE}"
                    '''
                }
            }
        }
    }
}

timeout(time: 2, unit: 'HOURS') {
    // disableConcurrentBuilds: two runs racing each other would both push a tag commit
    // to main, and the loser's push is rejected after it has already built everything.
    properties([disableConcurrentBuilds()])

    def commitTag

    stage('Checkout') {
        podTemplate(namespace: 'jenkins', serviceAccount: 'jenkins', containers: [
            containerTemplate(name: 'tools', image: 'alpine/k8s:1.28.2',
                              command: 'sh', args: '-c "trap : TERM INT; sleep infinity & wait"',
                              resourceRequestCpu: '100m', resourceRequestMemory: '256Mi',
                              resourceLimitCpu: '1', resourceLimitMemory: '512Mi'),
        ]) {
            node(POD_LABEL) {
                def scmVars = checkout scm
                // Short SHA of what was actually checked out. Taken from the SCM result
                // rather than from `git rev-parse` in a shell, so it cannot drift from
                // the revision the other stages build.
                commitTag = scmVars.GIT_COMMIT.take(7)
                echo "Building ${commitTag}"
            }
        }
    }

    stage('Build and push images') {
        def branches = [:]
        for (svc in SERVICES) {
            branches["build-${svc.dir}"] = buildService(svc, commitTag)
        }
        // failFast false: one broken service should not cancel five healthy builds
        // mid-flight. The next stage refuses to run unless all six succeeded anyway.
        branches.failFast = false
        parallel branches
    }

    // ── Deliberately all-or-nothing ─────────────────────────────────────────
    // Reached only if every build succeeded, because `parallel` throws otherwise and
    // this stage never runs. Writing a tag for an image that was never pushed is how you
    // get ImagePullBackOff in production behind a green pipeline.
    //
    // The cost is that five good builds do not deploy when the sixth fails. Making it
    // per-service would mean six commits racing each other on one branch, which is a
    // worse problem than waiting for a fix.
    stage('Update GitOps manifests') {
        podTemplate(namespace: 'jenkins', serviceAccount: 'jenkins', containers: [
            containerTemplate(name: 'tools', image: 'alpine/k8s:1.28.2',
                              command: 'sh', args: '-c "trap : TERM INT; sleep infinity & wait"',
                              resourceRequestCpu: '100m', resourceRequestMemory: '256Mi',
                              resourceLimitCpu: '1', resourceLimitMemory: '512Mi'),
        ]) {
            node(POD_LABEL) {
                checkout scm
                container('tools') {
                    withCredentials([usernamePassword(
                        credentialsId: 'github-token',
                        usernameVariable: 'GIT_USER',
                        passwordVariable: 'GITHUB_TOKEN',
                    )]) {
                        def imageArgs = SERVICES.collect { svc ->
                            "${svc.dir}:${PROJECT}-${svc.repo}"
                        }.join(' ')
                        sh """
                            set -eu
                            COMMIT_TAG='${commitTag}'
                            REGISTRY='${REGISTRY}'
                            BRANCH='${BRANCH}'
                            SERVICES='${imageArgs}'
                        """ + '''
                            echo "=== [Jenkins CI] updating GitOps workloads to ${COMMIT_TAG} ==="
                            for item in $SERVICES; do
                                APP_DIR="${item%%:*}"
                                REPO_NAME="${item##*:}"
                                FULL_IMAGE="${REGISTRY}/${REPO_NAME}:${COMMIT_TAG}"
                                WORKLOAD_DIR="gitops/workloads/${APP_DIR}"
                                if [ ! -d "${WORKLOAD_DIR}" ]; then
                                    echo "ERROR: ${WORKLOAD_DIR} does not exist -- the SERVICES map" >&2
                                    echo "       in the Jenkinsfile is out of sync with gitops/workloads/." >&2
                                    exit 1
                                fi
                                echo ">>> ${WORKLOAD_DIR}/kustomization.yaml -> ${COMMIT_TAG}"
                                ( cd "${WORKLOAD_DIR}" && kustomize edit set image "${REPO_NAME}=${FULL_IMAGE}" )
                            done

                            git config user.email "jenkins-ci@localstack-crossplane.internal"
                            git config user.name  "Jenkins CI"
                            # A credential helper rather than https://TOKEN@github.com/...
                            # in the URL: the URL form leaks the token into every error
                            # message and into `git remote -v`.
                            git config credential.helper \
                                '!f() { echo "username=x-access-token"; echo "password=${GITHUB_TOKEN}"; }; f'

                            git add gitops/workloads/
                            if git diff-index --quiet HEAD --; then
                                echo ">>> No image tag changed. Nothing to commit."
                                exit 0
                            fi

                            # [skip ci] is what stops this push from triggering the next
                            # build, forever. casc/jenkins.yaml filters it out of polling
                            # with messageExclusion; the marker alone is decoration, and
                            # the filter alone has nothing to match. Both or neither.
                            git commit -q -m "chore(ci): update image tags to ${COMMIT_TAG} [skip ci]"

                            echo ">>> pushing to ${BRANCH}"
                            if ! git push origin "HEAD:${BRANCH}"; then
                                echo "ERROR: push rejected. Most likely ${BRANCH} moved while this" >&2
                                echo "       build was running. Re-run against the new head." >&2
                                exit 1
                            fi
                            echo ">>> pushed. ArgoCD picks up the new tags on its next poll."
                        '''
                    }
                }
            }
        }
    }
}

# ==============================================================================
# Next.js — two-stage build
# ==============================================================================
#
# HISTORY: Earlier versions ended build commands with `|| true` and a fallback mock
# HTTP server when `next build` failed. Consequently, the entire pipeline reported false positives:
#
#   next build error → image built → CodeBuild SUCCEEDED → ECR push
#                    → ArgoCD sync → pod Healthy → probes green
#
# All signals were green while the artifact was broken. Silent failures undermine CI/CD quality.
# All commands now fail fast and propagate errors.

FROM node:20-alpine AS builder
WORKDIR /app

COPY package*.json ./

# `npm ci` installs the EXACT dependency tree in package-lock.json and fails if the lockfile
# diverges from package.json. Builds are deterministic across runs.
#
# `--legacy-peer-deps` is used because npm 7+ treats peer dependency conflicts as hard errors.
# --no-audit --no-fund: the audit pass POSTs the whole dependency tree to the registry
# and, on a Next.js tree inside DinD, was a large part of a 47-MINUTE npm ci.
#
# The `node -e require.resolve` is not paranoia. npm 10.8.2 hit its own bug here:
#     npm error Exit handler never called!
# and then EXITED 0, leaving node_modules empty. Docker happily continued, and the
# failure surfaced two steps later as `sh: next: not found` with exit 127 -- pointing at
# the build script instead of the install. This makes the install fail where it broke.
RUN npm ci --legacy-peer-deps --no-audit --no-fund \
 && node -e "require.resolve(next/package.json)"

COPY . .

# Fail immediately if build fails
RUN npm run build

# ------------------------------------------------------------------------------
FROM node:20-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production

# --chown=node:node ensures files are owned by the process user (uid 1000).
COPY --from=builder --chown=node:node /app/public ./public
COPY --from=builder --chown=node:node /app/.next/standalone ./
COPY --from=builder --chown=node:node /app/.next/static ./.next/static

# Image defaults to root unless specified. Non-root user `node` (uid 1000 in node:20-alpine)
# matches the manifest securityContext.
USER node

EXPOSE 3000
CMD ["node", "server.js"]

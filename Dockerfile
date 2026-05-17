# ============================================
# Stage 1: Install dependencies
# ============================================
FROM node:22.20-bookworm-slim AS deps

RUN apt-get update && apt-get install -y --no-install-recommends \
    g++ \
    make \
    python3-pip \
    python3-setuptools \
&& rm -rf /var/lib/apt/lists/*

RUN npm --no-update-notifier --no-fund --global install pnpm@10.6.1

WORKDIR /app

# Copy dependency manifests first for better layer caching
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY apps/frontend/package.json apps/frontend/package.json
COPY apps/backend/package.json apps/backend/package.json
COPY apps/orchestrator/package.json apps/orchestrator/package.json
COPY libraries/helpers/package.json libraries/helpers/package.json
COPY libraries/nestjs-libraries/package.json libraries/nestjs-libraries/package.json
COPY libraries/react-shared-libraries/package.json libraries/react-shared-libraries/package.json

# Install all dependencies (including devDeps needed for build)
RUN pnpm install --frozen-lockfile

# ============================================
# Stage 2: Build all apps
# ============================================
FROM node:22.20-bookworm-slim AS builder

RUN npm --no-update-notifier --no-fund --global install pnpm@10.6.1

WORKDIR /app

ARG NEXT_PUBLIC_VERSION
ENV NEXT_PUBLIC_VERSION=$NEXT_PUBLIC_VERSION

# Copy installed node_modules from deps stage
COPY --from=deps /app/node_modules ./node_modules

# Copy full source code
COPY . .

# Generate Prisma client
RUN pnpm run prisma-generate

# Build all 3 apps (frontend, backend, orchestrator)
RUN NODE_OPTIONS="--max-old-space-size=4096" pnpm run build

# Next.js standalone: copy static assets into standalone output
RUN cp -r /app/apps/frontend/public /app/apps/frontend/.next/standalone/apps/frontend/public && \
    cp -r /app/apps/frontend/.next/static /app/apps/frontend/.next/standalone/apps/frontend/.next/static

# Prune devDependencies to reduce final image size
RUN pnpm prune --prod --no-optional || true

# ============================================
# Stage 3: Production runtime
# ============================================
FROM node:22.20-bookworm-slim AS runner

RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    bash \
    tini \
    curl \
&& rm -rf /var/lib/apt/lists/*

RUN npm --no-update-notifier --no-fund --global install pnpm@10.6.1 pm2

# Create system user for nginx
RUN addgroup --system www \
 && adduser --system --ingroup www --home /www --shell /usr/sbin/nologin www \
 && mkdir -p /www /uploads \
 && chown -R www:www /www /var/lib/nginx /uploads

WORKDIR /app

# Copy nginx config
COPY var/docker/nginx.conf /etc/nginx/nginx.conf

# Copy production node_modules (pruned, no devDeps)
COPY --from=builder /app/node_modules ./node_modules

# Copy workspace config (needed for pnpm scripts)
COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/pnpm-workspace.yaml ./pnpm-workspace.yaml
COPY --from=builder /app/pnpm-lock.yaml ./pnpm-lock.yaml
COPY --from=builder /app/.npmrc ./.npmrc

# Copy app package.json files (needed for pnpm --filter and pm2 scripts)
COPY --from=builder /app/apps/backend/package.json ./apps/backend/package.json
COPY --from=builder /app/apps/orchestrator/package.json ./apps/orchestrator/package.json
COPY --from=builder /app/apps/frontend/package.json ./apps/frontend/package.json

# Copy built backend (NestJS compiled output)
COPY --from=builder /app/apps/backend/dist ./apps/backend/dist

# Copy built orchestrator (NestJS compiled output)
COPY --from=builder /app/apps/orchestrator/dist ./apps/orchestrator/dist

# Copy built frontend (Next.js standalone)
COPY --from=builder /app/apps/frontend/.next/standalone ./apps/frontend/.next/standalone
COPY --from=builder /app/apps/frontend/.next/static ./apps/frontend/.next/static
COPY --from=builder /app/apps/frontend/public ./apps/frontend/public

# Copy Prisma schema (needed for prisma-db-push at startup)
COPY --from=builder /app/libraries/nestjs-libraries/src/database/prisma/schema.prisma ./libraries/nestjs-libraries/src/database/prisma/schema.prisma

# Copy generated Prisma client
COPY --from=builder /app/node_modules/.prisma ./node_modules/.prisma
COPY --from=builder /app/node_modules/@prisma/client ./node_modules/@prisma/client

# Copy dynamicconfig (for Temporal)
COPY --from=builder /app/dynamicconfig ./dynamicconfig

# Copy libraries package.json (needed for workspace resolution)
COPY --from=builder /app/libraries/helpers/package.json ./libraries/helpers/package.json
COPY --from=builder /app/libraries/nestjs-libraries/package.json ./libraries/nestjs-libraries/package.json
COPY --from=builder /app/libraries/react-shared-libraries/package.json ./libraries/react-shared-libraries/package.json

# Set environment
ENV NODE_ENV=production
ENV TZ=UTC

EXPOSE 5000

# Use tini for proper PID 1 signal handling (graceful shutdown)
ENTRYPOINT ["tini", "--"]
CMD ["sh", "-c", "nginx && pnpm run pm2"]

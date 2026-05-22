FROM node:24-alpine AS deps
WORKDIR /app
RUN corepack enable
COPY package.json pnpm-lock.yaml* ./
RUN pnpm install --frozen-lockfile=false

FROM deps AS build
WORKDIR /app
COPY tsconfig.json ./
COPY src ./src
RUN pnpm build
RUN pnpm prune --prod

FROM node:24-alpine AS runtime
WORKDIR /app

# node:24-alpine already provides a `node` user (UID 1000) + group; reuse
# rather than creating a duplicate `nodeuser` at the same UID which fails
# with "addgroup: gid '1000' in use". Only the audit-log directory needs
# explicit chown since /app is the WORKDIR and gets COPY --chown below.
RUN mkdir -p /var/log/license-signing-api \
  && chown -R node:node /var/log/license-signing-api /app

ENV NODE_ENV=production
ENV PORT=8443

COPY --from=build --chown=node:node /app/package.json ./package.json
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist

USER node

EXPOSE 8443
HEALTHCHECK --interval=10s --timeout=3s --retries=5 \
  CMD wget --quiet --tries=1 --spider http://127.0.0.1:${PORT}/healthz || exit 1

CMD ["node", "dist/index.js"]

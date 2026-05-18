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

RUN addgroup -g 1000 nodeuser \
  && adduser -D -u 1000 -G nodeuser nodeuser \
  && mkdir -p /var/log/license-signing-api \
  && chown -R nodeuser:nodeuser /var/log/license-signing-api /app

ENV NODE_ENV=production
ENV PORT=8443

COPY --from=build --chown=nodeuser:nodeuser /app/package.json ./package.json
COPY --from=build --chown=nodeuser:nodeuser /app/node_modules ./node_modules
COPY --from=build --chown=nodeuser:nodeuser /app/dist ./dist

USER nodeuser

EXPOSE 8443
HEALTHCHECK --interval=10s --timeout=3s --retries=5 \
  CMD wget --quiet --tries=1 --spider http://127.0.0.1:${PORT}/healthz || exit 1

CMD ["node", "dist/index.js"]

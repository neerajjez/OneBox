# arm64 verified. Pinned minor, not `latest` (rule 20).
FROM node:22-alpine

# Non-root. node:alpine ships uid/gid 1000 as `node`.
WORKDIR /app
COPY src/server.js ./server.js
RUN chown -R node:node /app
USER node

ENV NODE_ENV=production PORT=3000
EXPOSE 3000

# No npm install: zero dependencies is the point. Nothing to audit, nothing to
# go stale, no lockfile to drift.
CMD ["node", "server.js"]

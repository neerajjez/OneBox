FROM node:22-alpine
WORKDIR /app
COPY src/server.js ./server.js
RUN chown -R node:node /app
USER node
ENV NODE_ENV=production PORT=9095
EXPOSE 9095
CMD ["node", "server.js"]

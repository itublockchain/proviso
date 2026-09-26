FROM node:26-slim
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY *.ts ./
# monid.ts keeps its cache next to itself; point that at the state volume so it survives restarts.
RUN ln -s /data/.monid-cache.json .monid-cache.json
USER node
ENV PORT=8787 PROVISO_STATE_DIR=/data
EXPOSE 8787
CMD ["node", "--import", "tsx", "server.ts"]

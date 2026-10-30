FROM node:24-alpine@sha256:06d7adf3e0ef61a13f1d28682726366f97a15aa1888c934d3ecec86c33918b53 AS build
WORKDIR /build
COPY apps/web/package.json apps/web/package-lock.json ./
RUN npm ci --ignore-scripts
COPY apps/web/ ./
RUN npm run build && node scripts/check-notices.mjs

FROM nginx:1.30.6-alpine@sha256:47928bf67eb62a1863cb08d9ecb52d3e704304ba614eaee17884204677702951 AS runtime
# The source label links the published image to this repository on the GitHub Container Registry.
LABEL org.opencontainers.image.source="https://github.com/cj-vana/reel-client" \
      org.opencontainers.image.description="Reel, a Jellyfin web client" \
      org.opencontainers.image.licenses="MIT"
RUN rm -rf /usr/share/nginx/html/*
COPY docker/nginx.conf /etc/nginx/nginx.conf
COPY --from=build /build/dist/ /usr/share/nginx/html/
COPY LICENSE /usr/share/nginx/html/LICENSE.txt
USER 101:101
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 CMD ["wget", "--spider", "--quiet", "http://127.0.0.1:8080/healthz"]
ENTRYPOINT ["nginx"]
CMD ["-g", "daemon off;"]

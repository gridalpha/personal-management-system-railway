# The Vue SPA bakes its backend origin at build time, and on Railway that origin does
# not exist until the backend service has a domain. So the bundle is built once against
# a placeholder token and the token is substituted at boot - which is what makes this
# publishable as a template.
FROM node:18.19.1-bullseye AS build

ARG PMS_FRONTEND_REF=main
ADD https://codeload.github.com/Volmarg/personal-management-system-front/tar.gz/refs/heads/${PMS_FRONTEND_REF} /tmp/pms-front.tar.gz

WORKDIR /app
RUN tar -xzf /tmp/pms-front.tar.gz -C /app --strip-components=1 \
    && rm -f /tmp/pms-front.tar.gz \
    && test -f /app/package.json \
    && test -f /app/.env.production

# Written into the env file rather than passed as a variable: vite.config.js folds
# process.env into the bundle itself, so the file is the only unambiguous input.
RUN sed -i 's|^VITE_BACKEND_BASE_URL=.*|VITE_BACKEND_BASE_URL=__PMS_BACKEND_URL__|' .env.production \
    && grep -qx 'VITE_BACKEND_BASE_URL=__PMS_BACKEND_URL__' .env.production

# The repo ships a stale dist/; it must not survive into the image.
RUN rm -rf /app/dist

RUN npm ci --no-audit --no-fund || npm install --no-audit --no-fund
RUN chmod +x build-assets.sh prepare-prod.sh && npm run build \
    && test -f /app/dist/index.html \
    && grep -rq '__PMS_BACKEND_URL__' /app/dist \
    || (echo "the placeholder did not reach the bundle" && exit 1)

FROM nginx:1.27-alpine

RUN apk add --no-cache gzip

COPY --from=build /app/dist /opt/pms-front/dist
COPY frontend/nginx.conf.template /etc/nginx/nginx.conf.template
COPY frontend/entrypoint.sh /usr/local/bin/pms-front-entrypoint.sh
RUN chmod +x /usr/local/bin/pms-front-entrypoint.sh \
    && sh -n /usr/local/bin/pms-front-entrypoint.sh \
    && test -f /opt/pms-front/dist/index.html

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/pms-front-entrypoint.sh"]

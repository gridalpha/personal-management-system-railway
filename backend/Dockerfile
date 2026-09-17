FROM php:8.3-fpm-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_NO_INTERACTION=1 \
    APP_ENV=prod

# Runtime + build dependencies. Nothing is purged afterwards: `apt-get purge --auto-remove`
# on the -dev packages also takes the shared libraries the compiled PHP extensions link against.
#
# `tree` is load-bearing, not a convenience: ShellTreeService shells out to it, so without
# it the Files, Images and Video modules list nothing and only log a CRITICAL, on a
# container that is otherwise perfectly healthy. `mariadb-client` is what the app's own
# backup command execs.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        unzip \
        nginx \
        gettext-base \
        openssl \
        procps \
        tree \
        mariadb-client \
        libicu-dev \
        libzip-dev \
        libpng-dev \
        libjpeg62-turbo-dev \
        libfreetype6-dev \
        zlib1g-dev \
        g++ \
        make \
        autoconf \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

RUN docker-php-ext-configure intl \
    && docker-php-ext-install -j"$(nproc)" intl
RUN docker-php-ext-install -j"$(nproc)" pdo_mysql
RUN docker-php-ext-install -j"$(nproc)" opcache
RUN docker-php-ext-install -j"$(nproc)" zip
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" gd
RUN yes '' | pecl install apcu && docker-php-ext-enable apcu

# OPcache registers itself as "Zend OPcache", never "opcache".
RUN command -v tree && command -v mariadb-dump
RUN php -r 'exit(extension_loaded("Zend OPcache") && extension_loaded("apcu") && extension_loaded("intl") && extension_loaded("pdo_mysql") && extension_loaded("gd") && extension_loaded("zip") ? 0 : 1);'

COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

# Upstream publishes no backend image, so the application is built from source here.
# `main` rather than the newest release tag: the 2026-08-19 hardening of the public
# /public/get-file route is not in v2.0.4.
ARG PMS_BACKEND_REF=main
ADD https://codeload.github.com/Volmarg/personal-management-system/tar.gz/refs/heads/${PMS_BACKEND_REF} /tmp/pms-backend.tar.gz
RUN mkdir -p /application \
    && tar -xzf /tmp/pms-backend.tar.gz -C /application --strip-components=1 \
    && rm -f /tmp/pms-backend.tar.gz \
    && test -f /application/composer.json \
    && test -f /application/public/index.php

WORKDIR /application

# Added before the autoloader is dumped so the command lands in the optimised classmap.
COPY backend/RailwayCreateFirstUserCommand.php /application/src/Command/RailwayCreateFirstUserCommand.php
RUN php -l /application/src/Command/RailwayCreateFirstUserCommand.php

# Kernel::configureContainer globs config/packages/*.yaml, so this merges into the
# Doctrine configuration without patching the file upstream ships.
COPY backend/zz_railway_doctrine.yaml /application/config/packages/zz_railway_doctrine.yaml
RUN grep -q '1002:' /application/config/packages/zz_railway_doctrine.yaml

RUN composer install --no-interaction --no-progress --ignore-platform-reqs --optimize-autoloader \
    && composer dump-autoload --no-interaction --ignore-platform-reqs --optimize \
    && rm -rf /root/.composer/cache

# php-fpm clears the environment by default and PHP's stock variables_order omits E,
# so without both of these no Railway variable reaches $_ENV, which is what this app reads.
COPY backend/php.ini /usr/local/etc/php/conf.d/zz-pms.ini
COPY backend/fpm-pool.conf /usr/local/etc/php-fpm.d/zz-docker.conf
RUN php -i | grep -q 'variables_order => EGPCS' \
    && grep -q 'clear_env = no' /usr/local/etc/php-fpm.d/zz-docker.conf

COPY backend/nginx.conf.template /etc/nginx/nginx.conf.template
COPY backend/healthz.php /opt/pms/healthz.php
COPY backend/entrypoint.sh /usr/local/bin/pms-entrypoint.sh
RUN php -l /opt/pms/healthz.php \
    && bash -n /usr/local/bin/pms-entrypoint.sh \
    && chmod +x /usr/local/bin/pms-entrypoint.sh

# Hand PHP the real client address and the forwarded scheme. Rewriting the single
# definition inside fastcgi_params beats re-declaring the key after the include,
# which would send it twice.
RUN sed -i 's|^fastcgi_param[[:space:]]\{1,\}REMOTE_ADDR.*|fastcgi_param  REMOTE_ADDR        $pms_real_ip;|' /etc/nginx/fastcgi_params \
    && printf 'fastcgi_param  HTTPS              $pms_https if_not_empty;\n' >> /etc/nginx/fastcgi_params \
    && grep -q 'pms_real_ip' /etc/nginx/fastcgi_params \
    && grep -q 'pms_https' /etc/nginx/fastcgi_params \
    && rm -f /etc/nginx/sites-enabled/default

EXPOSE 8080

CMD ["/usr/local/bin/pms-entrypoint.sh"]

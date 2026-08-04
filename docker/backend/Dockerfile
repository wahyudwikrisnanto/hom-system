# Local dev image for gym-backend.
#
# Deliberately NOT gym-backend/Dockerfile: that one is the production image — it COPYs
# the source, runs `composer install` at build time, and boots Octane/Swoole through
# scripts/entrypoint.sh. For local work we want the opposite: no source baked in, the
# submodule bind-mounted, and `php artisan serve` so every request re-reads the files
# from disk (edit → refresh, no rebuild, no restart).
#
# Build context is this directory only — nothing is copied from the app.
ARG PHP_VERSION=8.2

FROM php:${PHP_VERSION}-cli-bookworm

ARG ROOT_DIR=/var/www/app
ARG UID=1000
ARG GID=1000
ARG USER=hom
ARG TZ=Asia/Jakarta

ENV DEBIAN_FRONTEND=noninteractive \
    TERM=xterm-color \
    TZ=${TZ} \
    ROOT=${ROOT_DIR} \
    COMPOSER_FUND=0 \
    COMPOSER_MAX_PARALLEL_HTTP=48

WORKDIR ${ROOT_DIR}

ADD --chmod=0755 https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/

# Same extension set as production, minus the ones only the Octane/queue infra needs
# (swoole, uv, rdkafka, memcached, ldap, pdo_mysql) — keeps the local build fast.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libzip-dev \
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev \
    libonig-dev \
    libxml2-dev \
    libicu-dev \
    unzip \
    git \
    curl \
    && install-php-extensions \
        apcu \
        bcmath \
        bz2 \
        exif \
        gd \
        intl \
        mbstring \
        opcache \
        pcntl \
        pdo_pgsql \
        redis \
        sockets \
        zip \
    && apt-get -y autoremove \
    && apt-get clean \
    && docker-php-source delete \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

# Opcache revalidates on every request so edits in the bind mount take effect immediately.
RUN { \
        echo 'opcache.enable=1'; \
        echo 'opcache.validate_timestamps=1'; \
        echo 'opcache.revalidate_freq=0'; \
        echo 'display_errors=On'; \
        echo 'memory_limit=512M'; \
        echo 'upload_max_filesize=64M'; \
        echo 'post_max_size=64M'; \
    } > /usr/local/etc/php/conf.d/zz-local.ini

RUN set -eux; \
    groupadd --gid $GID $USER || true; \
    useradd --uid $UID --gid $GID -m -s /bin/bash $USER || true; \
    mkdir -p $ROOT_DIR; \
    chown -R $UID:$GID $ROOT_DIR

USER $USER

EXPOSE 8000

CMD ["php", "artisan", "serve", "--host=0.0.0.0", "--port=8000"]

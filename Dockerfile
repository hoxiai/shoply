# ==========================================
# Shopark 生产镜像（单文件构建，不再依赖外部 shopark-base 基础镜像）
# 运行环境与代码同仓定版；runtime 层只在本段变化时重建，其余时间命中构建缓存。
# ==========================================
ARG PHP_IMAGE=php:8.2-cli-alpine3.24
ARG COMPOSER_IMAGE=composer:2.10

FROM ${COMPOSER_IMAGE} AS composer

# ==========================================
# 运行环境：PHP 扩展 + node（Site SSR）+ composer（构建期与运行时安装应用依赖）
# Go 二进制为 CGO_ENABLED=0 静态编译，不需要 glibc 兼容层。
# ==========================================
FROM ${PHP_IMAGE} AS runtime
# 可选 apk 镜像源，如 https://mirrors.aliyun.com；留空使用官方源
ARG APK_MIRROR=
# 与 plugins/composer.lock 中 google/protobuf 的大版本、小版本保持一致
ARG PROTOBUF_VERSION=4.33.6

COPY scripts/docker/protobuf-4.33.6.tgz /tmp/protobuf.tgz

RUN set -eux; \
    if [ -n "$APK_MIRROR" ]; then \
        sed -i -E "s#https?://dl-cdn.alpinelinux.org#${APK_MIRROR%/}#g" /etc/apk/repositories; \
    fi; \
    apk add --no-cache --virtual .build-deps \
        $PHPIZE_DEPS linux-headers \
        freetype-dev icu-dev libjpeg-turbo-dev libpng-dev libwebp-dev libzip-dev libpq-dev zlib-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install -j"$(getconf _NPROCESSORS_ONLN)" \
        bcmath gd intl opcache pcntl pdo_mysql pdo_pgsql sockets zip; \
    if [ -f /tmp/protobuf.tgz ]; then \
        pecl install /tmp/protobuf.tgz; \
        rm -f /tmp/protobuf.tgz; \
    else \
        pecl install "protobuf-${PROTOBUF_VERSION}"; \
    fi; \
    docker-php-ext-enable protobuf; \
    # 只保留扩展实际链接的共享库，与官方 PHP 镜像的做法一致
    runDeps="$( \
        scanelf --needed --nobanner --format '%n#p' --recursive /usr/local/lib/php/extensions \
        | tr ',' '\n' | sort -u \
        | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )"; \
    apk add --no-cache --virtual .shopark-phpext-rundeps $runDeps; \
    apk del --no-network .build-deps; \
    rm -rf /tmp/pear ~/.pearrc /usr/local/lib/php/test /usr/local/lib/php/doc; \
    # purego (webp 动态加载) 产生 libc/libdl 动态链接，引入 gcompat 兼容层保证 Alpine 正常执行；
    # 同时安装 postgresql-client 与 mysql-client 供 php shopark db:backup / db:restore 使用
    apk add --no-cache bash gcompat nodejs tzdata postgresql-client mysql-client; \
    php -m | grep -qi '^protobuf$'; \
    php -r 'foreach (["mysql", "pgsql"] as $driver) { if (!in_array($driver, PDO::getAvailableDrivers(), true)) { exit(1); } }'; \
    command -v pg_dump >/dev/null && command -v psql >/dev/null && command -v mysqldump >/dev/null && command -v mysql >/dev/null; \
    node -v

COPY --from=composer /usr/bin/composer /usr/bin/composer
ENV TZ=UTC

# ==========================================
# PHP 生产依赖
# 开发机的 vendor 带着 phpunit 等开发包，autoload 也引用它们；只靠 .dockerignore 删目录，
# autoload 仍会去加载被删掉的文件，PHP 一启动就 Fatal。这里按 composer.lock 去掉开发包并
# 重新生成 autoload。vendor 与 lock 一致时不联网。
# ==========================================
FROM runtime AS plugins
WORKDIR /build
COPY plugins ./
RUN COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --no-interaction --no-progress --no-plugins --no-scripts

# 仅安装独立主题编译器；锁文件是 Site 锁文件的副本（build-image.sh 构建前同步），确保 Vue/编译器版本一致。
# 源码仓与 release 归档里都位于 scripts/theme-builder/，两边用同一份 Dockerfile。
FROM runtime AS theme-builder
WORKDIR /build
RUN apk add --no-cache npm && npm install --global yarn@1.22.22
COPY scripts/theme-builder/package.json scripts/theme-builder/yarn.lock ./
RUN yarn install --production --non-interactive && \
    find /build/node_modules \( -name "*.d.ts" -o -name "*.d.mts" -o -name "*.d.cts" -o -name "*.map" -o -iname "README*" -o -iname "CHANGELOG*" -o -iname "HISTORY*" \) -type f -delete

# ==========================================
# 最终运行镜像
# ==========================================
FROM runtime
ARG SHOPARK_BINARY=dist/shopark-linux-amd64
ARG SHOPARK_VERSION=v2.0.0

WORKDIR /var/www/shopark

# 1. 复制宿主机编译好的 Go 主程序并赋权
COPY --chmod=755 ${SHOPARK_BINARY} ./shopark
RUN printf '%s\n' "${SHOPARK_VERSION}" > /var/www/shopark/VERSION

# 2. 复制核心运行依赖与资产
COPY --from=plugins /build ./plugins
COPY resource ./resource
COPY themes ./themes
COPY dist/admin ./dist/admin
COPY dist/site ./dist/site
COPY public ./public
COPY --from=theme-builder /build ./scripts/theme-builder
COPY scripts/build-ai-decor-theme.mjs scripts/run-ai-launch.mjs ./scripts/
COPY scripts/lib/resolve-ts.mjs scripts/lib/ai-decor-modules.mjs scripts/lib/theme-decor-files.mjs ./scripts/lib/

# 3. 复制容器入口脚本并赋予执行权限
COPY --chmod=755 scripts/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# 4. 预创建运行态与挂载点目录，并备份内置应用插件与官方主题源码供宿主机挂载时自愈释放
RUN mkdir -p data config runtime public/uploads && \
    cp -r plugins/app /var/www/shopark/.builtin-plugins-app && \
    cp -r themes /var/www/shopark/.builtin-themes

EXPOSE 5490

# 5. 入口与主程序启动
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["./shopark"]

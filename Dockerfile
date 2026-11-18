# The job image: one image for every job type (PHP, Flutter, Go, Node, PostgreSQL server binaries,
# Claude Code), run by GitHub Actions as a `container:`.
#
# No USER directive because Actions needs root to mount its workspace; the scripts under /opt/ci
# drop to the unprivileged `ci` account (uid 2000) with setpriv before they touch anything that
# came from a pull request. Every download is pinned by version and sha256; bump the two together.
# There are no ARG lines, so a version lives next to the checksum it belongs to.
#
# The base is Ubuntu 26.04 LTS, the system of the hosted runners (`ubuntu-latest` moves to it
# between 19 October and 19 November 2026), pinned by digest: the tag moves.
#
# Size is what a job pays for at start: the runner pulls and unpacks the whole image before the
# first step, and unpacking, not the download, is most of that time. So nothing is installed that a
# job does not run, and what the SDKs ship for other purposes is dropped in the layer that
# installs them (a later `rm` would only hide bytes the image still carries).

# --- php: upstream PHP built from source, so the image carries what production runs with no
# compiler toolchain for it and no php source. Only /usr/local (the official php image's layout)
# and the list of runtime packages the binaries link against come across. The tarball checksum is
# the one php.net publishes for php-8.5.12.tar.xz; the two PECL checksums are those of the release
# tarballs.
FROM ubuntu:26.04@sha256:d66b366dac61b575bee2aef07e9c26e8070096fbe84a3d4d3eb0da069b5d76db AS php

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        autoconf \
        bison \
        build-essential \
        ca-certificates \
        curl \
        libargon2-dev \
        libcurl4-openssl-dev \
        libfreetype-dev \
        libicu-dev \
        libjpeg-dev \
        libonig-dev \
        libpng-dev \
        libpq-dev \
        libreadline-dev \
        libsodium-dev \
        libsqlite3-dev \
        libssl-dev \
        libwebp-dev \
        libxml2-dev \
        libzip-dev \
        pkg-config \
        re2c \
        xz-utils \
        zlib1g-dev

RUN php_version=8.5.12 \
    && php_sha256=08bc2eba2a588654ade1357174aa646b761556c862dda0678345ee29ed481209 \
    && curl -fsSLo /tmp/php.tar.xz "https://www.php.net/distributions/php-${php_version}.tar.xz" \
    && echo "${php_sha256}  /tmp/php.tar.xz" | sha256sum -c - \
    && mkdir /tmp/php-src \
    && tar -C /tmp/php-src --strip-components=1 -xJf /tmp/php.tar.xz \
    && cd /tmp/php-src \
    && ./configure \
        --prefix=/usr/local \
        --with-config-file-path=/usr/local/etc/php \
        --with-config-file-scan-dir=/usr/local/etc/php/conf.d \
        --enable-option-checking=fatal \
        --disable-cgi \
        --disable-phpdbg \
        --enable-bcmath \
        --enable-exif \
        --enable-ftp \
        --enable-gd \
        --enable-intl \
        --enable-mbstring \
        --enable-mysqlnd \
        --enable-pcntl \
        --enable-sockets \
        --with-curl \
        --with-freetype \
        --with-jpeg \
        --with-openssl \
        --with-password-argon2 \
        --with-pdo-pgsql \
        --with-pdo-sqlite \
        --with-pgsql \
        --with-readline \
        --with-sodium \
        --with-webp \
        --with-zip \
        --with-zlib \
    && make -j"$(nproc)" \
    && make install \
    && mkdir -p /usr/local/etc/php/conf.d

# The PECL extensions are shared objects, loaded from conf.d.
RUN set -eux; \
    for item in \
        pcov:1.0.12:23255c8c9335a9636ccb743f5302436a97a582a0bbde9869485be911bbc15da8 \
        redis:6.3.0:0d5141f634bd1db6c1ddcda053d25ecf2c4fc1c395430d534fd3f8d51dd7f0b5; do \
        name="${item%%:*}"; rest="${item#*:}"; version="${rest%%:*}"; sha256="${rest#*:}"; \
        curl -fsSLo "/tmp/${name}.tgz" "https://pecl.php.net/get/${name}-${version}.tgz"; \
        echo "${sha256}  /tmp/${name}.tgz" | sha256sum -c -; \
        mkdir "/tmp/${name}-src"; \
        tar -C "/tmp/${name}-src" --strip-components=1 -xzf "/tmp/${name}.tgz"; \
        (cd "/tmp/${name}-src" && phpize && ./configure --with-php-config=/usr/local/bin/php-config && make -j"$(nproc)" && make install); \
        echo "extension=${name}.so" > "/usr/local/etc/php/conf.d/${name}.ini"; \
    done

# Strip, drop what a job never uses, and list the packages the binaries link against. /usr/local
# holds nothing but PHP in this stage, so the whole directory comes across.
RUN set -eux; \
    strip --strip-all /usr/local/bin/php; \
    find /usr/local/lib/php -name '*.so' -exec strip --strip-unneeded {} +; \
    rm -rf /usr/local/php /usr/local/include /usr/local/lib/php/build /usr/local/bin/phpize /usr/local/bin/php-config; \
    find /usr/local/lib/php /usr/local/bin/php -type f \( -name '*.so' -o -path '/usr/local/bin/php' \) -exec ldd {} + \
        | awk '/=> \//{print $3}' | sort -u | xargs -r readlink -f | sort -u \
        | xargs -r dpkg-query -S | cut -d: -f1 | sort -u > /php-deps.txt; \
    test -s /php-deps.txt; \
    php -m | tr '\n' ' '; echo; tr '\n' ' ' < /php-deps.txt; echo

# --- the image
FROM ubuntu:26.04@sha256:d66b366dac61b575bee2aef07e9c26e8070096fbe84a3d4d3eb0da069b5d76db

ENV DEBIAN_FRONTEND=noninteractive

COPY --from=php /php-deps.txt /tmp/php-deps.txt

# One apt layer; the libraries PHP links against come with it, from the list the php stage wrote.
# git, curl, unzip and xz-utils are what actions/checkout, the downloads below and the Flutter tool
# need; util-linux brings setpriv and procps brings pgrep and pkill, both used by the sandbox
# scripts. librsvg2-bin, python3 and python3-pil are the icon renderer and the comparer and
# entitlement checker the Flutter repositories' lint steps run. gcc and libc6-dev are cgo's
# toolchain, which `go test -race` needs. openssh-client and rsync reach a repository's box, tmux
# hosts interactive sessions, jq reads manifests. No sudo: nothing in a job may regain root.
#
# The PostgreSQL server binaries are for suites that run against a real database: a job runs
# initdb and pg_ctl as `ci` against a data directory of its own. The distribution's cluster is
# switched off before the server package is configured, so no cluster exists and no service starts
# at build time. The binaries live outside PATH. Docs, man pages and locales are dropped with the
# apt lists.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gcc \
        git \
        jq \
        libc6-dev \
        librsvg2-bin \
        openssh-client \
        $(cat /tmp/php-deps.txt) \
        postgresql-common \
        procps \
        python3 \
        python3-pil \
        rsync \
        tmux \
        unzip \
        util-linux \
        xz-utils \
        zip \
    && echo 'create_main_cluster = false' >> /etc/postgresql-common/createcluster.conf \
    && apt-get install -y --no-install-recommends postgresql-18 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /usr/share/doc /usr/share/man /usr/share/locale /usr/share/i18n /var/cache/debconf/*-old /tmp/php-deps.txt

COPY --from=php /usr/local /usr/local

# The list the php stage wrote is the only thing that puts PHP's libraries here, and a path the
# stage could not map to a package drops out of it without a word: so the build runs php and
# fails on any library the binaries cannot find.
RUN php -m > /dev/null \
    && ! ldd /usr/local/bin/php /usr/local/lib/php/extensions/*/*.so | grep -q 'not found'

# composer is pinned by digest: the `2` tag moves.
COPY --from=composer:2@sha256:3d1eb9437516b0ba88c46a0bb05826451a1ab178d29adacb5ded26dad0899ae4 /usr/bin/composer /usr/local/bin/composer

# A fresh HOME is created per run by ci-sandbox; the account exists so setpriv has a stable uid
# to drop to.
RUN useradd -u 2000 -m -s /bin/bash ci

# Node 26 LTS (Lithium) from the official tarball. The checksum is the linux-x64 xz line of
# SHASUMS256.txt for that version. The headers are left out: node-gyp fetches the ones it needs.
RUN node_version=26.13.1 \
    && node_sha256=5c063e46bab0fbc1c17cc445d7ff129cbdcd0471be6ed83b6ab864f8143bc864 \
    && curl -fsSLo /tmp/node.tar.xz "https://nodejs.org/dist/v${node_version}/node-v${node_version}-linux-x64.tar.xz" \
    && echo "${node_sha256}  /tmp/node.tar.xz" | sha256sum -c - \
    && tar -C /usr/local --strip-components=1 --no-same-owner \
        --exclude='*/share/doc' --exclude='*/share/man' --exclude="node-v${node_version}-linux-x64/include" \
        --exclude='*/share/systemtap' \
        --exclude='*/CHANGELOG.md' --exclude='*/LICENSE' --exclude='*/README.md' \
        -xJf /tmp/node.tar.xz \
    && rm /tmp/node.tar.xz

# The Go the Laravel and Go suites build with: the minor the gateway's go.mod and the deploy
# workflow build the shipped binary with (1.25), at its latest patch, so the suites test the
# standard library and vet the binary ships with. The checksum is the linux-amd64 archive one
# from go.dev/dl. The standard library's tests, the API files, the docs and the misc tree are never
# run by a job (anchored: `go/doc` must not match the package `src/go/doc`).
RUN go_version=1.25.14 \
    && go_sha256=a21ae5633a269bcd7e90cf767e48225633795e99d831742cbf3397064fee7712 \
    && curl -fsSLo /tmp/go.tar.gz "https://go.dev/dl/go${go_version}.linux-amd64.tar.gz" \
    && echo "${go_sha256}  /tmp/go.tar.gz" | sha256sum -c - \
    && tar -C /usr/local -xzf /tmp/go.tar.gz --anchored \
        --exclude='go/test' --exclude='go/api' --exclude='go/doc' --exclude='go/misc' \
    && find /usr/local/go/src -type d -name testdata -prune -exec rm -rf {} + \
    && rm /tmp/go.tar.gz

# The checksum is the bun-linux-x64.zip line of the release's SHASUMS256.txt.
RUN bun_version=1.4.4 \
    && bun_sha256=bf8ccbfb2b0b80159e0f9a6d15c55317add8077534dbc6130a3edb52fccb395c \
    && curl -fsSLo /tmp/bun.zip "https://github.com/oven-sh/bun/releases/download/bun-v${bun_version}/bun-linux-x64.zip" \
    && echo "${bun_sha256}  /tmp/bun.zip" | sha256sum -c - \
    && unzip -j -d /usr/local/bin /tmp/bun.zip bun-linux-x64/bun \
    && chmod 0755 /usr/local/bin/bun \
    && rm /tmp/bun.zip

# Static build, both binaries: no package repository, no service. The checksum is the one
# pkgs.tailscale.com publishes next to the amd64 tarball.
RUN tailscale_version=1.104.7 \
    && tailscale_sha256=e56693ff74a64f2591b7e819c280635a100aae1ddfb0ef058fcd052b7cd8d16c \
    && curl -fsSLo /tmp/tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${tailscale_version}_amd64.tgz" \
    && echo "${tailscale_sha256}  /tmp/tailscale.tgz" | sha256sum -c - \
    && tar -C /usr/local/bin --strip-components=1 --no-same-owner -xzf /tmp/tailscale.tgz \
        "tailscale_${tailscale_version}_amd64/tailscale" "tailscale_${tailscale_version}_amd64/tailscaled" \
    && rm /tmp/tailscale.tgz

# The native linux-x64 binary, not the npm package: no node runtime dependency and no install
# scripts. The checksum is the digest GitHub publishes for the Linux-x86_64 asset of the release.
# Root-owned, so a job running as `ci` cannot replace it.
RUN sentry_version=3.8.2 \
    && sentry_sha256=c958865f9d4000183509ea21b1f04925d5390de6d8d87386b9e69f2b305070c3 \
    && curl -fsSLo /tmp/sentry-cli "https://github.com/getsentry/sentry-cli/releases/download/${sentry_version}/sentry-cli-Linux-x86_64" \
    && echo "${sentry_sha256}  /tmp/sentry-cli" | sha256sum -c - \
    && install -m 0755 /tmp/sentry-cli /usr/local/bin/sentry-cli \
    && rm /tmp/sentry-cli

# The native linux-x64 binary from the release bucket, not the npm package: no node runtime
# dependency and no install scripts. The checksum is the linux-x64 entry of that version's
# manifest.json. Root-owned, so a job running as `ci` cannot replace it.
RUN claude_version=2.1.326 \
    && claude_sha256=b6b3647d981130dc44fc670846ae97b6cde531ffb667cf9c4d17cfcafb38cb37 \
    && curl -fsSLo /usr/local/bin/claude "https://downloads.claude.ai/claude-code-releases/${claude_version}/linux-x64/claude" \
    && echo "${claude_sha256}  /usr/local/bin/claude" | sha256sum -c - \
    && chmod 0755 /usr/local/bin/claude

# Latest stable (3.50.x) from the official releases manifest. One layer from download to
# ownership: the recursive chmod and chown touch every file of the SDK, and in a layer of their
# own they would store a changed copy of each. Only the universal and web artifacts are fetched at
# build time; the tool snapshot and the version file are made here too, so a job neither rebuilds
# the tool nor downloads an engine.
#
# What a job never runs is dropped before the layer closes, about two thirds of what the SDK
# unpacks to: the pub cache the tool's own packages were fetched into, the Android and profile or
# release engine artifacts (the repositories analyze, test and build for the web), the engine
# sources, the SDK's own dev, examples, docs and package tests, and the DevTools web app (its
# version.json stays: the tool reads it for `flutter doctor` and whenever it rewrites its version
# file). The
# tarball's git history is replaced by a one-commit clone of the same commit: the tool asks git
# for its revision and tag, and still gets them. A job that needs an artifact that is gone
# downloads it, as it would on a fresh SDK.
#
# The SDK stays root-owned, readable but unwritable by `ci`: a file planted in /opt/flutter/bin
# would be resolved by anything that has it on PATH. Only what the Flutter tool writes at run time
# belongs to `ci`: bin/cache (its lockfile and stamps) and packages/flutter_tools/.dart_tool (pub
# rewrites its package_config.json on every `flutter pub get`). The safe.directory entry lets `ci`
# run git in the root-owned SDK checkout.
RUN flutter_version=3.50.0 \
    && flutter_sha256=6ea2d806fd57269ae783e6788e2a81fc26eaad782f1e0d0ff38623bb765ff9f5 \
    && curl -fsSLo /tmp/flutter.tar.xz \
        "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${flutter_version}-stable.tar.xz" \
    && echo "${flutter_sha256}  /tmp/flutter.tar.xz" | sha256sum -c - \
    && tar -C /opt --no-same-owner -xJf /tmp/flutter.tar.xz \
    && rm /tmp/flutter.tar.xz \
    && git config --system --add safe.directory /opt/flutter \
    && /opt/flutter/bin/flutter config --no-analytics \
    && /opt/flutter/bin/flutter --version \
    && /opt/flutter/bin/flutter precache --universal --web \
    && rm -rf /root/.pub-cache /root/.dart /root/.dartServer \
    && cd /opt/flutter/bin/cache/artifacts/engine \
    && rm -rf android-* *-profile *-release \
    && cd /opt/flutter \
    && rm -rf engine dev examples docs packages/*/test \
    && find bin/cache/dart-sdk/bin/resources/devtools -mindepth 1 ! -name version.json -delete \
    && git clone -q --depth 1 file:///opt/flutter /tmp/flutter-shallow \
    && rm -rf /opt/flutter/.git \
    && mv /tmp/flutter-shallow/.git /opt/flutter/.git \
    && rm -rf /tmp/flutter-shallow \
    && git -C /opt/flutter remote set-url origin https://github.com/flutter/flutter.git \
    && git -C /opt/flutter describe --tags --exact-match \
    && /opt/flutter/bin/flutter --version \
    && chmod -R go-w,a+rX /opt/flutter \
    && chown -R ci:ci /opt/flutter/bin/cache /opt/flutter/packages/flutter_tools/.dart_tool

# Explicit glob, not the whole directory: scripts/test holds the harness tests and must not ship.
# COPY writes root-owned files, so a job running as `ci` cannot rewrite the code that sandboxes it.
COPY --chmod=0755 scripts/ci-* /opt/ci/

# /opt/flutter/bin is not here: ci-sandbox puts it on the PATH of the sandboxed child only, with
# the Go and PostgreSQL directories.
ENV PATH=/opt/ci:/usr/local/go/bin:/usr/lib/postgresql/18/bin:${PATH}

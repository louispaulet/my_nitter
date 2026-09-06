ARG NITTER_REF

FROM nimlang/nim:2.2.6-alpine-regular AS builder

RUN apk add --no-cache \
    git \
    libsass-dev \
    pcre

WORKDIR /build

ARG NITTER_REF
RUN test -n "${NITTER_REF}" \
    && git init nitter \
    && cd nitter \
    && git remote add origin https://github.com/zedeus/nitter.git \
    && git fetch --depth=1 origin "${NITTER_REF}" \
    && git checkout --detach FETCH_HEAD

WORKDIR /build/nitter

RUN nimble install -y --depsOnly
RUN nimble build -d:danger -d:lto -d:strip --mm:refc \
    && nimble scss \
    && nimble md

FROM alpine:3.22

RUN apk add --no-cache \
    pcre \
    ca-certificates \
    openssl \
    gettext \
    busybox-extras

WORKDIR /src

COPY --from=builder /build/nitter/nitter ./nitter
COPY --from=builder /build/nitter/public ./public
COPY docker/nitter.conf.template /etc/nitter/nitter.conf.template
COPY docker/entrypoint.sh /usr/local/bin/nitter-entrypoint

RUN chmod 0755 /usr/local/bin/nitter-entrypoint \
    && adduser -h /src -D -s /bin/sh nitter

USER nitter

ENV NITTER_CONF_FILE=/tmp/nitter.conf \
    NITTER_SESSIONS_FILE=/run/secrets/nitter_sessions

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/nitter-entrypoint"]


FROM openresty/openresty:1.31.1.1-4-alpine-fat@sha256:035818c9596ce60cdc816fc1941db0414d50398644ec9567b45fded04a76e7d0 AS build

COPY bin/install-toolchain /opt/toolchain/install-toolchain
RUN sh /opt/toolchain/install-toolchain compiler http

WORKDIR /src

COPY tlconfig.lua ./
COPY bin ./bin
COPY declarations ./declarations
COPY config ./config
COPY src ./src
RUN sh bin/build

FROM openresty/openresty:1.31.1.1-4-alpine@sha256:52ff9a6e337bd0138745c73cdfeb5aaa0e783e29eeec0695eec6971c1231f3bd

ARG KINETIX_SERVICE_VERSION

RUN apk upgrade --no-cache \
    && addgroup -S -g 10001 edge \
    && adduser -S -D -H -u 10001 -G edge edge \
    && mkdir -p /opt/edge/conf /opt/edge/logs /opt/edge/temp \
    && chown -R edge:edge /opt/edge/logs /opt/edge/temp

COPY --from=build \
    /usr/local/openresty/luajit/share/lua/5.1/resty/http.lua \
    /usr/local/openresty/luajit/share/lua/5.1/resty/http_connect.lua \
    /usr/local/openresty/luajit/share/lua/5.1/resty/http_headers.lua \
    /usr/local/openresty/site/lualib/resty/
COPY --from=build /src/build/lua /opt/edge/lua
COPY nginx/nginx.conf /opt/edge/conf/nginx.conf

ENV KINETIX_SERVICE_VERSION=$KINETIX_SERVICE_VERSION

USER edge

EXPOSE 8080 9145

STOPSIGNAL SIGQUIT

HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/health/ready"]

ENTRYPOINT ["/usr/local/openresty/bin/openresty", "-p", "/opt/edge/", "-c", "conf/nginx.conf"]

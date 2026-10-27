FROM openresty/openresty:1.31.1.1-5-alpine-fat@sha256:32d74c9cb9190e28d07915dbe79d97439d9bbc151b5aff68b7727aa3bb55cce1 AS build

COPY bin/install-toolchain /opt/toolchain/install-toolchain
RUN sh /opt/toolchain/install-toolchain compiler http

WORKDIR /src

COPY tlconfig.lua ./
COPY bin ./bin
COPY declarations ./declarations
COPY config ./config
COPY src ./src
RUN sh bin/build

FROM openresty/openresty:1.31.1.1-5-alpine@sha256:646cdd1451ea0d465ee4a5aa42f146228f04101e318ede576f9f08a78d10423d

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

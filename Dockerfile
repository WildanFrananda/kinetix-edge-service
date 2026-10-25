FROM openresty/openresty:1.31.1.1-3-alpine-fat@sha256:df3b068317a76ef121686711d83990ec09c151e117d005d4d46b5458720afe29 AS build

COPY bin/install-toolchain /opt/toolchain/install-toolchain
RUN sh /opt/toolchain/install-toolchain compiler http

WORKDIR /src

COPY tlconfig.lua ./
COPY bin ./bin
COPY declarations ./declarations
COPY config ./config
COPY src ./src
RUN sh bin/build

FROM openresty/openresty:1.31.1.1-3-alpine@sha256:e260a5b63b78700eb8047e934950a17b4ab3980a77ef254ec486fff8ea4617e6

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

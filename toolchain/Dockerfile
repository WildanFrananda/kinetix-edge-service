FROM openresty/openresty:1.31.1.1-5-alpine-fat@sha256:32d74c9cb9190e28d07915dbe79d97439d9bbc151b5aff68b7727aa3bb55cce1

COPY bin/install-toolchain /opt/toolchain/install-toolchain

RUN sh /opt/toolchain/install-toolchain compiler http test \
    && rm -rf /root/.cache

WORKDIR /workspace

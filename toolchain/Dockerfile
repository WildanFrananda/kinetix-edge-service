FROM openresty/openresty:1.31.1.1-4-alpine-fat@sha256:035818c9596ce60cdc816fc1941db0414d50398644ec9567b45fded04a76e7d0

COPY bin/install-toolchain /opt/toolchain/install-toolchain

RUN sh /opt/toolchain/install-toolchain compiler http test \
    && rm -rf /root/.cache

WORKDIR /workspace

FROM openresty/openresty:1.31.8.1-0-alpine-fat@sha256:f104df1e34d48308aeec2b0c8dcda405a6e5aa1910c6dd8311d772aa8e70ee39

COPY bin/install-toolchain /opt/toolchain/install-toolchain

RUN sh /opt/toolchain/install-toolchain compiler http test \
    && rm -rf /root/.cache

WORKDIR /workspace

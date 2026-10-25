FROM openresty/openresty:1.31.1.1-3-alpine-fat@sha256:df3b068317a76ef121686711d83990ec09c151e117d005d4d46b5458720afe29

COPY bin/install-toolchain /opt/toolchain/install-toolchain

RUN sh /opt/toolchain/install-toolchain compiler http test \
    && rm -rf /root/.cache

WORKDIR /workspace

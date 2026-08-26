FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS builder
LABEL maintainer="tindy.it@gmail.com"
ARG THREADS="4"

# build minimized
WORKDIR /
RUN set -xe && \
    apk add --no-cache --virtual .build-tools git g++ build-base linux-headers cmake python3 py3-pip && \
    apk add --no-cache --virtual .build-deps curl-dev rapidjson-dev pcre2-dev yaml-cpp-dev && \
    git clone --no-checkout https://github.com/ftk/quickjspp.git && \
    cd quickjspp && \
    git fetch origin 0c00c48895919fc02da3f191a2da06addeb07f09 && \
    git checkout 0c00c48895919fc02da3f191a2da06addeb07f09 && \
    git submodule update --init && \
    cmake -DCMAKE_BUILD_TYPE=Release . && \
    make quickjs -j $THREADS && \
    install -d /usr/lib/quickjs/ && \
    install -m644 quickjs/libquickjs.a /usr/lib/quickjs/ && \
    install -d /usr/include/quickjs/ && \
    install -m644 quickjs/quickjs.h quickjs/quickjs-libc.h /usr/include/quickjs/ && \
    install -m644 quickjspp.hpp /usr/include && \
    cd .. && \
    git clone --no-checkout https://github.com/PerMalmberg/libcron && \
    cd libcron && \
    git fetch origin ee34810b11bd23c8be637345532f91059b68b2d7 && \
    git checkout ee34810b11bd23c8be637345532f91059b68b2d7 && \
    git submodule update --init && \
    cmake -DCMAKE_BUILD_TYPE=Release . && \
    make libcron -j $THREADS && \
    install -m644 libcron/out/Release/liblibcron.a /usr/lib/ && \
    install -d /usr/include/libcron/ && \
    install -m644 libcron/include/libcron/* /usr/include/libcron/ && \
    install -d /usr/include/date/ && \
    install -m644 libcron/externals/date/include/date/* /usr/include/date/ && \
    cd .. && \
    git clone --no-checkout https://github.com/ToruNiina/toml11 && \
    cd toml11 && \
    git fetch origin 499be3c177bcf9b42848d5d9567153e4edfcbc8a && \
    git checkout 499be3c177bcf9b42848d5d9567153e4edfcbc8a && \
    cmake -DCMAKE_CXX_STANDARD=11 . && \
    make install -j $THREADS

COPY . /subconverter
WORKDIR /subconverter
RUN set -xe && \
    PIP_BREAK_SYSTEM_PACKAGES=1 python3 -m pip install --no-cache-dir \
        GitPython==3.1.59 gitdb==4.0.12 smmap==5.0.3 typing-extensions==4.7.1 && \
    python3 scripts/update_rules.py -c scripts/rules_config.conf && \
    cmake -DCMAKE_BUILD_TYPE=Release . && \
    make -j $THREADS

# build final image
FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b
LABEL maintainer="tindy.it@gmail.com"

RUN apk add --no-cache --virtual subconverter-deps pcre2 libcurl yaml-cpp

COPY --from=builder /subconverter/subconverter /usr/bin/
COPY --from=builder /subconverter/base /base/

RUN addgroup -S subconverter && \
    adduser -S -D -h /base -G subconverter subconverter && \
    chown -R subconverter:subconverter /base /usr/bin/subconverter

ENV TZ=Africa/Abidjan
RUN ln -sf /usr/share/zoneinfo/$TZ /etc/localtime
RUN echo $TZ > /etc/timezone

# set entry
WORKDIR /base
USER subconverter
CMD subconverter

EXPOSE 25500/tcp

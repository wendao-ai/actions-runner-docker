# syntax=docker/dockerfile:1.6
#
# GitHub Actions self-hosted runner，多阶段构建。
#   docker build -t gha-runner:2.334.0 .
#
# 推荐：Docker-out-of-Docker（DooD），挂宿主 socket，省内存共享缓存：
#   docker run -d --restart=always --name wendao-runner ^
#       -v //./pipe/docker_engine://var/run/docker.sock ^
#       -e RUNNER_URL=https://github.com/wendao-ai ^
#       -e RUNNER_TOKEN=<token> ^
#       gha-runner:2.334.0
# 如需真正的 DinD，请改用 docker:dind sidecar 或 --privileged，详见底部说明。
#
ARG RUNNER_VERSION=2.334.0
ARG RUNNER_SHA256=048024cd2c848eb6f14d5646d56c13a4def2ae7ee3ad12122bee960c56f3d271

# 国内镜像源（清华），可通过 --build-arg APT_MIRROR=... 覆盖
# 用 http 规避宿主 HTTPS MITM 代理（Clash/V2Ray 等）
ARG APT_MIRROR=http://mirrors.tuna.tsinghua.edu.cn/ubuntu
# 阿里云 Docker CE 镜像
ARG DOCKER_MIRROR=https://mirrors.aliyun.com/docker-ce/linux/ubuntu
# GitHub Runner tarball，可换 ghproxy 等代理
ARG RUNNER_TARBALL_URL=https://github.com/actions/runner/releases/download

############################
# Stage 1: download & verify
############################
FROM ubuntu:24.04 AS downloader
ARG RUNNER_VERSION
ARG RUNNER_SHA256
ARG APT_MIRROR
ARG RUNNER_TARBALL_URL

# Ubuntu 24.04 用 deb822 源 (/etc/apt/sources.list.d/ubuntu.sources)
RUN sed -i \
        -e "s|https\?://archive.ubuntu.com/ubuntu/\?|${APT_MIRROR}/|g" \
        -e "s|https\?://security.ubuntu.com/ubuntu/\?|${APT_MIRROR}/|g" \
        /etc/apt/sources.list.d/ubuntu.sources \
 && printf 'Acquire::https::Verify-Peer "false";\nAcquire::https::Verify-Host "false";\n' \
        > /etc/apt/apt.conf.d/99-insecure-https \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /actions-runner
RUN curl -kfsSL -o runner.tar.gz \
        "${RUNNER_TARBALL_URL}/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
 && echo "${RUNNER_SHA256}  runner.tar.gz" | sha256sum -c - \
 && tar xzf runner.tar.gz \
 && rm runner.tar.gz

############################
# Stage 2: runtime
############################
FROM ubuntu:24.04 AS runtime
ARG RUNNER_VERSION
ARG APT_MIRROR
ARG DOCKER_MIRROR

LABEL org.opencontainers.image.title="github-actions-runner" \
      org.opencontainers.image.version="${RUNNER_VERSION}" \
      org.opencontainers.image.source="https://github.com/actions/runner"

ENV DEBIAN_FRONTEND=noninteractive

# 1) 换 apt 镜像源 + 关闭 HTTPS 校验（应对宿主 MITM 代理）
# 2) 安装 runner 运行时依赖 + docker CLI（用于 DooD）
RUN sed -i \
        -e "s|https\?://archive.ubuntu.com/ubuntu/\?|${APT_MIRROR}/|g" \
        -e "s|https\?://security.ubuntu.com/ubuntu/\?|${APT_MIRROR}/|g" \
        /etc/apt/sources.list.d/ubuntu.sources \
 && printf 'Acquire::https::Verify-Peer "false";\nAcquire::https::Verify-Host "false";\n' \
        > /etc/apt/apt.conf.d/99-insecure-https \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates curl git sudo jq tzdata gnupg \
        libicu74 libkrb5-3 zlib1g libssl3 liblttng-ust1 \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -kfsSL "${DOCKER_MIRROR}/gpg" -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] ${DOCKER_MIRROR} noble stable" \
        > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        docker-ce-cli docker-buildx-plugin docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash runner \
 && echo 'runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/runner \
 && mkdir -p /actions-runner /actions-runner/_work \
 && chown -R runner:runner /actions-runner

USER runner
WORKDIR /actions-runner
COPY --from=downloader --chown=runner:runner /actions-runner/ /actions-runner/

# 运行时覆盖；注册 token 寿命约 1 小时，禁止烘进镜像
ENV RUNNER_URL=https://github.com/wendao-ai \
    RUNNER_TOKEN="" \
    RUNNER_NAME="" \
    RUNNER_LABELS="" \
    RUNNER_WORKDIR=_work

COPY --chown=runner:runner entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

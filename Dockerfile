ARG DEBIAN_VERSION=bookworm
FROM debian:${DEBIAN_VERSION} AS builder
RUN sed -i 's/deb.debian.org/mirrors.ustc.edu.cn/g' /etc/apt/sources.list.d/debian.sources

# 安装编译工具（GCC、make、内核头文件构建依赖）
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    make \
    build-essential \
    libncurses-dev \
    libelf1 \
    && rm -rf /var/lib/apt/lists/*

# 设置工作目录
WORKDIR /driver

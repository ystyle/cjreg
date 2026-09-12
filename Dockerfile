# cjreg — 生产镜像（产物打包）
#
# 构建策略：**宿主工具链产出二进制 → 镜像只打包**（不在容器内编译）。
# 原因：cjreg 通过 path 依赖引用 ../cjxt（本地开发），容器内自构建需要额外准备兄弟仓库与工具链镜像；
# 与同系列仓颉项目（忆时塔 chronomem / 集思阁 jisi-pavilion / liveboard）保持一致。
#
#   1) eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
#   2) cjpm build -j 16
#   3) docker compose up -d --build        # 或：bash scripts/docker-deploy.sh
#
# 基础镜像 archlinux：与宿主编译环境 glibc 一致（避免 GLIBC 符号缺失）；
# cjreg 二进制为 --static 但仍动态依赖 liburing.so.2（badger-cj 的 io_uring 支持）与 libstdc++，
# 另装 tzdata（时区/日志）与 ca-certificates（上游回源 TLS）。
FROM archlinux:latest

RUN pacman -Sy --noconfirm \
        liburing \
        tzdata \
        ca-certificates \
        curl \
    && rm -rf /var/cache/pacman/pkg

# 非 root 运行（uid 1000 与宿主数据目录属主对齐，挂卷后可写）
RUN useradd -u 1000 -m app

WORKDIR /app

# 二进制（默认取宿主构建产物；CI 里用 --build-arg CJREG_BIN=... 指定）
# chmod：从 CI artifact 解出的文件会丢执行位（docker: exec "/app/cjreg": permission denied）
ARG CJREG_BIN=target/release/bin/ystyle::cjreg
COPY ${CJREG_BIN} /app/cjreg
RUN chmod 0755 /app/cjreg

# Web 界面静态资源（cjxt 的 serveStatic("/css", "public/css") 相对运行目录）
COPY public /app/public

# 数据目录（compose 挂载卷）：cjreg.db + blobs/ + cjreg.toml
RUN mkdir -p /data && chown -R app:app /data /app

USER app
ENV HOME=/app

# 发布大包（>30MB）时的仓颉 GC 堆：运行时默认上限 256MB，整包读入内存的路径会触顶；
# 可在 compose/.env 里按机器内存覆盖（如 4GB）
ENV cjHeapSize=2GB \
    cjGCThreshold=1GB \
    cjGCInterval=100ms

EXPOSE 8060

# 优雅关闭：SIGTERM → 停 HTTP 服务 → flush memtable 落盘 → exit 0
# （compose 里配 stop_grace_period，给落盘留时间）
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8060/api/health || exit 1

CMD ["/app/cjreg", "serve", "-d", "/data"]

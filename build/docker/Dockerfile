# Dockerfile —— 容器版镜像：把套件产物 target/ 装进 Debian 12 slim，交给套件自带的 start.sh 启停。
#
# 为什么是 Debian 12（而不是 alpine）：
#   随包 node 是 glibc 构建，二进制里引用到 GLIBC_2.28；Debian 12 提供 2.36，满足且稳定。
#   alpine 是 musl，跑不起来 —— 除非换成 musl 版 node 并重编全部原生模块（17 个 .node）。
#
# 为什么不在镜像里另起一套启动逻辑：
#   target/start.sh 已经包含端口探测、反代与门户 token、自检、残留实例清理；
#   容器只补「属主对齐 / 工作区别名 / HOME」这些容器特有的事，见 entrypoint.sh。
#
# 构建（仓库根为上下文，先跑一次构建产出 target）：
#   ./build/build-common.sh                                   # 产出 build/master-build/<work>/target
#   docker build -f build/docker/Dockerfile \
#       --build-arg TARGET_DIR=build/master-build/<work>/target -t dsh:local .
FROM debian:12-slim

# tini：容器里 node 不是 PID 1 时收不到信号，停容器会被等 10 秒强杀；
# ca-certificates：dsh 的远程登录与插件下载都要走 HTTPS；
# tzdata + util-linux：时区正确、setpriv 用来做 PUID/PGID 降权（不额外装 gosu）。
RUN apt-get update \
    && apt-get install -y --no-install-recommends tini ca-certificates tzdata util-linux \
    && rm -rf /var/lib/apt/lists/*

# 构建产物目录（含随包 node、裁剪后的依赖、start.sh）；由 --build-arg 指定，避免写死工作目录名
ARG TARGET_DIR=build/master-build/dsh/target

# target/ 里已含随包 node、裁剪后的依赖与 start.sh，直接整体拷入
COPY ${TARGET_DIR}/ /opt/dsh/

COPY build/docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /opt/dsh/start.sh 2>/dev/null || true

# PKG_VERSION=current：让数据目录恒为 /data/current/.dsh，换镜像版本后旧数据仍可见。
# 端口沿用套件默认：30800 是对外反代（门户/token），30801 是 dsh 本体，只留容器内。
ENV PKG_VAR=/data \
    PKG_VERSION=current \
    DSH_PROXY_PORT=30800 \
    DSH_DSH_PORT=30801 \
    UMASK=0022

VOLUME ["/data"]
EXPOSE 30800

# 健康检查直接复用套件脚本：未运行时返回非 0
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
    CMD ["/opt/dsh/start.sh", "status"]

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]

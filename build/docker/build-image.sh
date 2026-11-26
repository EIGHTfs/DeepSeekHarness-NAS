#!/bin/bash
# build-image.sh —— 把公共 target 打成容器镜像并（可选）推送、冒烟。
#
# 为什么是脚本而不是只留在 workflow 里：
#   CI 的平台清单来自 build/config/platforms.json，每个平台只声明一条「build 命令」。
#   docker 要作为**与其他平台同等地位**的一项被动态调度，就必须有一个可独立执行的入口；
#   顺带的好处是本地也能跑（不需要 GitHub Actions）。
#
# 用法：
#   build-image.sh <target目录> [--arch x86_64|arm64] [--image 名称] [--registry ghcr.io]
#                  [--push] [--no-smoke] [--tag 版本]
#
# 环境变量（CI 里由 workflow 注入）：
#   GITHUB_TOKEN  —— 推镜像用；给了就自动 docker login（否则需事先登录）
#   PKG_VER       —— 不传 --tag 时用 build-meta.env 里的版本
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET_DIR=""
ARCH="x86_64"
IMAGE="eightfs/deepseekharness-nas"
REGISTRY="ghcr.io"
PUSH=0
SMOKE=1
TAG=""
PORT_SMOKE=38080

while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="${2:-x86_64}"; shift 2 ;;
    --image) IMAGE="${2:-}"; shift 2 ;;
    --registry) REGISTRY="${2:-}"; shift 2 ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --push) PUSH=1; shift ;;
    --no-smoke) SMOKE=0; shift ;;
    -*) echo "未知参数: $1" >&2; exit 2 ;;
    *) TARGET_DIR="$1"; shift ;;
  esac
done

[ -n "$TARGET_DIR" ] || { echo "用法: build-image.sh <target目录> [--arch x86_64|arm64] [--push]" >&2; exit 2; }
[ -d "$TARGET_DIR" ] || { echo "✗ target 目录不存在: $TARGET_DIR" >&2; exit 1; }

case "$ARCH" in
  x86_64|arm64) ;;
  *) echo "✗ 未知架构: $ARCH（支持 x86_64 / arm64）" >&2; exit 2 ;;
esac
PLATFORM="linux/amd64"
[ "$ARCH" = "arm64" ] && PLATFORM="linux/arm64"

# 版本：优先 --tag，其次 build-meta.env（与套件同一来源）
if [ -z "$TAG" ]; then
  META="$(dirname "$TARGET_DIR")/build-meta.env"
  if [ -f "$META" ]; then
    TAG="$(grep -m1 '^PKG_VER=' "$META" | cut -d= -f2- | tr -d "\"'")"
  fi
fi
[ -n "$TAG" ] || { echo "✗ 无法确定镜像版本（--tag 或 build-meta.env 的 PKG_VER）" >&2; exit 1; }

# ── 暂存载荷：Dockerfile 的契约是「仓库根为上下文 + --build-arg TARGET_DIR」 ──
STAGE="$ROOT/build/master-build/docker"
echo "▶ 暂存载荷 → $STAGE/target"
rm -rf "$STAGE/target"
mkdir -p "$STAGE"
cp -a "$TARGET_DIR" "$STAGE/target"

# start.sh 不在 target 产物里（打包期由 gen_start_sh 生成），这里补上
bash "$ROOT/build/docker/stage-payload.sh" "$STAGE/target" || { echo "✗ 生成 start.sh 失败" >&2; exit 1; }

IMAGE_REF="${REGISTRY}/${IMAGE}:${TAG}-$([ "$ARCH" = "arm64" ] && echo arm64 || echo amd64)"
echo "▶ 构建镜像 $IMAGE_REF（$PLATFORM）"
if ! docker build -f "$ROOT/build/docker/Dockerfile" \
      --build-arg TARGET_DIR=build/master-build/docker/target \
      --platform "$PLATFORM" -t "$IMAGE_REF" "$ROOT"; then
  echo "✗ 镜像构建失败" >&2; exit 1
fi

# 载荷已进镜像层，及时清掉：800MB 目录留着会让 CI 后置缓存步骤遍历超时
rm -rf "$STAGE/target"

# ── 预检：确认镜像里运行时能在本架构跑（跨架构误装会在这里暴露） ──
echo "▶ 预检（架构 / node / start.sh）"
docker run --rm --entrypoint sh "$IMAGE_REF" -c '
  echo "  容器内 uname: $(uname -m)"
  echo "  node: $(/opt/dsh/bin/node -v 2>&1 | head -1) / arch=$(/opt/dsh/bin/node -p "process.arch" 2>&1 | head -1)"
  echo "  start.sh: $(wc -l < /opt/dsh/start.sh 2>/dev/null || echo 缺失) 行"
' || { echo "✗ 预检失败" >&2; exit 1; }

# ── 冒烟：起容器验「门户 302 + health healthy + 不含宿主路径」 ──
if [ "$SMOKE" = "1" ]; then
  echo "▶ 冒烟（端口 $PORT_SMOKE）"
  SMOKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dsh-smoke.XXXXXX")"
  docker rm -f dsh-smoke >/dev/null 2>&1 || true
  docker run -d --name dsh-smoke --user "$(id -u):$(id -g)" \
    -p "${PORT_SMOKE}:30800" -v "$SMOKE_DIR:/data" "$IMAGE_REF" >/dev/null || { echo "✗ 容器启动失败" >&2; exit 1; }
  ok=0
  for _ in $(seq 1 36); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Sec-Fetch-Dest: document' "http://127.0.0.1:${PORT_SMOKE}/" || true)"
    health="$(docker inspect --format '{{.State.Health.Status}}' dsh-smoke 2>/dev/null || echo unknown)"
    echo "  HTTP=$code health=$health"
    [ "$code" = "302" ] && [ "$health" = "healthy" ] && { ok=1; break; }
    [ "$health" = "unhealthy" ] && break
    sleep 5
  done
  # 镜像内不得出现宿主专属路径（/volumeN/）
  if docker exec dsh-smoke sh -c 'grep -rlE "/volume[0-9]+/" /opt/dsh /entrypoint.sh 2>/dev/null | head -3' | grep -q .; then
    echo "  ✗ 镜像里出现群晖专属路径"; ok=0
  fi
  if [ "$ok" != "1" ]; then
    echo "✗ 冒烟失败，容器日志：" >&2
    docker logs dsh-smoke 2>&1 | tail -40 >&2
    docker cp dsh-smoke:/data "$SMOKE_DIR/cp" >/dev/null 2>&1 && tail -40 "$SMOKE_DIR"/cp/*.log >&2 || true
    docker rm -f dsh-smoke >/dev/null 2>&1 || true
    rm -rf "$SMOKE_DIR" 2>/dev/null || sudo rm -rf "$SMOKE_DIR" 2>/dev/null || true
    exit 1
  fi
  docker rm -f dsh-smoke >/dev/null 2>&1 || true
  rm -rf "$SMOKE_DIR" 2>/dev/null || sudo rm -rf "$SMOKE_DIR" 2>/dev/null || true
  echo "  ✓ 冒烟通过"
fi

# ── 推送 ──
if [ "$PUSH" = "1" ]; then
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "$GITHUB_TOKEN" | docker login "$REGISTRY" -u "${GITHUB_ACTOR:-github-actions}" --password-stdin >/dev/null \
      || { echo "✗ 登录 $REGISTRY 失败" >&2; exit 1; }
  fi
  echo "▶ 推送 $IMAGE_REF"
  docker push "$IMAGE_REF" || { echo "✗ 推送失败" >&2; exit 1; }
fi

echo "✓ 完成：$IMAGE_REF（$TAG / $ARCH）"
echo "IMAGE_REF=$IMAGE_REF"

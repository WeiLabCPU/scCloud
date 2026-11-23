#!/bin/sh
# scCloud 一键启动脚本
# 用法：
#   sh ./start.sh                   # 默认：检查环境 → 拉取预构建镜像 → 启动服务
#   sh ./start.sh --doctor          # 只读环境体检（不改 .env、不拉镜像、不启容器）
#   sh ./start.sh --sync-proxy      # 将终端代理同步到 Docker daemon（sccloud-proxy.conf）并重启后启动
#   sh ./start.sh --clear-proxy     # 清理 sccloud-proxy.conf 并重启 Docker daemon 恢复直连
#   sh ./start.sh --no-pull         # 跳过 pull，仅使用本地已有镜像启动
#   sh ./start.sh --build           # 本地源码构建（无 r-library 时自动跳过 r-engine 或拦截）
#   sh ./start.sh --install-docker  # 缺 Docker 时自动安装（共享机勿默认使用）
#
# 注意：不使用 set -e（步骤失败有分类诊断）；使用 set -u。

set -u

PROJECT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
cd "$PROJECT_DIR" || exit 1

# 兼容官方 rootless Docker 默认安装路径（$HOME/bin）
if [ -n "${HOME:-}" ] && [ -d "${HOME}/bin" ]; then
  case ":${PATH:-}:" in
    *":${HOME}/bin:"*) ;;
    *) PATH="${HOME}/bin:${PATH:-}"; export PATH ;;
  esac
fi

DEFAULT_FRONTEND_IMAGE="ghcr.io/cangiolo/sccloud-frontend:latest"
DEFAULT_BACKEND_IMAGE="ghcr.io/cangiolo/sccloud-backend:latest"
DEFAULT_R_ENGINE_IMAGE="ghcr.io/cangiolo/sccloud-r-engine:latest"
DEFAULT_NGINX_IMAGE="nginx:alpine@sha256:db35bfc6b2951e7f8a72db5db120288c127ffaeeb4a6d4b95a26fead017d5913"
DEFAULT_MARIADB_IMAGE="mariadb:11@sha256:2439dcd7d14010ecd1ff7a4e1c5abe8e208c34fe35290744deeeaac3569043c3"
DEFAULT_REDIS_IMAGE="redis:7-alpine@sha256:ff02b58f971e7d7d156a1267e283fcbbeee91773b6aa36c49dac28ecfe28eadf"
RELEASE_R_TAR_URL="https://github.com/WeiLabCPU/scCloud/releases/download/v1.0.0/sccloud-r-engine-image.tar.gz"

CALLER_WEB_PORT="${WEB_PORT:-}"
CALLER_WEB_BIND="${WEB_BIND_ADDRESS:-}"
CALLER_COMPOSE_FILE="${COMPOSE_FILE:-}"
CALLER_ROOTLESS="${SCCLOUD_ROOTLESS:-${SCLOUD_ROOTLESS:-}}"
CALLER_PROJECTS_DATA_DIR="${PROJECTS_DATA_DIR:-}"

DO_BUILD=0
DO_PULL=1
DO_DOCTOR=0
DO_SYNC_PROXY=0
DO_CLEAR_PROXY=0
INSTALL_DOCKER=0
for arg in "$@"; do
  case "$arg" in
    --build)          DO_BUILD=1; DO_PULL=0 ;;
    --no-pull)        DO_PULL=0 ;;
    --doctor)         DO_DOCTOR=1 ;;
    --sync-proxy)     DO_SYNC_PROXY=1 ;;
    --clear-proxy)    DO_CLEAR_PROXY=1 ;;
    --install-docker) INSTALL_DOCKER=1 ;;
    -h|--help)
      cat <<'EOF'
用法: sh ./start.sh [--doctor|--sync-proxy|--clear-proxy|--no-pull|--build|--install-docker]
  --doctor           只读环境体检（Docker/Rootless/代理/磁盘/端口/镜像），不启动服务
  --sync-proxy       将当前终端 HTTP(S)_PROXY 写入 Docker daemon（sccloud-proxy.conf）并重启后继续启动
  --clear-proxy      删除 sccloud-proxy.conf 并重启 Docker daemon，恢复直连
  --no-pull          不 pull，直接使用本地已有镜像
  --build            本地源码构建（缺 r-engine/r-library 时不会误构建 r-engine）
  --install-docker   未检测到 Docker 时自动运行 get.docker.com（仅限有 root 的独享主机）
EOF
      exit 0
      ;;
    *) echo "未知参数：$arg（支持：--doctor / --sync-proxy / --clear-proxy / --no-pull / --build / --install-docker）" >&2; exit 1 ;;
  esac
done

color() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
info()  { printf '%s %s\n' "$(color '1;36' '•')" "$*"; }
ok()    { printf '%s %s\n' "$(color '1;32' '✓')" "$*"; }
warn()  { printf '%s %s\n' "$(color '1;33' '!')" "$*" >&2; }
die()   { printf '%s %s\n' "$(color '1;31' '✗')" "$*" >&2; exit 1; }

now_s() { date +%s; }
elapsed_str() { printf '%ds' $(($2 - $1)); }

SUDO=""
IS_ROOTLESS=0
IS_PODMAN=0
DOCKER_READY=0
DOCKER_ROOT_DIR=""
ROOTLESS_UNIT_STOPPED=0
USE_ROOTLESS_OVERLAY=0
COMPOSE_DISPLAY="docker compose --env-file .env"
PULL_LOG_FILE=""
PULL_RC_FILE=""
PROXY_MISMATCH=0
SHELL_PROXY_DISPLAY=""

# shellcheck disable=SC2329
cleanup_tmp() {
  [ -n "$PULL_LOG_FILE" ] && rm -f "$PULL_LOG_FILE" 2>/dev/null || true
  [ -n "$PULL_RC_FILE" ] && rm -f "$PULL_RC_FILE" 2>/dev/null || true
}
trap cleanup_tmp EXIT

run_docker() {
  if [ -n "$SUDO" ]; then
    "$SUDO" docker "$@"
  else
    docker "$@"
  fi
}

run_compose() {
  env_arg=""
  if [ -f .env ]; then
    env_arg=".env"
  elif [ -f .env.example ]; then
    env_arg=".env.example"
  fi
  if [ -n "$env_arg" ]; then
    if [ "$USE_ROOTLESS_OVERLAY" = "1" ]; then
      run_docker compose --env-file "$env_arg" -f docker-compose.yml -f docker-compose.rootless.yml "$@"
    else
      run_docker compose --env-file "$env_arg" "$@"
    fi
  else
    if [ "$USE_ROOTLESS_OVERLAY" = "1" ]; then
      run_docker compose -f docker-compose.yml -f docker-compose.rootless.yml "$@"
    else
      run_docker compose "$@"
    fi
  fi
}

print_rootless_docker_guide() {
  cat >&2 <<'EOF'

  [共享 Linux 服务器（无 root 权限）推荐使用 Rootless Docker]
  1) 检查前置条件（两文件均需有当前用户记录且数量 ≥ 65536）：
       command -v newuidmap newgidmap
       grep "^$(whoami):" /etc/subuid /etc/subgid
  2) 安装并启用个人 rootless Docker（系统 Docker 在跑时加 --force，勿停系统服务）：
       dockerd-rootless-setuptool.sh install
       systemctl --user enable --now docker
       docker context use rootless
       docker info
     （注：rootless 下 docker info 出现 No cpu cfs quota / io.weight / bridge-nf-call-iptables 等 WARNING 属正常无害）
  3) 如需退出 SSH 后仍保持运行，请管理员执行：
       sudo loginctl enable-linger $(whoami)

  [仅个人独享主机] 若确有管理员权限且接受加入 docker 组（等同 root）：
       sudo usermod -aG docker "$USER" && newgrp docker

  详细步骤见 README.md「共享服务器（Rootless Docker）与代理配置」。
EOF
}

print_proxy_hint() {
  sample_proxy="${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-http://127.0.0.1:7890}}}}"
  if [ "$IS_ROOTLESS" = "1" ]; then
    cat >&2 <<EOF

[Rootless Docker 配置代理]（终端 export https_proxy 不会传递给 systemd --user 里的 dockerd）
mkdir -p ~/.config/systemd/user/docker.service.d
cat <<'CONF' > ~/.config/systemd/user/docker.service.d/sccloud-proxy.conf
[Service]
Environment="HTTP_PROXY=${sample_proxy}"
Environment="HTTPS_PROXY=${sample_proxy}"
Environment="NO_PROXY=localhost,127.0.0.1,::1"
CONF
systemctl --user daemon-reload
systemctl --user restart docker
# 也可直接运行 sh ./start.sh --sync-proxy 自动写入；事后可用 --clear-proxy 清理
EOF
  else
    cat >&2 <<EOF

[Docker daemon 配置代理]（终端 export https_proxy 不会传递给 dockerd）
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo tee /etc/systemd/system/docker.service.d/sccloud-proxy.conf >/dev/null <<'CONF'
[Service]
Environment="HTTP_PROXY=${sample_proxy}"
Environment="HTTPS_PROXY=${sample_proxy}"
Environment="NO_PROXY=localhost,127.0.0.1,::1"
CONF
sudo systemctl daemon-reload
sudo systemctl restart docker
# 也可在有权限时运行 sh ./start.sh --sync-proxy 自动写入；事后可用 --clear-proxy 清理
EOF
  fi
}

docker_proxy_dropin_path() {
  if [ "$IS_ROOTLESS" = "1" ]; then
    printf '%s/systemd/user/docker.service.d/sccloud-proxy.conf' "${XDG_CONFIG_HOME:-${HOME}/.config}"
  else
    printf '/etc/systemd/system/docker.service.d/sccloud-proxy.conf'
  fi
}

can_manage_docker_systemd() {
  [ "$IS_PODMAN" = "1" ] && return 1
  command -v systemctl >/dev/null 2>&1 || return 1
  if [ "$IS_ROOTLESS" = "1" ]; then
    [ -n "${HOME:-}" ] || return 1
    systemctl --user is-active docker >/dev/null 2>&1
    return
  fi
  if [ "$(id -u)" = "0" ] || [ -n "$SUDO" ]; then
    systemctl is-active docker >/dev/null 2>&1
    return
  fi
  return 1
}

is_valid_proxy_url() {
  u=$1
  case "$u" in
    http://?*|https://?*|socks5://?*|socks5h://?*) ;;
    *) return 1 ;;
  esac
  if printf '%s' "$u" | grep -qE '[[:space:]"'"'"'\\;]'; then
    return 1
  fi
  return 0
}

build_safe_no_proxy() {
  raw="${NO_PROXY:-${no_proxy:-}}"
  if [ -z "$raw" ] || printf '%s' "$raw" | grep -qE '[[:space:]"'"'"'\\;]'; then
    printf 'localhost,127.0.0.1,::1'
    return 0
  fi
  case ",${raw}," in
    *",127.0.0.1,"*) printf '%s' "$raw" ;;
    *) printf 'localhost,127.0.0.1,::1,%s' "$raw" ;;
  esac
}

warn_running_containers_before_restart() {
  running_list=$(run_docker ps --format '  - {{.Names}} ({{.Status}})' 2>/dev/null || true)
  if [ -n "$running_list" ]; then
    running_cnt=$(printf '%s\n' "$running_list" | wc -l | tr -d ' ')
    warn "当前 Docker daemon 下有 ${running_cnt} 个正在运行的容器，重启 dockerd 会中断/重启这些容器："
    printf '%s\n' "$running_list" >&2
  fi
}

reload_and_wait_docker_systemd() {
  if [ "$IS_ROOTLESS" = "1" ]; then
    if ! systemctl --user daemon-reload || ! systemctl --user restart docker; then
      return 1
    fi
  elif [ -n "$SUDO" ]; then
    if ! "$SUDO" systemctl daemon-reload || ! "$SUDO" systemctl restart docker; then
      return 1
    fi
  else
    if ! systemctl daemon-reload || ! systemctl restart docker; then
      return 1
    fi
  fi

  i=0
  while [ "$i" -lt 30 ]; do
    if run_docker info >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

apply_docker_proxy_sync() {
  eff_http="${HTTP_PROXY:-${http_proxy:-${HTTPS_PROXY:-${https_proxy:-}}}}"
  eff_https="${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-}}}}"
  if [ -z "$eff_http" ] && [ -z "$eff_https" ]; then
    warn "当前终端未设置 HTTP_PROXY / HTTPS_PROXY，无法同步代理"
    return 1
  fi
  if ! is_valid_proxy_url "$eff_http" || ! is_valid_proxy_url "$eff_https"; then
    warn "终端代理地址格式不合法（支持 http/https/socks5 且不含空白/引号），已拒绝写入：HTTP=${eff_http} HTTPS=${eff_https}"
    return 1
  fi
  if ! can_manage_docker_systemd; then
    warn "当前环境不支持通过 systemd 自动重启 Docker daemon（非 systemd 或无 root/免密 sudo），请按上方提示手工配置。"
    return 1
  fi

  eff_no_proxy=$(build_safe_no_proxy)
  conf_file=$(docker_proxy_dropin_path)
  conf_dir=$(dirname -- "$conf_file")

  info "写入独立代理配置：${conf_file}（不覆盖已有 http-proxy.conf）..."
  if [ "$IS_ROOTLESS" = "1" ]; then
    mkdir -p "$conf_dir" || return 1
    cat > "$conf_file" <<EOF
# 由 scCloud start.sh 生成；清理请运行：sh ./start.sh --clear-proxy
[Service]
Environment="HTTP_PROXY=${eff_http}"
Environment="HTTPS_PROXY=${eff_https}"
Environment="NO_PROXY=${eff_no_proxy}"
EOF
  else
    if [ -n "$SUDO" ]; then
      "$SUDO" mkdir -p "$conf_dir" || return 1
      "$SUDO" tee "$conf_file" >/dev/null <<EOF
# 由 scCloud start.sh 生成；清理请运行：sh ./start.sh --clear-proxy
[Service]
Environment="HTTP_PROXY=${eff_http}"
Environment="HTTPS_PROXY=${eff_https}"
Environment="NO_PROXY=${eff_no_proxy}"
EOF
    else
      mkdir -p "$conf_dir" || return 1
      cat > "$conf_file" <<EOF
# 由 scCloud start.sh 生成；清理请运行：sh ./start.sh --clear-proxy
[Service]
Environment="HTTP_PROXY=${eff_http}"
Environment="HTTPS_PROXY=${eff_https}"
Environment="NO_PROXY=${eff_no_proxy}"
EOF
    fi
  fi

  info "重载并重启 Docker daemon..."
  if ! reload_and_wait_docker_systemd; then
    warn "Docker daemon 重启后未就绪，请检查 systemctl status docker 与 ${conf_file}"
    return 1
  fi

  PROXY_MISMATCH=0
  ok "已同步代理到 ${conf_file} 并重启 Docker daemon"
  info "若使用的是临时代理端口，事后可运行 sh ./start.sh --clear-proxy 一键清理并恢复直连"
  return 0
}

clear_docker_proxy_sync() {
  detect_docker_access
  conf_file=$(docker_proxy_dropin_path)
  if [ ! -f "$conf_file" ]; then
    info "未找到 ${conf_file}，无需清理"
    exit 0
  fi
  if ! can_manage_docker_systemd; then
    die "当前环境不支持自动重启 Docker daemon，请手动删除 ${conf_file} 并重启 docker"
  fi
  warn_running_containers_before_restart
  if [ "$IS_ROOTLESS" = "1" ] || [ -z "$SUDO" ]; then
    rm -f "$conf_file" || die "删除 ${conf_file} 失败"
  else
    "$SUDO" rm -f "$conf_file" || die "删除 ${conf_file} 失败"
  fi
  info "已删除 ${conf_file}，正在重载并重启 Docker daemon..."
  reload_and_wait_docker_systemd || die "Docker daemon 重启后未就绪，请检查服务状态"
  ok "已清理 scCloud 代理配置并恢复 Docker daemon 直连"
  exit 0
}

ensure_docker_installed() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return 0
  fi

  if [ "$DO_DOCTOR" = "1" ]; then
    warn "未检测到 Docker 或 Docker Compose v2"
    return 1
  fi

  if [ "$INSTALL_DOCKER" != "1" ]; then
    warn "未检测到 Docker Compose v2。"
    print_rootless_docker_guide
    die "请先安装 Docker（独享主机也可加 --install-docker 自动安装：https://docs.docker.com/get-docker/）"
  fi

  os_id="unknown"
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-unknown}"
  fi

  if [ "$(id -u)" != "0" ]; then
    if command -v sudo >/dev/null 2>&1; then
      SUDO=sudo
    else
      die "Docker 未安装且无 root/sudo。共享服务器请参考 README 安装 Rootless Docker 或联系管理员。"
    fi
  else
    SUDO=""
  fi

  warn "未检测到 Docker，尝试自动安装（发行版：$os_id）..."
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh || die "下载 get.docker.com 失败"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO /tmp/get-docker.sh https://get.docker.com || die "下载 get.docker.com 失败"
  else
    die "需要 curl 或 wget 才能自动安装 Docker"
  fi

  sh /tmp/get-docker.sh || die "Docker 安装失败"
  rm -f /tmp/get-docker.sh

  if command -v systemctl >/dev/null 2>&1; then
    if [ -n "$SUDO" ]; then
      "$SUDO" systemctl enable docker 2>/dev/null || true
      "$SUDO" systemctl start docker 2>/dev/null || true
    else
      systemctl enable docker 2>/dev/null || true
      systemctl start docker 2>/dev/null || true
    fi
  fi

  if [ "$(id -u)" != "0" ] && [ -n "$SUDO" ]; then
    "$SUDO" usermod -aG docker "$(whoami)" 2>/dev/null || true
    info "已加入 docker 组，重新登录后可不加 sudo"
  fi

  i=0
  while [ "$i" -lt 30 ]; do
    if run_docker info >/dev/null 2>&1; then
      ok "Docker 安装完成"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  die "Docker 已装但 daemon 未就绪"
}

detect_docker_access() {
  DOCKER_READY=0
  ROOTLESS_UNIT_STOPPED=0
  IS_PODMAN=0
  IS_ROOTLESS=0

  if ! ensure_docker_installed; then
    return 1
  fi

  if run_docker --version 2>/dev/null | grep -qi 'podman'; then
    IS_PODMAN=1
    if [ "$(id -u)" != "0" ] && [ -z "${XDG_RUNTIME_DIR:-}" ]; then
      _uid=$(id -u)
      if [ -d "/run/user/${_uid}" ]; then
        XDG_RUNTIME_DIR="/run/user/${_uid}"
        export XDG_RUNTIME_DIR
      fi
    fi
  fi

  if run_docker info >/dev/null 2>&1; then
    DOCKER_READY=1
  elif [ "$(id -u)" != "0" ]; then
    uid=$(id -u)
    rt_dir="${XDG_RUNTIME_DIR:-/run/user/${uid}}"
    rootless_sock="${rt_dir}/docker.sock"
    if [ -S "$rootless_sock" ] && DOCKER_HOST="unix://${rootless_sock}" docker info >/dev/null 2>&1; then
      DOCKER_HOST="unix://${rootless_sock}"
      export DOCKER_HOST
      DOCKER_READY=1
      ok "自动检测到 rootless Docker socket：$DOCKER_HOST"
      info "建议固定上下文：docker context use rootless（或写入 ~/.bashrc）"
    else
      if [ -f "${HOME:-}/.config/systemd/user/docker.service" ]; then
        ROOTLESS_UNIT_STOPPED=1
      fi
      if command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
        SUDO="sudo"
        DOCKER_READY=1
      fi
    fi
  fi

  if [ "$DOCKER_READY" != "1" ]; then
    if [ "$ROOTLESS_UNIT_STOPPED" = "1" ]; then
      warn "检测到本账号已配置 rootless Docker，但服务未运行。请先执行："
      warn "  systemctl --user enable --now docker && docker context use rootless"
    else
      warn "当前用户无法访问 Docker daemon。"
      print_rootless_docker_guide
    fi
    if [ "$DO_DOCTOR" = "1" ]; then
      return 1
    fi
    die "无法连接 Docker daemon，已中止启动"
  fi

  IS_ROOTLESS=0
  if [ "$IS_PODMAN" = "1" ]; then
    if [ "$(run_docker info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)" = "true" ]; then
      IS_ROOTLESS=1
    fi
    DOCKER_ROOT_DIR=$(run_docker info --format '{{.Store.GraphRoot}}' 2>/dev/null || true)
    if [ "$IS_ROOTLESS" = "1" ] && command -v loginctl >/dev/null 2>&1; then
      if loginctl show-user "$(whoami)" -p Linger 2>/dev/null | grep -q 'Linger=no'; then
        warn "检测到 Rootless Podman 且未开启 systemd linger：退出 SSH 后健康检查定时器可能停止，建议管理员执行 sudo loginctl enable-linger $(whoami)"
      fi
    fi
  else
    if run_docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -qi 'rootless'; then
      IS_ROOTLESS=1
    fi
    DOCKER_ROOT_DIR=$(run_docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
  fi
  return 0
}

setup_compose_mode() {
  effective_rootless="${CALLER_ROOTLESS:-${SCCLOUD_ROOTLESS:-${SCLOUD_ROOTLESS:-auto}}}"
  USE_ROOTLESS_OVERLAY=0
  if [ -n "${COMPOSE_FILE:-}" ]; then
    USE_ROOTLESS_OVERLAY=0
  elif [ "$effective_rootless" = "0" ] || [ "$effective_rootless" = "false" ]; then
    USE_ROOTLESS_OVERLAY=0
  elif [ -f docker-compose.rootless.yml ]; then
    if [ "$effective_rootless" = "1" ] || [ "$effective_rootless" = "true" ] || [ "$IS_ROOTLESS" = "1" ]; then
      USE_ROOTLESS_OVERLAY=1
    fi
  fi

  prefix="docker compose --env-file .env"
  [ -n "$SUDO" ] && prefix="${SUDO} ${prefix}"
  if [ "$USE_ROOTLESS_OVERLAY" = "1" ]; then
    COMPOSE_DISPLAY="${prefix} -f docker-compose.yml -f docker-compose.rootless.yml"
  else
    COMPOSE_DISPLAY="$prefix"
  fi
}

safe_set_env_key() {
  key=$1
  val=$2
  [ -f .env ] || return 0
  (
    umask 077
    if grep -q "^${key}=" .env 2>/dev/null; then
      ENV_KEY="$key" ENV_VAL="$val" awk '
        index($0, ENVIRON["ENV_KEY"] "=") == 1 { print ENVIRON["ENV_KEY"] "=" ENVIRON["ENV_VAL"]; next }
        { print }
      ' .env > .env.tmp
    else
      cat .env > .env.tmp
      printf '%s=%s\n' "$key" "$val" >> .env.tmp
    fi
    chmod 600 .env.tmp 2>/dev/null || true
    mv .env.tmp .env
  )
}

migrate_legacy_ghcr_env() {
  [ -f .env ] || return 0
  if grep -qE '^(FRONTEND_IMAGE|BACKEND_IMAGE|R_ENGINE_IMAGE)=ghcr\.io/zyzhou-saffron/sccloud-' .env 2>/dev/null; then
    if [ "$DO_DOCTOR" = "1" ]; then
      warn ".env 中存在已失效的旧镜像地址 ghcr.io/zyzhou-saffron/sccloud-*（运行 sh ./start.sh 将自动迁移为 ghcr.io/cangiolo/sccloud-*）"
      return 1
    fi
    (
      umask 077
      sed \
        -e 's|^FRONTEND_IMAGE=ghcr\.io/zyzhou-saffron/sccloud-|FRONTEND_IMAGE=ghcr.io/cangiolo/sccloud-|' \
        -e 's|^BACKEND_IMAGE=ghcr\.io/zyzhou-saffron/sccloud-|BACKEND_IMAGE=ghcr.io/cangiolo/sccloud-|' \
        -e 's|^R_ENGINE_IMAGE=ghcr\.io/zyzhou-saffron/sccloud-|R_ENGINE_IMAGE=ghcr.io/cangiolo/sccloud-|' \
        .env > .env.tmp
      chmod 600 .env.tmp 2>/dev/null || true
      mv .env.tmp .env
    )
    warn "检测到 .env 中存在旧镜像地址 ghcr.io/zyzhou-saffron/sccloud-*，已自动迁移为 ghcr.io/cangiolo/sccloud-*（权限保持 600）"
  fi
  return 0
}

check_arch() {
  arch=$(uname -m 2>/dev/null || echo unknown)
  case "$arch" in
    x86_64|amd64)
      ok "系统架构：${arch}"
      ;;
    *)
      warn "检测到非 amd64 架构（${arch}）：当前 frontend 与 r-engine 预构建镜像仅支持 linux/amd64，可能无法正常运行"
      ;;
  esac
}

check_dir_space() {
  dir=$1
  label=$2
  avail_kb=0
  if command -v df >/dev/null 2>&1; then
    avail_kb=$(df -Pk "$dir" 2>/dev/null | awk 'NR==2{print $4}') || avail_kb=0
  fi
  case "$avail_kb" in
    ''|*[!0-9]*) avail_kb=0 ;;
  esac
  if [ "$avail_kb" -gt 0 ]; then
    avail_gb=$((avail_kb / 1024 / 1024))
    if [ "$avail_gb" -lt 20 ]; then
      warn "${label}（${dir}）可用空间约 ${avail_gb}GB（建议 ≥20GB；全部镜像解压约 8GB，另需拉取缓冲与项目数据）"
    else
      ok "${label}可用空间：${avail_gb}GB（${dir}）"
    fi
  fi
}

resolve_projects_data_dir() {
  raw="${PROJECTS_DATA_DIR:-./data/projects}"
  case "$raw" in
    /*) printf '%s' "$raw" ;;
    ./*) printf '%s/%s' "$PROJECT_DIR" "${raw#./}" ;;
    *) printf '%s/%s' "$PROJECT_DIR" "$raw" ;;
  esac
}

ensure_projects_data_dir() {
  target=$(resolve_projects_data_dir)
  mkdir -p \
    "$target" \
    "$target/users" \
    "$target/_tmp" \
    "$target/_tmp/exports" \
    "$target/_tmp/chunks" \
    "$target/_tmp/inspect" 2>/dev/null || true
  chmod 0777 \
    "$target" \
    "$target/users" \
    "$target/_tmp" \
    "$target/_tmp/exports" \
    "$target/_tmp/chunks" \
    "$target/_tmp/inspect" 2>/dev/null || true
}

projects_data_dir_has_data() {
  dir=$1
  [ -d "$dir" ] || return 1
  for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    base=$(basename "$entry")
    case "$base" in
      users|_tmp) continue ;;
      *) return 0 ;;
    esac
  done
  if [ -d "$dir/users" ]; then
    for entry in "$dir/users"/* "$dir/users"/.[!.]* "$dir/users"/..?*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      return 0
    done
  fi
  return 1
}

pick_volume_helper_image() {
  for cand in \
    "${BACKEND_IMAGE:-$DEFAULT_BACKEND_IMAGE}" \
    "$DEFAULT_BACKEND_IMAGE" \
    "${REDIS_IMAGE:-$DEFAULT_REDIS_IMAGE}" \
    "${NGINX_IMAGE:-$DEFAULT_NGINX_IMAGE}" \
    "alpine:latest" \
    "busybox:latest"
  do
    [ -n "$cand" ] || continue
    if run_docker image inspect "$cand" >/dev/null 2>&1; then
      printf '%s' "$cand"
      return 0
    fi
  done
  return 1
}

legacy_projects_volume_has_data() {
  run_docker volume inspect sccloud_projects_data >/dev/null 2>&1 || return 1
  helper_img=$(pick_volume_helper_image) || return 0
  # shellcheck disable=SC2016
  run_docker run --rm -v "sccloud_projects_data:/src:ro" --entrypoint /bin/sh "$helper_img" \
    -c 'for e in /src/* /src/.[!.]* /src/..?*; do if [ -e "$e" ] || [ -L "$e" ]; then exit 0; fi; done; exit 1' \
    >/dev/null 2>&1
}

check_legacy_projects_volume_migration() {
  [ "${SCCLOUD_SKIP_VOLUME_MIGRATION_CHECK:-0}" = "1" ] && return 0
  target=$(resolve_projects_data_dir)
  if projects_data_dir_has_data "$target"; then
    return 0
  fi
  if ! legacy_projects_volume_has_data; then
    return 0
  fi

  warn "检测到旧版 Docker 命名卷 sccloud_projects_data 存有项目数据，而当前目标目录 ${target} 尚无项目数据。"
  warn "新版一键部署默认将项目数据直接落盘在 ${PROJECTS_DATA_DIR:-./data/projects}（不再使用命名卷 projects_data）。"
  if { [ -t 0 ] && [ -t 2 ]; } || [ "${SCCLOUD_ASSUME_TTY:-0}" = "1" ]; then
    printf '是否现在将旧卷 sccloud_projects_data 无损复制到 %s？（旧卷保留作备份） [y/N] ' "$target" >&2
    ans=""
    IFS= read -r ans || ans=""
    case "$ans" in
      y|Y|yes|YES)
        PROJECTS_DATA_DIR="${PROJECTS_DATA_DIR:-./data/projects}" sh ./scripts/sccloud-ops.sh migrate-projects-dir \
          || die "旧卷迁移失败，请手动排查后重试"
        ok "旧卷数据已复制到 ${target}，继续启动服务"
        return 0
        ;;
      *)
        die "已中止启动（避免以空目录掩盖旧卷数据）。请先执行 sh ./scripts/sccloud-ops.sh migrate-projects-dir 后再运行 sh ./start.sh"
        ;;
    esac
  else
    cat >&2 <<EOF
  为避免已有项目变成 404，已中止启动。请按以下步骤完成无损迁移（旧卷保留作备份）：
    sh ./scripts/sccloud-ops.sh migrate-projects-dir
    sh ./start.sh
  （若确认不需要旧卷数据，可设置 SCCLOUD_SKIP_VOLUME_MIGRATION_CHECK=1 后重试）
EOF
    die "检测到未迁移的旧项目数据卷 sccloud_projects_data"
  fi
}

check_disk_space() {
  check_dir_space "." "项目目录"
  proj_fs=""
  if command -v df >/dev/null 2>&1; then
    proj_fs=$(df -Pk . 2>/dev/null | awk 'NR==2{print $1}') || proj_fs=""
  fi
  data_dir=$(resolve_projects_data_dir)
  if [ -d "$data_dir" ] && command -v df >/dev/null 2>&1; then
    data_fs=$(df -Pk "$data_dir" 2>/dev/null | awk 'NR==2{print $1}') || data_fs=""
    if [ -n "$data_fs" ] && [ "$data_fs" != "$proj_fs" ]; then
      check_dir_space "$data_dir" "项目数据目录"
    fi
  fi
  if [ -n "$DOCKER_ROOT_DIR" ] && [ -d "$DOCKER_ROOT_DIR" ] && command -v df >/dev/null 2>&1; then
    docker_fs=$(df -Pk "$DOCKER_ROOT_DIR" 2>/dev/null | awk 'NR==2{print $1}') || docker_fs=""
    if [ -n "$docker_fs" ] && [ "$docker_fs" != "$proj_fs" ]; then
      check_dir_space "$DOCKER_ROOT_DIR" "Docker 数据目录"
    fi
  fi
}

check_rootless_mounts() {
  [ "$IS_ROOTLESS" = "1" ] || return 0
  bad_mounts=""
  for p in ./nginx/nginx.bridge.conf ./r-engine/plumber.R ./r-engine/worker.R ./r-engine/run_job.R ./r-engine/R ./r-engine/data; do
    [ -e "$p" ] || continue
    # shellcheck disable=SC2012
    perm=$(ls -ld "$p" 2>/dev/null | awk '{print $1}')
    case "$perm" in
      d??????r?x*|d??????r?s*|d??????r?t*) ;;
      -??????r??*) ;;
      "") ;;
      *) bad_mounts="${bad_mounts} ${p}" ;;
    esac
  done
  if [ -n "$bad_mounts" ]; then
    warn "Rootless 模式下以下挂载路径缺少 other 读/遍历权限（可能由 umask 077 引起），容器内非 root 进程可能无法读取：${bad_mounts}"
    warn "建议修复：chmod -R a+rX nginx r-engine"
  fi
}

check_docker_proxy() {
  [ "$DOCKER_READY" = "1" ] || return 0
  shell_proxy="${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-}}}}"
  if [ "$IS_PODMAN" = "1" ]; then
    PROXY_MISMATCH=0
    SHELL_PROXY_DISPLAY="$shell_proxy"
    if [ "$DO_DOCTOR" = "1" ]; then
      info "代理状态：Shell=${shell_proxy:-未设置} | Podman 直接继承当前终端代理（容器内已配置 NO_PROXY 绕过本地与内网探活）"
    fi
    return 0
  fi
  daemon_proxies=$(run_docker info --format '{{.HTTPProxy}}|{{.HTTPSProxy}}' 2>/dev/null || true)
  daemon_http=${daemon_proxies%%|*}
  daemon_https=${daemon_proxies#*|}
  [ "$daemon_http" = "<no value>" ] && daemon_http=""
  [ "$daemon_https" = "<no value>" ] && daemon_https=""
  daemon_mirrors=$(run_docker info --format '{{.RegistryConfig.Mirrors}}' 2>/dev/null || true)
  case "$daemon_mirrors" in
    ""|"[]"|"map[]"|"<no value>") daemon_mirrors="" ;;
  esac

  if [ "$DO_DOCTOR" = "1" ]; then
    info "代理状态：Shell=${shell_proxy:-未设置} | dockerd HTTP=${daemon_http:-未设置} HTTPS=${daemon_https:-未设置} | Mirrors=${daemon_mirrors:-未配置}"
  fi

  PROXY_MISMATCH=0
  SHELL_PROXY_DISPLAY="$shell_proxy"

  if [ -n "$shell_proxy" ] && [ -z "$daemon_http" ] && [ -z "$daemon_https" ]; then
    PROXY_MISMATCH=1
    warn "检测到终端已设置代理（${shell_proxy}），但 Docker daemon 未配置代理！"
    warn "Docker 拉取镜像不会自动继承终端的 http_proxy/https_proxy；若直连外网受限，拉取将超时。"
    print_proxy_hint
  fi
}

check_port_available() {
  port=$1
  if command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | awk -v p="$port" '
      NR > 1 {
        addr = $4
        sub(/^.*:/, "", addr)
        if (addr == p) { found = 1; exit 0 }
      }
      END { exit(found ? 0 : 1) }
    ' && return 1
    return 0
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | awk -v p="$port" '
      NR > 2 {
        addr = $4
        sub(/^.*:/, "", addr)
        if (addr == p) { found = 1; exit 0 }
      }
      END { exit(found ? 0 : 1) }
    ' && return 1
    return 0
  fi
  # macOS 兜底
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && return 1
  fi
  return 0
}

is_own_web_port() {
  port=$1
  [ "$DOCKER_READY" = "1" ] || return 1
  mapped=$(run_compose port web 8080 2>/dev/null || true)
  [ -n "$mapped" ] || return 1
  printf '%s\n' "$mapped" | awk -v p="$port" '
    {
      sub(/^.*:/, "")
      if ($0 == p) { found = 1; exit 0 }
    }
    END { exit(found ? 0 : 1) }
  '
}

find_available_port() {
  base_port=$1
  p=$base_port
  end=$((base_port + 9))
  while [ "$p" -le "$end" ]; do
    if check_port_available "$p"; then
      echo "$p"
      return 0
    fi
    p=$((p + 1))
  done
  echo ""
  return 1
}

# GHCR / Docker Hub /v2/ 返回 200/401/403 即表示网络可达
check_registry_reachable() {
  url="${1:-https://ghcr.io/v2/}"
  code="000"
  if command -v curl >/dev/null 2>&1; then
    code=$(curl -sS --max-time 6 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null) || code="000"
  elif command -v wget >/dev/null 2>&1; then
    code=$(wget --timeout=6 --server-response -qO /dev/null "$url" 2>&1 \
      | grep -oE 'HTTP/[0-9.]+ [0-9]+' | tail -1 | grep -oE '[0-9]+$') || code="000"
  fi
  case "$code" in
    200|401|403) return 0 ;;
    *) return 1 ;;
  esac
}

image_exists_locally() {
  ref=$1
  run_docker image inspect "$ref" >/dev/null 2>&1
}

get_r_engine_image() {
  printf '%s' "${R_ENGINE_IMAGE:-$DEFAULT_R_ENGINE_IMAGE}"
}

has_r_library() {
  [ -d ./r-engine/r-library ] && [ -n "$(ls -A ./r-engine/r-library 2>/dev/null)" ]
}

ensure_r_engine_image() {
  R_IMG=$(get_r_engine_image)

  if image_exists_locally "$R_IMG"; then
    ok "本地已有 R 镜像：$R_IMG"
    return 0
  fi

  # 尝试常见本地 tag（含旧命名空间残留本地镜像）
  for cand in sccloud-r-engine:latest sccloud-r-engine ghcr.io/zyzhou-saffron/sccloud-r-engine:latest; do
    if [ "$cand" != "$R_IMG" ] && image_exists_locally "$cand"; then
      info "发现本地镜像 $cand，retag → $R_IMG"
      run_docker tag "$cand" "$R_IMG" || true
      if image_exists_locally "$R_IMG"; then
        return 0
      fi
    fi
  done

  if [ -f ./data/sccloud-r-engine-image.tar.gz ]; then
    info "从 data/sccloud-r-engine-image.tar.gz 加载 R 镜像..."
    if gunzip -c ./data/sccloud-r-engine-image.tar.gz | run_docker load; then
      loaded=$(run_docker images --format '{{.Repository}}:{{.Tag}}' | grep -i 'r-engine\|sccloud-r' | head -1) || loaded=""
      if [ -n "$loaded" ] && [ "$loaded" != "$R_IMG" ]; then
        run_docker tag "$loaded" "$R_IMG" 2>/dev/null || true
      fi
      ok "R 镜像离线 load 完成"
      return 0
    fi
    warn "data/sccloud-r-engine-image.tar.gz 加载失败"
  fi

  return 1
}

images_ready() {
  missing=0
  for img in \
    "${FRONTEND_IMAGE:-$DEFAULT_FRONTEND_IMAGE}" \
    "${BACKEND_IMAGE:-$DEFAULT_BACKEND_IMAGE}" \
    "${R_ENGINE_IMAGE:-$DEFAULT_R_ENGINE_IMAGE}" \
    "${NGINX_IMAGE:-$DEFAULT_NGINX_IMAGE}" \
    "${MARIADB_IMAGE:-$DEFAULT_MARIADB_IMAGE}" \
    "${REDIS_IMAGE:-$DEFAULT_REDIS_IMAGE}"
  do
    if ! image_exists_locally "$img"; then
      warn "缺少本地镜像：$img"
      missing=1
    fi
  done
  [ "$missing" = "0" ]
}

is_network_pull_error() {
  log_file=$1
  [ -n "$log_file" ] && [ -s "$log_file" ] || return 1
  grep -qiE 'i/o timeout|deadline exceeded|connection refused|tls handshake|unexpected eof|no such host|temporary failure in name resolution|dial tcp' "$log_file"
}

run_pull_once() {
  pull_ok=0
  [ -n "$PULL_LOG_FILE" ] && rm -f "$PULL_LOG_FILE" 2>/dev/null || true
  [ -n "$PULL_RC_FILE" ] && rm -f "$PULL_RC_FILE" 2>/dev/null || true
  PULL_LOG_FILE=$(mktemp "${TMPDIR:-/tmp}/sccloud-pull.XXXXXX")
  PULL_RC_FILE=$(mktemp "${TMPDIR:-/tmp}/sccloud-pull-rc.XXXXXX")
  pull_log="$PULL_LOG_FILE"
  info "拉取预构建镜像（${COMPOSE_DISPLAY} pull）..."
  (
    run_compose pull 2>&1
    echo $? > "$PULL_RC_FILE"
  ) | tee "$PULL_LOG_FILE"
  pull_rc=$(cat "$PULL_RC_FILE" 2>/dev/null || echo 1)
  if [ "$pull_rc" = "0" ]; then
    pull_ok=1
  else
    warn "镜像拉取未全部成功（退出码 ${pull_rc}），检查本地镜像与离线兜底..."
  fi
}

offer_interactive_proxy_sync() {
  [ "$PROXY_MISMATCH" = "1" ] || return 1
  is_network_pull_error "$pull_log" || return 1
  can_manage_docker_systemd || return 1

  if { [ -t 0 ] && [ -t 2 ]; } || [ "${SCCLOUD_ASSUME_TTY:-0}" = "1" ]; then
    echo "" >&2
    warn "拉取因网络/超时失败，且终端代理（${SHELL_PROXY_DISPLAY}）尚未同步到 Docker daemon。"
    warn_running_containers_before_restart
    printf '是否自动将终端代理 (%s) 写入 Docker daemon（独立文件 sccloud-proxy.conf）并重启后自动重试拉取？[y/N] ' "$SHELL_PROXY_DISPLAY" >&2
    IFS= read -r ans || ans=""
    case "$ans" in
      y|Y|yes|YES)
        apply_docker_proxy_sync
        return $?
        ;;
      *)
        info "已跳过自动写入代理。"
        return 1
        ;;
    esac
  fi

  info "当前为非交互终端，未自动重启 dockerd；可直接运行 sh ./start.sh --sync-proxy 自动写入并重启后拉取。"
  return 1
}

diagnose_pull_failure() {
  log_file=$1
  echo "" >&2
  warn "========== 镜像拉取失败诊断 =========="

  if [ -n "$log_file" ] && [ -s "$log_file" ]; then
    if grep -qiE 'i/o timeout|deadline exceeded|connection refused|tls handshake|unexpected eof|no such host|temporary failure in name resolution|dial tcp' "$log_file"; then
      warn "原因判断：Docker daemon 访问镜像仓库超时或网络不可达（GHCR 或 Docker Hub）。"
      print_proxy_hint
      cat >&2 <<'EOF'

  [备选：国内/内网镜像源]
  可在 .env 中将以下变量指向镜像源后重试 sh ./start.sh：
    FRONTEND_IMAGE / BACKEND_IMAGE / R_ENGINE_IMAGE
    NGINX_IMAGE / MARIADB_IMAGE / REDIS_IMAGE
EOF
    fi

    if grep -qiE 'denied|unauthorized|manifest unknown|pull access denied|requested access to the resource is denied' "$log_file"; then
      warn "原因判断：镜像仓库拒绝访问或 tag 不存在（denied / manifest unknown）。"
      warn "  1) 检查 .env 中 FRONTEND_IMAGE / BACKEND_IMAGE / R_ENGINE_IMAGE 是否仍为旧命名空间（当前默认应为 ghcr.io/cangiolo/sccloud-*）。"
      warn "  2) 若使用了私有镜像源，请先执行 docker login 后重试。"
    fi

    if grep -qiE 'no space left on device' "$log_file"; then
      warn "原因判断：磁盘空间不足（no space left on device）。"
      [ -n "$DOCKER_ROOT_DIR" ] && warn "  Docker 数据目录：${DOCKER_ROOT_DIR}（请清理旧镜像 docker system prune 或迁移 data-root）。"
    fi
  fi

  R_IMG=$(get_r_engine_image)
  if ! image_exists_locally "$R_IMG"; then
    cat >&2 <<EOF

  [关于 R 引擎镜像（无需 r-engine/r-library 目录）]
  普通用户克隆仓库不含 r-engine/r-library/，不需要也不应从源码构建 R 镜像。
  可任选其一补齐 R 镜像：
    1) 配置好 Docker 代理/网络后直接运行：sh ./start.sh
    2) 离线包兜底：下载 Release 里的 sccloud-r-engine-image.tar.gz 放到 ./data/ 后重试：
       ${RELEASE_R_TAR_URL}
EOF
  fi

  warn "可运行 sh ./start.sh --doctor 查看完整环境体检报告。"
  warn "======================================"
}

svc_health() {
  svc=$1
  run_compose ps --format '{{.Health}}' "$svc" 2>/dev/null | head -1
}

svc_status() {
  svc=$1
  run_compose ps --format '{{.Status}}' "$svc" 2>/dev/null | head -1
}

diagnose_failure() {
  echo ""
  warn "========== 自动诊断 =========="
  info "[1/3] 容器状态："
  run_compose ps 2>/dev/null || true
  echo ""
  info "[2/3] 异常服务日志（各 ~40 行）："
  printed_any=0
  for svc in db redis backend r-engine r-engine-worker frontend web; do
    st=$(svc_status "$svc") || st=""
    hl=$(svc_health "$svc") || hl=""
    if echo "$st" | grep -qiE 'exited|failed|unhealthy|restarting' \
      || echo "$hl" | grep -qiE 'unhealthy|starting'; then
      printed_any=1
      st_label="${st:-unknown}"
      [ -n "$hl" ] && st_label="${st_label}, health=${hl}"
      echo "    --- $svc ($st_label) ---"
      if echo "$hl" | grep -qiE 'unhealthy|starting'; then
        cid=$(run_compose ps -q "$svc" 2>/dev/null | head -1) || cid=""
        if [ -n "$cid" ]; then
          hlog=$(run_docker inspect --format '{{range .State.Health.Log}}[exit={{.ExitCode}}] {{.Output}} {{end}}' "$cid" 2>/dev/null | tr '\r\n' '  ' | cut -c1-1000) || hlog=""
          [ -n "$hlog" ] && echo "    [healthcheck] $hlog"
        fi
      fi
      run_compose logs --tail 40 "$svc" 2>/dev/null | sed 's/^/    /'
      echo ""
    fi
  done
  if [ "$printed_any" = "0" ]; then
    for svc in backend web; do
      cid=$(run_compose ps -q "$svc" 2>/dev/null | head -1) || cid=""
      if [ -n "$cid" ]; then
        st=$(svc_status "$svc") || st=""
        hl=$(svc_health "$svc") || hl=""
        echo "    --- $svc (${st:-unknown}${hl:+, health=$hl}) ---"
        run_compose logs --tail 30 "$svc" 2>/dev/null | sed 's/^/    /'
        echo ""
      fi
    done
  fi
  info "[3/3] 磁盘："
  df -h . 2>/dev/null | sed 's/^/    /' || true
  if [ -n "$DOCKER_ROOT_DIR" ] && [ -d "$DOCKER_ROOT_DIR" ]; then
    df -h "$DOCKER_ROOT_DIR" 2>/dev/null | sed 's/^/    /' || true
  fi
  echo ""
  info "完整日志：${COMPOSE_DISPLAY} logs --tail 200"
  info "环境体检：sh ./start.sh --doctor"
  info "重置（会清空数据库与项目文件）：${COMPOSE_DISPLAY} down -v && rm -f .env && rm -f secrets/* && sh ./start.sh"
  warn "=============================="
}

print_access_info() {
  admin_user="${BOOTSTRAP_ADMIN_USER:-admin}"
  admin_pass="${BOOTSTRAP_ADMIN_PASSWORD:-admin123}"
  if [ -f ./secrets/bootstrap-admin-password ]; then
    admin_pass=$(tr -d '\r\n' < ./secrets/bootstrap-admin-password)
  fi
  if [ "$WEB_BIND" = "0.0.0.0" ]; then
    lan_ip=""
    if command -v ip >/dev/null 2>&1; then
      lan_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}') || true
    fi
    if [ -z "$lan_ip" ] && command -v hostname >/dev/null 2>&1; then
      lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
    fi
    echo "访问地址："
    echo "  本机：    http://localhost:${WEB_PORT}"
    [ -n "$lan_ip" ] && echo "  局域网：  http://${lan_ip}:${WEB_PORT}"
  else
    echo "访问地址：http://${WEB_BIND}:${WEB_PORT}"
    echo "  （若从本机浏览器访问远端服务器，可建立 SSH 隧道：ssh -L ${WEB_PORT}:${WEB_BIND}:${WEB_PORT} <user>@<host>）"
  fi
  health_host="127.0.0.1"
  [ "$WEB_BIND" != "0.0.0.0" ] && health_host="$WEB_BIND"
  echo ""
  echo "健康检查：http://${health_host}:${WEB_PORT}/healthz"
  echo "项目数据目录：$(resolve_projects_data_dir)"
  echo ""
  echo "默认管理员（仅空库首次启动创建）："
  echo "  用户：${admin_user}"
  echo "  密码：${admin_pass}"
  echo "  请登录后立即修改密码。"
  echo ""
  echo "常用命令："
  echo "  sh ./scripts/sccloud-ops.sh status"
  echo "  sh ./scripts/sccloud-ops.sh logs"
  echo "  sh ./scripts/sccloud-ops.sh stop"
  if [ "$WEB_BIND" = "0.0.0.0" ]; then
    echo ""
    warn "当前绑定 0.0.0.0:${WEB_PORT}。公网暴露前请加反向代理与 TLS，或改为 WEB_BIND_ADDRESS=127.0.0.1。"
  fi
}

wait_health() {
  svc=$1
  label=$2
  max_i=${3:-60}
  printf '  %s' "$label"
  stage_start=$(now_s)
  ok_flag=0
  i=0
  while [ "$i" -lt "$max_i" ]; do
    h=$(svc_health "$svc") || h=""
    if [ "$h" = "healthy" ]; then
      ok_flag=1
      break
    fi
    st=$(svc_status "$svc") || st=""
    if echo "$st" | grep -qiE 'exited|failed'; then
      break
    fi
    printf '.'
    sleep 2
    i=$((i + 1))
  done
  stage_end=$(now_s)
  if [ "$ok_flag" = "1" ]; then
    printf ' ✓ (%s)\n' "$(elapsed_str "$stage_start" "$stage_end")"
    return 0
  fi
  printf ' ✗\n'
  return 1
}

run_doctor() {
  info "========== scCloud 环境体检（只读）=========="
  check_arch

  if detect_docker_access; then
    docker_ver=$(run_docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
    compose_ver=$(run_docker compose version --short 2>/dev/null || run_docker compose version 2>/dev/null || echo "unknown")
    mode_label="rootful"
    [ "$IS_ROOTLESS" = "1" ] && mode_label="rootless"
    if [ "$IS_PODMAN" = "1" ]; then
      ok "Docker(Podman 兼容) 就绪：Server ${docker_ver} | Compose ${compose_ver} | 模式=${mode_label} | RootDir=${DOCKER_ROOT_DIR:-unknown}"
    else
      ok "Docker 就绪：Server ${docker_ver} | Compose ${compose_ver} | 模式=${mode_label} | RootDir=${DOCKER_ROOT_DIR:-unknown}"
    fi
  fi

  if [ -f .env ]; then
    # shellcheck disable=SC2012
    env_perm=$(ls -l .env 2>/dev/null | awk '{print $1}')
    case "$env_perm" in
      -rw-------*) ok ".env 存在且权限安全（600）" ;;
      *) warn ".env 权限偏宽（${env_perm}），建议 chmod 600 .env" ;;
    esac
    migrate_legacy_ghcr_env || true
    set -a
    # shellcheck disable=SC1091
    . ./.env 2>/dev/null || true
    set +a
  else
    info ".env 尚未创建（首次运行 sh ./start.sh 时会自动生成）"
  fi

  [ -n "$CALLER_COMPOSE_FILE" ] && COMPOSE_FILE="$CALLER_COMPOSE_FILE"
  [ -n "$CALLER_WEB_PORT" ] && WEB_PORT="$CALLER_WEB_PORT"
  [ -n "$CALLER_WEB_BIND" ] && WEB_BIND_ADDRESS="$CALLER_WEB_BIND"
  [ -n "$CALLER_PROJECTS_DATA_DIR" ] && PROJECTS_DATA_DIR="$CALLER_PROJECTS_DATA_DIR"
  WEB_PORT="${WEB_PORT:-8080}"
  WEB_BIND="${WEB_BIND_ADDRESS:-0.0.0.0}"
  PROJECTS_DATA_DIR="${PROJECTS_DATA_DIR:-./data/projects}"

  setup_compose_mode
  info "项目数据目录：$(resolve_projects_data_dir)"
  check_disk_space
  check_rootless_mounts
  if [ "$DOCKER_READY" = "1" ] && ! projects_data_dir_has_data "$(resolve_projects_data_dir)"; then
    if run_docker volume inspect sccloud_projects_data >/dev/null 2>&1; then
      warn "检测到旧命名卷 sccloud_projects_data；若其中有历史项目，升级启动前请先执行 sh ./scripts/sccloud-ops.sh migrate-projects-dir"
    fi
  fi
  check_docker_proxy

  info "检测仓库连通性（当前终端网络视角；实际拉取取决于 Docker daemon 代理）："
  if check_registry_reachable "https://ghcr.io/v2/"; then
    ok "GHCR（ghcr.io）可达"
  else
    warn "GHCR（ghcr.io）在当前终端不可达"
  fi
  if check_registry_reachable "https://registry-1.docker.io/v2/"; then
    ok "Docker Hub（registry-1.docker.io）可达"
  else
    warn "Docker Hub（registry-1.docker.io）在当前终端不可达（nginx/mariadb/redis 需要访问 Docker Hub 或配置 mirror）"
  fi

  if check_port_available "$WEB_PORT"; then
    ok "目标端口 ${WEB_BIND}:${WEB_PORT} 可用"
  elif is_own_web_port "$WEB_PORT"; then
    ok "目标端口 ${WEB_PORT} 正由当前 scCloud 服务使用"
  else
    warn "目标端口 ${WEB_PORT} 已被其他进程占用（启动时将自动顺延）"
  fi

  if [ "$DOCKER_READY" = "1" ]; then
    info "本地镜像状态："
    if images_ready; then
      ok "全部 6 个镜像已在本地就绪"
    else
      info "以上缺失镜像将在运行 sh ./start.sh 时通过 docker compose pull 拉取"
    fi
  fi

  info "============================================"
  [ "$DOCKER_READY" = "1" ] && exit 0
  exit 1
}

# ---------- main ----------
if [ "$DO_CLEAR_PROXY" = "1" ]; then
  clear_docker_proxy_sync
fi

if [ "$DO_DOCTOR" = "1" ]; then
  run_doctor
fi

check_arch
detect_docker_access

need_wizard=0
if [ ! -f .env ]; then
  need_wizard=1
fi
for s in db-root-password db-password jwt-secret redis-password bootstrap-admin-password; do
  if [ ! -s "./secrets/$s" ]; then
    need_wizard=1
    break
  fi
done
if [ "$need_wizard" = "1" ]; then
  info "运行初始化向导（.env / secrets）..."
  sh ./scripts/setup-wizard.sh || die "setup-wizard 失败"
fi

migrate_legacy_ghcr_env

set -a
# shellcheck disable=SC1091
. ./.env
set +a

[ -n "$CALLER_COMPOSE_FILE" ] && COMPOSE_FILE="$CALLER_COMPOSE_FILE"
setup_compose_mode

check_disk_space
check_rootless_mounts
check_docker_proxy

if [ "$DO_SYNC_PROXY" = "1" ]; then
  warn_running_containers_before_restart
  apply_docker_proxy_sync || die "自动同步代理到 Docker daemon 失败"
fi

# 每次启动用 secrets 刷新 R 引擎 Redis URL（安全写入，保持 .env 600 权限）
if [ -s ./secrets/redis-password ]; then
  _rp=$(tr -d '\r\n' < ./secrets/redis-password)
  export R_REDIS_URL="redis://:${_rp}@redis:6379/0"
  safe_set_env_key R_REDIS_URL "$R_REDIS_URL"
fi

if [ -n "$CALLER_WEB_PORT" ]; then
  WEB_PORT="$CALLER_WEB_PORT"
  safe_set_env_key WEB_PORT "$WEB_PORT"
fi
if [ -n "$CALLER_WEB_BIND" ]; then
  WEB_BIND_ADDRESS="$CALLER_WEB_BIND"
  safe_set_env_key WEB_BIND_ADDRESS "$WEB_BIND_ADDRESS"
fi

WEB_PORT="${WEB_PORT:-8080}"
WEB_BIND="${WEB_BIND_ADDRESS:-0.0.0.0}"

if ! check_port_available "$WEB_PORT"; then
  if is_own_web_port "$WEB_PORT"; then
    ok "端口 $WEB_PORT 正由当前 scCloud 服务使用，保持不变"
  else
    warn "端口 $WEB_PORT 已被其他进程占用，自动寻找可用端口..."
    new_port=$(find_available_port $((WEB_PORT + 1))) || true
    if [ -n "$new_port" ]; then
      safe_set_env_key WEB_PORT "$new_port"
      WEB_PORT="$new_port"
      ok "WEB_PORT 已更新为 $WEB_PORT（.env 权限保持 600）"
    else
      die "端口 $WEB_PORT ~ $((WEB_PORT + 9)) 均被占用，请改 .env 中 WEB_PORT"
    fi
  fi
fi

# 重新 export 给 compose
set -a
# shellcheck disable=SC1091
. ./.env
set +a
WEB_PORT="${WEB_PORT:-8080}"
WEB_BIND="${WEB_BIND_ADDRESS:-0.0.0.0}"
[ -n "$CALLER_PROJECTS_DATA_DIR" ] && PROJECTS_DATA_DIR="$CALLER_PROJECTS_DATA_DIR"
PROJECTS_DATA_DIR="${PROJECTS_DATA_DIR:-./data/projects}"
export WEB_PORT WEB_BIND_ADDRESS PROJECTS_DATA_DIR
if [ -s ./secrets/redis-password ]; then
  _rp=$(tr -d '\r\n' < ./secrets/redis-password)
  export R_REDIS_URL="redis://:${_rp}@redis:6379/0"
fi

build_ok=0

if [ "$DO_BUILD" = "1" ]; then
  ensure_r_engine_image || true
  R_IMG=$(get_r_engine_image)
  if has_r_library; then
    info "检测到 r-engine/r-library，本地构建全部镜像（R 引擎首次较慢）..."
    if run_compose build; then
      build_ok=1
    else
      die "镜像构建失败"
    fi
  elif image_exists_locally "$R_IMG"; then
    info "未检测到 r-engine/r-library，复用本地 R 镜像（$R_IMG），仅构建 frontend 与 backend..."
    if run_compose build frontend backend; then
      build_ok=1
    else
      die "frontend/backend 镜像构建失败"
    fi
  else
    cat >&2 <<EOF

  普通用户克隆仓库不含 r-engine/r-library/（该目录为维护者预编译 R 包，不进 git），无需从源码构建 R 镜像。
  请选择以下方式获取 R 镜像后再启动：
    1) 直接拉取预构建镜像（推荐）：sh ./start.sh
    2) 离线包加载：下载 ${RELEASE_R_TAR_URL} 到 ./data/sccloud-r-engine-image.tar.gz 后重试
EOF
    die "已拦截 --build：缺少 r-engine/r-library 且本地无可用 R 镜像（$R_IMG）"
  fi
else
  pull_ok=0
  pull_log=""
  if [ "$DO_PULL" = "1" ]; then
    run_pull_once
    if [ "$pull_ok" != "1" ] && offer_interactive_proxy_sync; then
      info "代理同步完成，自动重试镜像拉取..."
      run_pull_once
    fi
  fi

  # R 镜像离线/本地兜底（本地 tag 或 data/sccloud-r-engine-image.tar.gz）
  ensure_r_engine_image || true

  if images_ready; then
    if [ "$DO_PULL" = "1" ] && [ "$pull_ok" != "1" ]; then
      warn "远端拉取未完全成功，但本地已具备全部 6 个镜像，继续使用本地缓存启动"
    else
      ok "全部 6 个镜像已就绪"
    fi
    build_ok=1
  else
    diagnose_pull_failure "$pull_log"
    die "镜像未就绪，已中止启动（未自动回退到 docker compose build）"
  fi
fi

[ "$build_ok" = "1" ] || die "镜像准备失败"

ensure_projects_data_dir
check_legacy_projects_volume_migration

info "启动服务..."
run_compose up -d || {
  diagnose_failure
  die "docker compose up 失败"
}

info "等待服务就绪..."
phase_start=$(now_s)

wait_health db "db..." 45 || { diagnose_failure; die "db 未就绪"; }
wait_health redis "redis..." 30 || { diagnose_failure; die "redis 未就绪"; }
wait_health backend "backend..." 90 || { diagnose_failure; die "backend 未就绪"; }

# r-engine 启动较慢
printf '  r-engine'
re_ok=0
i=0
stage_start=$(now_s)
while [ "$i" -lt 90 ]; do
  h=$(svc_health r-engine) || h=""
  if [ "$h" = "healthy" ]; then
    re_ok=1
    break
  fi
  st=$(svc_status r-engine) || st=""
  if echo "$st" | grep -qiE 'exited|failed'; then
    break
  fi
  printf '.'
  sleep 2
  i=$((i + 1))
done
stage_end=$(now_s)
if [ "$re_ok" = "1" ]; then
  printf ' ✓ (%s)\n' "$(elapsed_str "$stage_start" "$stage_end")"
else
  printf ' ✗（继续检查入口；分析功能可能不可用）\n'
  warn "r-engine 未 healthy，查看：${COMPOSE_DISPLAY} logs --tail 100 r-engine"
fi

printf '  web'
web_ok=0
i=0
stage_start=$(now_s)
health_host="127.0.0.1"
[ "$WEB_BIND" != "0.0.0.0" ] && health_host="$WEB_BIND"
HEALTH_URL="http://${health_host}:${WEB_PORT}/healthz"
while [ "$i" -lt 45 ]; do
  h=$(svc_health web) || h=""
  http_ok=0
  if command -v curl >/dev/null 2>&1; then
    curl --noproxy '*' -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1 && http_ok=1
  elif command -v wget >/dev/null 2>&1; then
    env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY wget -qO- --timeout=3 "$HEALTH_URL" >/dev/null 2>&1 && http_ok=1
  else
    [ "$h" = "healthy" ] && http_ok=1
  fi
  if [ "$http_ok" = "1" ]; then
    web_ok=1
    break
  fi
  st=$(svc_status web) || st=""
  if echo "$st" | grep -qiE 'exited|failed'; then
    break
  fi
  printf '.'
  sleep 2
  i=$((i + 1))
done
stage_end=$(now_s)
total_end=$(now_s)

if [ "$web_ok" = "1" ]; then
  printf ' ✓ (%s)\n' "$(elapsed_str "$stage_start" "$stage_end")"
  echo ""
  ok "服务已就绪（总等待 $(elapsed_str "$phase_start" "$total_end")）"
  echo ""
  print_access_info
  exit 0
fi

printf ' ✗\n'
diagnose_failure
die "入口健康检查超时：$HEALTH_URL"

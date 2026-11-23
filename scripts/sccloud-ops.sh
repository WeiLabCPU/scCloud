#!/bin/sh
# scCloud 运维薄封装（少碰 raw compose）
# 用法: sh ./scripts/sccloud-ops.sh {status|logs|stop|restart|up|pull|ps|promote-admin|migrate-projects-dir}

set -u

PROJECT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$PROJECT_DIR" || exit 1

if [ -n "${HOME:-}" ] && [ -d "${HOME}/bin" ]; then
  case ":${PATH:-}:" in
    *":${HOME}/bin:"*) ;;
    *) PATH="${HOME}/bin:${PATH:-}"; export PATH ;;
  esac
fi

if [ ! -f .env ]; then
  echo "缺少 .env，请先 sh ./start.sh 或 sh ./scripts/setup-wizard.sh" >&2
  exit 1
fi

SUDO=""
IS_ROOTLESS=0
IS_PODMAN=0
if docker --version 2>/dev/null | grep -qi 'podman'; then
  IS_PODMAN=1
  if [ "$(id -u)" != "0" ] && [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    _uid=$(id -u)
    if [ -d "/run/user/${_uid}" ]; then
      XDG_RUNTIME_DIR="/run/user/${_uid}"
      export XDG_RUNTIME_DIR
    fi
  fi
fi

if [ "$(id -u)" != "0" ] && ! docker info >/dev/null 2>&1; then
  uid=$(id -u)
  rootless_sock="${XDG_RUNTIME_DIR:-/run/user/${uid}}/docker.sock"
  if [ -S "$rootless_sock" ] && DOCKER_HOST="unix://${rootless_sock}" docker info >/dev/null 2>&1; then
    DOCKER_HOST="unix://${rootless_sock}"
    export DOCKER_HOST
  elif command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "当前用户无法访问 Docker daemon。请先确认 rootless Docker 已启动（systemctl --user start docker && docker context use rootless）或运行 sh ./start.sh --doctor 排查。" >&2
    exit 1
  fi
fi

run_docker() {
  if [ -n "$SUDO" ]; then
    "$SUDO" docker "$@"
  else
    docker "$@"
  fi
}

if [ "$IS_PODMAN" = "1" ]; then
  if [ "$(run_docker info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)" = "true" ]; then
    IS_ROOTLESS=1
  fi
elif run_docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -qi 'rootless'; then
  IS_ROOTLESS=1
fi

CALLER_COMPOSE_FILE="${COMPOSE_FILE:-}"
CALLER_ROOTLESS="${SCCLOUD_ROOTLESS:-${SCLOUD_ROOTLESS:-}}"
CALLER_PROJECTS_DATA_DIR="${PROJECTS_DATA_DIR:-}"

set -a
# shellcheck disable=SC1091
. ./.env 2>/dev/null || true
set +a

[ -n "$CALLER_COMPOSE_FILE" ] && COMPOSE_FILE="$CALLER_COMPOSE_FILE"
[ -n "$CALLER_PROJECTS_DATA_DIR" ] && PROJECTS_DATA_DIR="$CALLER_PROJECTS_DATA_DIR"
PROJECTS_DATA_DIR="${PROJECTS_DATA_DIR:-./data/projects}"
export PROJECTS_DATA_DIR
EFFECTIVE_ROOTLESS="${CALLER_ROOTLESS:-${SCCLOUD_ROOTLESS:-${SCLOUD_ROOTLESS:-auto}}}"

USE_ROOTLESS_OVERLAY=0
if [ -n "${COMPOSE_FILE:-}" ]; then
  USE_ROOTLESS_OVERLAY=0
elif [ "$EFFECTIVE_ROOTLESS" = "0" ] || [ "$EFFECTIVE_ROOTLESS" = "false" ]; then
  USE_ROOTLESS_OVERLAY=0
elif [ -f docker-compose.rootless.yml ]; then
  if [ "$EFFECTIVE_ROOTLESS" = "1" ] || [ "$EFFECTIVE_ROOTLESS" = "true" ] || [ "$IS_ROOTLESS" = "1" ]; then
    USE_ROOTLESS_OVERLAY=1
  fi
fi

run_compose() {
  if [ "$USE_ROOTLESS_OVERLAY" = "1" ]; then
    run_docker compose --env-file .env -f docker-compose.yml -f docker-compose.rootless.yml "$@"
  else
    run_docker compose --env-file .env "$@"
  fi
}

cmd="${1:-status}"
if [ "$#" -gt 0 ]; then
  shift
fi

db_app_pass() {
  if [ -s ./secrets/db-password ]; then
    tr -d '\r\n' < ./secrets/db-password
    return 0
  fi
  printf '%s' "${DB_PASS:-}"
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
    "${BACKEND_IMAGE:-ghcr.io/cangiolo/sccloud-backend:latest}" \
    "ghcr.io/cangiolo/sccloud-backend:latest" \
    "${REDIS_IMAGE:-redis:7-alpine@sha256:ff02b58f971e7d7d156a1267e283fcbbeee91773b6aa36c49dac28ecfe28eadf}" \
    "${NGINX_IMAGE:-nginx:alpine@sha256:db35bfc6b2951e7f8a72db5db120288c127ffaeeb4a6d4b95a26fead017d5913}" \
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

case "$cmd" in
  status|ps)
    run_compose ps "$@"
    ;;
  logs)
    run_compose logs --tail "${TAIL:-200}" -f "$@"
    ;;
  stop|down)
    run_compose stop "$@"
    ;;
  restart)
    run_compose restart "$@"
    ;;
  pull)
    run_compose pull "$@"
    ;;
  up)
    ensure_projects_data_dir
    run_compose up -d "$@"
    ;;
  migrate-projects-dir)
    force_copy=0
    if [ "${1:-}" = "--force" ]; then
      force_copy=1
    fi
    if ! run_docker volume inspect sccloud_projects_data >/dev/null 2>&1; then
      echo "未检测到旧命名卷 sccloud_projects_data，无需迁移。"
      ensure_projects_data_dir
      exit 0
    fi
    target=$(resolve_projects_data_dir)
    if [ "$force_copy" != "1" ] && projects_data_dir_has_data "$target"; then
      echo "目标目录 ${target} 已存在项目数据，跳过覆盖（如需强制合并复制请加 --force）。"
      exit 0
    fi
    helper_img=$(pick_volume_helper_image) || {
      echo "未找到本地可用镜像用于迁移卷数据，请先执行 sh ./scripts/sccloud-ops.sh pull 后重试。" >&2
      exit 1
    }
    ensure_projects_data_dir
    echo "正在将旧 Docker 命名卷 sccloud_projects_data 无损复制到 ${target}（使用镜像 ${helper_img}）..."
    # 仅逐项复制 /src 子条目（避免 cp -a /src/. 覆盖宿主机 /dst 根目录属主与权限）
    # shellcheck disable=SC2016
    run_docker run --rm --user 0:0 \
      -v "sccloud_projects_data:/src:ro" \
      -v "${target}:/dst" \
      --entrypoint /bin/sh \
      "$helper_img" \
      -c 'for e in /src/* /src/.[!.]* /src/..?*; do if [ -e "$e" ] || [ -L "$e" ]; then cp -a "$e" /dst/ || exit 1; fi; done; chmod 0777 /dst 2>/dev/null || true' || {
      echo "卷数据迁移失败，请检查目标目录权限与磁盘空间。" >&2
      exit 1
    }
    ensure_projects_data_dir
    echo "迁移完成：${target}"
    echo "说明：旧命名卷 sccloud_projects_data 已保留作为备份，确认服务正常后再按需手动清理。"
    ;;
  promote-admin)
    user="${1:-}"
    if [ -z "$user" ]; then
      echo "用法: sh ./scripts/sccloud-ops.sh promote-admin <username>" >&2
      exit 1
    fi
    case "$user" in
      *[!A-Za-z0-9_.@-]*|'')
        echo "非法用户名：$user（仅允许字母、数字、_ . - @）" >&2
        exit 1
        ;;
    esac
    DB_PASS_VAL=$(db_app_pass)
    run_compose exec -T db mariadb -u"${DB_USER:-sccloud_app}" -p"${DB_PASS_VAL}" "${DB_NAME:-sccloud_v2}" \
      -e "UPDATE users SET role='admin', max_projects=100, total_quota=1000 WHERE username='${user}';"
    echo "已尝试将 ${user} 提升为 admin（请核对上方 SQL 结果）"
    ;;
  *)
    cat <<EOF
用法: sh ./scripts/sccloud-ops.sh <command>
  status | ps
  logs [service]          # TAIL=200 可改
  stop | restart | up | pull
  migrate-projects-dir [--force]  # 将旧命名卷 sccloud_projects_data 复制到 PROJECTS_DATA_DIR
  promote-admin <user>
  环境: SCCLOUD_ROOTLESS=1|0 控制是否叠加 docker-compose.rootless.yml（默认在 rootless Docker 下自动叠加）
EOF
    exit 1
    ;;
esac

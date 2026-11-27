#!/bin/sh
# scCloud 一键部署脚本自动化测试（POSIX sh，零外部依赖，兼容 dash / bash）
# 用法：sh ./tests/test_start_sh.sh

set -u
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy SCCLOUD_ASSUME_TTY

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP_BASE=$(mktemp -d "${TMPDIR:-/tmp}/sccloud-start-tests.XXXXXX")
SOCK_DIR=""
# shellcheck disable=SC2329
cleanup_tests() {
  rm -rf "$TMP_BASE"
  [ -n "$SOCK_DIR" ] && rm -rf "$SOCK_DIR"
}
trap cleanup_tests EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '  [PASS] %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '  [FAIL] %s: %s\n' "$1" "$2" >&2
}

assert_contains() {
  name=$1
  haystack=$2
  needle=$3
  if printf '%s\n' "$haystack" | grep -Fq -- "$needle"; then
    return 0
  fi
  fail "$name" "expected output to contain: $needle"
  printf '    --- actual output ---\n%s\n    ---------------------\n' "$haystack" >&2
  return 1
}

assert_not_contains() {
  name=$1
  haystack=$2
  needle=$3
  if printf '%s\n' "$haystack" | grep -Fq -- "$needle"; then
    fail "$name" "expected output NOT to contain: $needle"
    printf '    --- actual output ---\n%s\n    ---------------------\n' "$haystack" >&2
    return 1
  fi
  return 0
}

# 创建隔离测试沙盒（模拟外部用户干净 git clone：无 r-engine/r-library）
setup_sandbox() {
  case_id=$1
  sb="${TMP_BASE}/${case_id}"
  mkdir -p "$sb/scripts" "$sb/nginx" "$sb/r-engine/R" "$sb/r-engine/data" "$sb/fake-bin"
  cp "$REPO_ROOT/start.sh" "$sb/start.sh"
  cp "$REPO_ROOT/scripts/setup-wizard.sh" "$sb/scripts/setup-wizard.sh"
  cp "$REPO_ROOT/scripts/sccloud-ops.sh" "$sb/scripts/sccloud-ops.sh"
  cp "$REPO_ROOT/.env.example" "$sb/.env.example"
  cp "$REPO_ROOT/docker-compose.yml" "$sb/docker-compose.yml"
  cp "$REPO_ROOT/docker-compose.rootless.yml" "$sb/docker-compose.rootless.yml"
  chmod +x "$sb/start.sh" "$sb/scripts/setup-wizard.sh" "$sb/scripts/sccloud-ops.sh"
  printf 'server {}\n' > "$sb/nginx/nginx.bridge.conf"
  printf '# stub\n' > "$sb/r-engine/plumber.R"
  printf '# stub\n' > "$sb/r-engine/worker.R"
  printf '# stub\n' > "$sb/r-engine/run_job.R"
  chmod -R a+rX "$sb/nginx" "$sb/r-engine"

  # ---- mock docker ----
  cat > "$sb/fake-bin/docker" <<'EOF'
#!/bin/sh
set -u
[ -n "${MOCK_DOCKER_LOG:-}" ] && printf '%s\n' "$*" >> "$MOCK_DOCKER_LOG"

if [ "${1:-}" = "--version" ]; then
  if [ "${MOCK_IS_PODMAN:-0}" = "1" ]; then
    echo "podman version 5.1.1"
  else
    echo "Docker version 27.2.0, build 3ab4256"
  fi
  exit 0
fi

if [ "${1:-}" = "compose" ] && [ "${2:-}" = "version" ]; then
  echo "Docker Compose version v2.29.0"
  exit 0
fi

if [ "${1:-}" = "version" ]; then
  if [ "${MOCK_IS_PODMAN:-0}" = "1" ]; then
    echo "5.1.1"
  else
    echo "27.2.0"
  fi
  exit 0
fi

if [ "${1:-}" = "info" ]; then
  if [ -n "${MOCK_DOCKER_REQUIRE_HOST:-}" ] && [ "${DOCKER_HOST:-}" != "$MOCK_DOCKER_REQUIRE_HOST" ]; then
    echo "Cannot connect to the Docker daemon" >&2
    exit 1
  fi
  if [ "${MOCK_DOCKER_INFO_FAIL:-0}" = "1" ]; then
    echo "permission denied while trying to connect to the Docker daemon socket" >&2
    exit 1
  fi
  fmt=""
  shift
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--format" ]; then
      fmt="${2:-}"
      shift 2
    else
      shift
    fi
  done
  if [ "${MOCK_IS_PODMAN:-0}" = "1" ]; then
    case "$fmt" in
      *"Host.Security.Rootless"*)
        if [ "${MOCK_PODMAN_ROOTLESS:-0}" = "1" ]; then
          echo "true"
        else
          echo "false"
        fi
        ;;
      *"Store.GraphRoot"*)
        echo "${MOCK_PODMAN_GRAPH_ROOT:-/var/lib/containers/storage}"
        ;;
      *"SecurityOptions"*|*"DockerRootDir"*|*"HTTPProxy"*|*"Mirrors"*)
        echo "Error: template: field not supported in Podman" >&2
        exit 1
        ;;
      *)
        echo "podman info"
        ;;
    esac
    exit 0
  fi
  case "$fmt" in
    *"SecurityOptions"*)
      if [ "${MOCK_DOCKER_ROOTLESS:-0}" = "1" ]; then
        echo "[name=seccomp,profile=builtin name=rootless name=cgroupns]"
      else
        echo "[name=seccomp,profile=builtin]"
      fi
      ;;
    *"DockerRootDir"*)
      echo "${MOCK_DOCKER_ROOT_DIR:-/var/lib/docker}"
      ;;
    *"HTTPProxy"*)
      printf '%s|%s\n' "${MOCK_DOCKER_HTTP_PROXY:-}" "${MOCK_DOCKER_HTTPS_PROXY:-}"
      ;;
    *"Mirrors"*)
      echo "${MOCK_DOCKER_MIRRORS:-[]}"
      ;;
    *)
      echo "Server Version: 27.2.0"
      ;;
  esac
  exit 0
fi

if [ "${1:-}" = "inspect" ]; then
  if [ -n "${MOCK_HEALTH_LOG_OUTPUT:-}" ]; then
    echo "[exit=1] ${MOCK_HEALTH_LOG_OUTPUT}"
  fi
  exit 0
fi

if [ "${1:-}" = "image" ] && [ "${2:-}" = "inspect" ]; then
  ref="${3:-}"
  if [ "${MOCK_ALL_LOCAL_IMAGES:-0}" = "1" ]; then
    exit 0
  fi
  if [ -n "${MOCK_PULL_SUCCEED_ON_PROXY_FILE:-}" ] && [ -f "$MOCK_PULL_SUCCEED_ON_PROXY_FILE" ]; then
    exit 0
  fi
  if [ -n "${MOCK_DYNAMIC_IMAGES_FILE:-}" ] && [ -f "$MOCK_DYNAMIC_IMAGES_FILE" ] && grep -Fxq -- "$ref" "$MOCK_DYNAMIC_IMAGES_FILE" 2>/dev/null; then
    exit 0
  fi
  case " ${MOCK_LOCAL_IMAGES:-} " in
    *" ${ref} "*) exit 0 ;;
    *) exit 1 ;;
  esac
fi

if [ "${1:-}" = "load" ]; then
  cat >/dev/null
  if [ -n "${MOCK_DYNAMIC_IMAGES_FILE:-}" ]; then
    printf '%s\n' "${MOCK_LOAD_TAG:-ghcr.io/cangiolo/sccloud-r-engine:latest}" >> "$MOCK_DYNAMIC_IMAGES_FILE"
  fi
  exit 0
fi

if [ "${1:-}" = "images" ]; then
  printf '%s\n' "${MOCK_LOAD_TAG:-ghcr.io/cangiolo/sccloud-r-engine:latest}"
  exit 0
fi

if [ "${1:-}" = "ps" ]; then
  if [ -n "${MOCK_RUNNING_CONTAINERS:-}" ]; then
    printf '%s\n' "$MOCK_RUNNING_CONTAINERS"
  fi
  exit 0
fi

if [ "${1:-}" = "tag" ]; then
  if [ -n "${MOCK_DYNAMIC_IMAGES_FILE:-}" ] && [ -n "${3:-}" ]; then
    printf '%s\n' "$3" >> "$MOCK_DYNAMIC_IMAGES_FILE"
  fi
  exit 0
fi

if [ "${1:-}" = "volume" ] && [ "${2:-}" = "inspect" ]; then
  if [ "${3:-}" = "sccloud_projects_data" ] && [ "${MOCK_LEGACY_PROJECTS_VOLUME:-0}" = "1" ]; then
    echo '[{"Name":"sccloud_projects_data"}]'
    exit 0
  fi
  exit 1
fi

if [ "${1:-}" = "run" ]; then
  dst_host=""
  prev=""
  for a in "$@"; do
    if [ "$prev" = "-v" ]; then
      case "$a" in
        *:/dst) dst_host="${a%:/dst}" ;;
      esac
    fi
    prev="$a"
  done
  case " $* " in
    *'cp -a "$e" /dst/'*)
      if [ -n "$dst_host" ] && [ -n "${MOCK_LEGACY_VOLUME_SRC:-}" ] && [ -d "$MOCK_LEGACY_VOLUME_SRC" ]; then
        mkdir -p "$dst_host"
        for e in "$MOCK_LEGACY_VOLUME_SRC"/* "$MOCK_LEGACY_VOLUME_SRC"/.[!.]* "$MOCK_LEGACY_VOLUME_SRC"/..?*; do
          if [ -e "$e" ] || [ -L "$e" ]; then
            cp -a "$e" "$dst_host/" || exit 1
          fi
        done
      fi
      exit 0
      ;;
    *)
      if [ "${MOCK_LEGACY_PROJECTS_VOLUME:-0}" = "1" ] && [ "${MOCK_LEGACY_VOLUME_EMPTY:-0}" != "1" ]; then
        exit 0
      fi
      exit 1
      ;;
  esac
fi

if [ "${1:-}" = "compose" ]; then
  shift
  # 跳过 --env-file / -f / -p 等前置参数
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --env-file|-f|-p) shift 2 ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  subcmd="${1:-}"
  [ "$#" -gt 0 ] && shift
  case "$subcmd" in
    port)
      if [ -n "${MOCK_OWN_PORT:-}" ]; then
        echo "0.0.0.0:${MOCK_OWN_PORT}"
        exit 0
      fi
      exit 1
      ;;
    pull)
      if [ -n "${MOCK_PULL_SUCCEED_ON_PROXY_FILE:-}" ] && [ -f "$MOCK_PULL_SUCCEED_ON_PROXY_FILE" ]; then
        echo "Pull complete via synced proxy"
        exit 0
      fi
      [ -n "${MOCK_PULL_MSG:-}" ] && printf '%s\n' "$MOCK_PULL_MSG" >&2
      exit "${MOCK_PULL_RC:-0}"
      ;;
    build)
      exit "${MOCK_BUILD_RC:-0}"
      ;;
    up)
      exit "${MOCK_UP_RC:-0}"
      ;;
    ps)
      case " $* " in
        *" -q "*) echo "mock-cid-1" ;;
        *"Health"*) echo "${MOCK_PS_HEALTH:-healthy}" ;;
        *"Status"*) echo "${MOCK_PS_STATUS:-Up 5 seconds (healthy)}" ;;
        *) echo "sccloud-web-1 ${MOCK_PS_STATUS:-Up 5 seconds (healthy)}" ;;
      esac
      exit 0
      ;;
    logs)
      echo "${MOCK_SVC_LOGS:-mock container log line}"
      exit 0
      ;;
    exec)
      exit 0
      ;;
    *)
      exit 0
      ;;
  esac
fi

exit 0
EOF

  # ---- mock sudo ----
  cat > "$sb/fake-bin/sudo" <<'EOF'
#!/bin/sh
set -u
[ -n "${MOCK_SUDO_LOG:-}" ] && printf '%s\n' "$*" >> "$MOCK_SUDO_LOG"
if [ "${1:-}" != "-n" ]; then
  echo "ERROR: interactive sudo invoked without -n!" >&2
  exit 99
fi
exit "${MOCK_SUDO_RC:-1}"
EOF

  # ---- mock systemctl ----
  cat > "$sb/fake-bin/systemctl" <<'EOF'
#!/bin/sh
set -u
[ -n "${MOCK_SYSTEMCTL_LOG:-}" ] && printf '%s\n' "$*" >> "$MOCK_SYSTEMCTL_LOG"
case " $* " in
  *" is-active "*)
    exit "${MOCK_SYSTEMCTL_ACTIVE_RC:-0}"
    ;;
esac
exit 0
EOF

  # ---- mock ss ----
  cat > "$sb/fake-bin/ss" <<'EOF'
#!/bin/sh
set -u
echo "State  Recv-Q Send-Q Local Address:Port  Peer Address:Port"
for p in ${MOCK_LISTEN_PORTS:-}; do
  printf 'LISTEN 0      4096   0.0.0.0:%s       0.0.0.0:*\n' "$p"
done
EOF

  # ---- mock df ----
  cat > "$sb/fake-bin/df" <<'EOF'
#!/bin/sh
set -u
target="."
for a in "$@"; do
  target="$a"
done
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
if [ -n "${MOCK_DOCKER_ROOT_DIR:-}" ] && [ "$target" = "$MOCK_DOCKER_ROOT_DIR" ]; then
  printf '%s 104857600 52428800 %s 50%% %s\n' "${MOCK_DF_DOCKER_FS:-/dev/docker}" "${MOCK_DF_DOCKER_KB:-52428800}" "$target"
else
  printf '%s 104857600 52428800 %s 50%% %s\n' "${MOCK_DF_PROJ_FS:-/dev/proj}" "${MOCK_DF_PROJ_KB:-52428800}" "$target"
fi
EOF

  # ---- mock uname ----
  cat > "$sb/fake-bin/uname" <<'EOF'
#!/bin/sh
set -u
if [ "${1:-}" = "-m" ]; then
  echo "${MOCK_UNAME_M:-x86_64}"
  exit 0
fi
/usr/bin/uname "$@" 2>/dev/null || echo "Linux"
EOF

  # ---- mock curl ----
  cat > "$sb/fake-bin/curl" <<'EOF'
#!/bin/sh
set -u
url=""
write_code=0
for a in "$@"; do
  case "$a" in
    http://*|https://*) url="$a" ;;
    "%{http_code}") write_code=1 ;;
  esac
done
if [ "$write_code" = "1" ]; then
  case "$url" in
    *ghcr.io*) echo "${MOCK_CURL_GHCR_CODE:-401}" ;;
    *docker.io*) echo "${MOCK_CURL_HUB_CODE:-401}" ;;
    *) echo "200" ;;
  esac
  exit 0
fi
case "$url" in
  */healthz)
    exit "${MOCK_HEALTHZ_RC:-0}"
    ;;
esac
exit 0
EOF

  chmod +x "$sb/fake-bin/"*
  printf '%s' "$sb"
}

ALL_SIX_IMAGES="ghcr.io/cangiolo/sccloud-frontend:latest ghcr.io/cangiolo/sccloud-backend:latest ghcr.io/cangiolo/sccloud-r-engine:latest nginx:alpine@sha256:db35bfc6b2951e7f8a72db5db120288c127ffaeeb4a6d4b95a26fead017d5913 mariadb:11@sha256:2439dcd7d14010ecd1ff7a4e1c5abe8e208c34fe35290744deeeaac3569043c3 redis:7-alpine@sha256:ff02b58f971e7d7d156a1267e283fcbbeee91773b6aa36c49dac28ecfe28eadf"

echo "Running scCloud start.sh / sccloud-ops.sh unit tests..."

# ---------------- U1: 无 Docker 访问权限（共享机） ----------------
sb=$(setup_sandbox u1)
sudo_log="$sb/sudo.log"
out=$(
  cd "$sb" && \
  env -u DOCKER_HOST -u XDG_RUNTIME_DIR \
    PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    MOCK_DOCKER_INFO_FAIL=1 MOCK_SUDO_RC=1 MOCK_SUDO_LOG="$sudo_log" \
    sh ./start.sh 2>&1
)
rc=$?
ok_u1=1
[ "$rc" -ne 0 ] || { fail "U1" "expected non-zero exit"; ok_u1=0; }
assert_contains "U1" "$out" "dockerd-rootless-setuptool.sh" || ok_u1=0
assert_not_contains "U1" "$out" "interactive sudo invoked without -n" || ok_u1=0
if [ -f "$sudo_log" ] && grep -vq '^-n ' "$sudo_log"; then
  fail "U1" "sudo was invoked without -n"
  ok_u1=0
fi
[ "$ok_u1" = "1" ] && pass "U1: 无 Docker 权限时不阻塞 sudo，输出 Rootless 引导"

# ---------------- U2: Rootless socket 自动发现 ----------------
if command -v python3 >/dev/null 2>&1; then
  sb=$(setup_sandbox u2)
  # AF_UNIX 路径最长 108 字节，使用短 /tmp 目录避免超长 TMPDIR 报错
  SOCK_DIR=$(mktemp -d "/tmp/sc-sock.XXXXXX")
  sock_path="${SOCK_DIR}/docker.sock"
  python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$sock_path"
  out=$(
    cd "$sb" && \
    env -u DOCKER_HOST \
      PATH="$sb/fake-bin:$PATH" HOME="$sb/home" XDG_RUNTIME_DIR="$SOCK_DIR" \
      MOCK_DOCKER_REQUIRE_HOST="unix://${sock_path}" MOCK_DOCKER_ROOTLESS=1 \
      MOCK_ALL_LOCAL_IMAGES=1 \
      sh ./start.sh --doctor 2>&1
  )
  rc=$?
  ok_u2=1
  [ "$rc" -eq 0 ] || { fail "U2" "expected exit 0, got $rc"; ok_u2=0; }
  assert_contains "U2" "$out" "自动检测到 rootless Docker socket" || ok_u2=0
  assert_contains "U2" "$out" "模式=rootless" || ok_u2=0
  [ "$ok_u2" = "1" ] && pass "U2: 自动发现 rootless docker.sock 并识别 rootless 模式"
else
  pass "U2: (skipped - python3 not available to create UNIX socket)"
fi

# ---------------- U3: Shell 有代理但 dockerd 无代理 ----------------
sb=$(setup_sandbox u3)
out=$(
  cd "$sb" && \
  env PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    HTTPS_PROXY="http://127.0.0.1:7890" \
    MOCK_DOCKER_ROOTLESS=1 MOCK_DOCKER_HTTP_PROXY="" MOCK_DOCKER_HTTPS_PROXY="" \
    MOCK_ALL_LOCAL_IMAGES=1 \
    sh ./start.sh --doctor 2>&1
)
rc=$?
ok_u3=1
[ "$rc" -eq 0 ] || { fail "U3" "expected exit 0, got $rc"; ok_u3=0; }
assert_contains "U3" "$out" "Docker daemon 未配置代理" || ok_u3=0
# shellcheck disable=SC2088
assert_contains "U3" "$out" "~/.config/systemd/user/docker.service.d/sccloud-proxy.conf" || ok_u3=0
[ "$ok_u3" = "1" ] && pass "U3: 识别 Shell 与 rootless dockerd 代理错位并输出 drop-in 配置"

# ---------------- U4: pull 超时不回退 build ----------------
sb=$(setup_sandbox u4)
dlog="$sb/docker.log"
out=$(
  cd "$sb" && \
  env PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    MOCK_DOCKER_LOG="$dlog" MOCK_DOCKER_ROOTLESS=1 \
    MOCK_PULL_RC=1 MOCK_PULL_MSG='Head "https://registry-1.docker.io/v2/": dial tcp 1.2.3.4:443: i/o timeout' \
    MOCK_LOCAL_IMAGES="" \
    sh ./start.sh 2>&1
)
rc=$?
ok_u4=1
[ "$rc" -ne 0 ] || { fail "U4" "expected non-zero exit"; ok_u4=0; }
assert_contains "U4" "$out" "超时或网络不可达" || ok_u4=0
assert_contains "U4" "$out" "无需 r-engine/r-library" || ok_u4=0
if grep -Eq '^compose .* build' "$dlog" 2>/dev/null; then
  fail "U4" "docker compose build was unexpectedly called after pull timeout"
  ok_u4=0
fi
[ "$ok_u4" = "1" ] && pass "U4: pull 超时绝不回退 docker compose build，精准指出代理/网络原因"

# ---------------- U5: pull DENIED 不回退 build ----------------
sb=$(setup_sandbox u5)
dlog="$sb/docker.log"
out=$(
  cd "$sb" && \
  env PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    MOCK_DOCKER_LOG="$dlog" \
    MOCK_PULL_RC=1 MOCK_PULL_MSG='Error response from daemon: Head "https://ghcr.io/v2/...": denied: requested access to the resource is denied' \
    MOCK_LOCAL_IMAGES="" \
    sh ./start.sh 2>&1
)
rc=$?
ok_u5=1
[ "$rc" -ne 0 ] || { fail "U5" "expected non-zero exit"; ok_u5=0; }
assert_contains "U5" "$out" "拒绝访问或 tag 不存在" || ok_u5=0
if grep -Eq '^compose .* build' "$dlog" 2>/dev/null; then
  fail "U5" "docker compose build was unexpectedly called after pull DENIED"
  ok_u5=0
fi
[ "$ok_u5" = "1" ] && pass "U5: pull 遇 DENIED 绝不回退 build，提示检查镜像命名空间或登录"

# ---------------- U6: pull 失败但本地 6 镜像均就绪 ----------------
sb=$(setup_sandbox u6)
dlog="$sb/docker.log"
out=$(
  cd "$sb" && \
  env PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    MOCK_DOCKER_LOG="$dlog" \
    MOCK_PULL_RC=1 MOCK_PULL_MSG='temporary network error' \
    MOCK_LOCAL_IMAGES="$ALL_SIX_IMAGES" \
    sh ./start.sh 2>&1
)
rc=$?
ok_u6=1
[ "$rc" -eq 0 ] || { fail "U6" "expected exit 0, got $rc"; ok_u6=0; }
assert_contains "U6" "$out" "本地已具备全部 6 个镜像" || ok_u6=0
if grep -Eq '^compose .* build' "$dlog" 2>/dev/null; then
  fail "U6" "build should not run when all 6 local images exist"
  ok_u6=0
fi
[ "$ok_u6" = "1" ] && pass "U6: pull 失败但本地 6 镜像全齐时平滑回退本地缓存启动"

# ---------------- U7: 无 r-library 传 --build（且无本地 R 镜像） ----------------
sb=$(setup_sandbox u7)
dlog="$sb/docker.log"
out=$(
  cd "$sb" && \
  env PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    MOCK_DOCKER_LOG="$dlog" MOCK_LOCAL_IMAGES="" \
    sh ./start.sh --build 2>&1
)
rc=$?
ok_u7=1
[ "$rc" -ne 0 ] || { fail "U7" "expected non-zero exit"; ok_u7=0; }
assert_contains "U7" "$out" "已拦截 --build" || ok_u7=0
assert_contains "U7" "$out" "不含 r-engine/r-library" || ok_u7=0
if grep -Eq '^compose .* build' "$dlog" 2>/dev/null; then
  fail "U7" "build should be blocked before invoking docker compose build"
  ok_u7=0
fi
[ "$ok_u7" = "1" ] && pass "U7: 无 r-library 且无本地 R 镜像时，--build 在调用 BuildKit 前被拦截"

# ---------------- U8: 无 r-library 传 --build（但本地已有 R 镜像） ----------------
sb=$(setup_sandbox u8)
dlog="$sb/docker.log"
out=$(
  cd "$sb" && \
  env PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    MOCK_DOCKER_LOG="$dlog" \
    MOCK_LOCAL_IMAGES="ghcr.io/cangiolo/sccloud-r-engine:latest" \
    sh ./start.sh --build 2>&1
)
rc=$?
ok_u8=1
[ "$rc" -eq 0 ] || { fail "U8" "expected exit 0, got $rc"; ok_u8=0; }
if ! grep -Eq '^compose .* build frontend backend$' "$dlog" 2>/dev/null; then
  fail "U8" "expected docker compose build frontend backend only"
  cat "$dlog" >&2
  ok_u8=0
fi
[ "$ok_u8" = "1" ] && pass "U8: 无 r-library 但已有本地 R 镜像时，--build 仅构建 frontend 与 backend"

# ---------------- U9: 旧 .env 自动迁移 + 600 权限保持 ----------------
sb=$(setup_sandbox u9)
cat > "$sb/.env" <<'EOF'
WEB_PORT=8091
WEB_BIND_ADDRESS=127.0.0.1
FRONTEND_IMAGE=ghcr.io/zyzhou-saffron/sccloud-frontend:latest
BACKEND_IMAGE=ghcr.io/zyzhou-saffron/sccloud-backend:latest
R_ENGINE_IMAGE=ghcr.io/zyzhou-saffron/sccloud-r-engine:latest
EOF
chmod 600 "$sb/.env"
out=$(
  cd "$sb" && \
  env PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    MOCK_ALL_LOCAL_IMAGES=1 \
    sh ./start.sh --no-pull 2>&1
)
rc=$?
ok_u9=1
[ "$rc" -eq 0 ] || { fail "U9" "expected exit 0, got $rc"; ok_u9=0; }
grep -q '^FRONTEND_IMAGE=ghcr.io/cangiolo/sccloud-frontend:latest$' "$sb/.env" || { fail "U9" "FRONTEND_IMAGE not migrated"; ok_u9=0; }
grep -q '^BACKEND_IMAGE=ghcr.io/cangiolo/sccloud-backend:latest$' "$sb/.env" || { fail "U9" "BACKEND_IMAGE not migrated"; ok_u9=0; }
grep -q '^R_ENGINE_IMAGE=ghcr.io/cangiolo/sccloud-r-engine:latest$' "$sb/.env" || { fail "U9" "R_ENGINE_IMAGE not migrated"; ok_u9=0; }
# shellcheck disable=SC2012
env_perm=$(ls -l "$sb/.env" | awk '{print $1}')
case "$env_perm" in
  -rw-------*) ;;
  *) fail "U9" ".env perm degraded to $env_perm"; ok_u9=0 ;;
esac
assert_not_contains "U9" "$out" "当前绑定 0.0.0.0" || ok_u9=0
[ "$ok_u9" = "1" ] && pass "U9: 旧 .env 自动迁移为 ghcr.io/cangiolo/* 且保持 600 权限"

# ---------------- U10: 二次运行不漂移自家占用端口 ----------------
sb=$(setup_sandbox u10)
cat > "$sb/.env" <<'EOF'
WEB_PORT=8091
WEB_BIND_ADDRESS=0.0.0.0
EOF
chmod 600 "$sb/.env"
out=$(
  cd "$sb" && \
  env PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    MOCK_LISTEN_PORTS="8091" MOCK_OWN_PORT="8091" MOCK_ALL_LOCAL_IMAGES=1 \
    sh ./start.sh --no-pull 2>&1
)
rc=$?
ok_u10=1
[ "$rc" -eq 0 ] || { fail "U10" "expected exit 0, got $rc"; ok_u10=0; }
assert_contains "U10" "$out" "正由当前 scCloud 服务使用，保持不变" || ok_u10=0
grep -q '^WEB_PORT=8091$' "$sb/.env" || { fail "U10" "WEB_PORT drifted!"; ok_u10=0; }
[ "$ok_u10" = "1" ] && pass "U10: 端口被自家 web 容器占用时不发生 WEB_PORT 漂移"

# ---------------- U11: 外部进程占端口时自动顺延并保 600 权限 ----------------
sb=$(setup_sandbox u11)
out=$(
  cd "$sb" && \
  env PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    MOCK_LISTEN_PORTS="8080" MOCK_OWN_PORT="" MOCK_ALL_LOCAL_IMAGES=1 \
    sh ./start.sh --no-pull 2>&1
)
rc=$?
ok_u11=1
[ "$rc" -eq 0 ] || { fail "U11" "expected exit 0, got $rc"; ok_u11=0; }
grep -q '^WEB_PORT=8081$' "$sb/.env" || { fail "U11" "expected WEB_PORT=8081"; ok_u11=0; }
# shellcheck disable=SC2012
env_perm=$(ls -l "$sb/.env" | awk '{print $1}')
case "$env_perm" in
  -rw-------*) ;;
  *) fail "U11" ".env perm degraded to $env_perm"; ok_u11=0 ;;
esac
[ "$ok_u11" = "1" ] && pass "U11: 端口被外部占用时顺延到 8081 且 .env 权限保持 600"

# ---------------- U12: 非 amd64 架构与 DockerRootDir 磁盘不足告警 ----------------
sb=$(setup_sandbox u12)
mkdir -p "$sb/docker-data"
out=$(
  cd "$sb" && \
  env PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    MOCK_UNAME_M="aarch64" \
    MOCK_DOCKER_ROOT_DIR="$sb/docker-data" \
    MOCK_DF_PROJ_KB=52428800 MOCK_DF_DOCKER_KB=5242880 \
    MOCK_ALL_LOCAL_IMAGES=1 \
    sh ./start.sh --doctor 2>&1
)
rc=$?
ok_u12=1
[ "$rc" -eq 0 ] || { fail "U12" "expected exit 0, got $rc"; ok_u12=0; }
assert_contains "U12" "$out" "非 amd64 架构（aarch64）" || ok_u12=0
assert_contains "U12" "$out" "Docker 数据目录" || ok_u12=0
assert_contains "U12" "$out" "约 5GB" || ok_u12=0
[ "$ok_u12" = "1" ] && pass "U12: 提前告警非 amd64 架构与 DockerRootDir 空间不足"

# ---------------- U13: --doctor 只读不改任何文件、不 pull/build/up ----------------
sb=$(setup_sandbox u13)
dlog="$sb/docker.log"
out=$(
  cd "$sb" && \
  env PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    MOCK_DOCKER_LOG="$dlog" MOCK_ALL_LOCAL_IMAGES=1 \
    sh ./start.sh --doctor 2>&1
)
rc=$?
ok_u13=1
[ "$rc" -eq 0 ] || { fail "U13" "expected exit 0, got $rc"; ok_u13=0; }
[ ! -e "$sb/.env" ] || { fail "U13" "--doctor must not create .env"; ok_u13=0; }
[ ! -e "$sb/secrets" ] || { fail "U13" "--doctor must not create secrets/"; ok_u13=0; }
if grep -Eq '^compose .* (pull|build|up)' "$dlog" 2>/dev/null; then
  fail "U13" "--doctor must not call pull/build/up"
  ok_u13=0
fi
[ "$ok_u13" = "1" ] && pass "U13: --doctor 严格只读（不创建 .env/secrets，不执行 pull/build/up）"

# ---------------- U14: sccloud-ops.sh Rootless 兼容与用户名防注入 ----------------
sb=$(setup_sandbox u14)
printf 'WEB_PORT=8080\n' > "$sb/.env"
chmod 600 "$sb/.env"
dlog="$sb/ops-docker.log"
ok_u14=1

(
  cd "$sb" && \
  env PATH="$sb/fake-bin:$PATH" MOCK_DOCKER_LOG="$dlog" \
    SCCLOUD_ROOTLESS=1 sh ./scripts/sccloud-ops.sh status >/dev/null 2>&1
)
grep -q -- '-f docker-compose.yml -f docker-compose.rootless.yml ps' "$dlog" || { fail "U14" "SCCLOUD_ROOTLESS=1 overlay missing"; ok_u14=0; }

: > "$dlog"
(
  cd "$sb" && \
  env PATH="$sb/fake-bin:$PATH" MOCK_DOCKER_LOG="$dlog" \
    SCLOUD_ROOTLESS=1 sh ./scripts/sccloud-ops.sh status >/dev/null 2>&1
)
grep -q -- '-f docker-compose.yml -f docker-compose.rootless.yml ps' "$dlog" || { fail "U14" "legacy SCLOUD_ROOTLESS=1 overlay missing"; ok_u14=0; }

: > "$dlog"
(
  cd "$sb" && \
  env PATH="$sb/fake-bin:$PATH" MOCK_DOCKER_LOG="$dlog" MOCK_DOCKER_ROOTLESS=1 \
    SCCLOUD_ROOTLESS=0 sh ./scripts/sccloud-ops.sh status >/dev/null 2>&1
)
if grep -q 'docker-compose.rootless.yml' "$dlog"; then
  fail "U14" "SCCLOUD_ROOTLESS=0 should disable rootless overlay"
  ok_u14=0
fi

: > "$dlog"
bad_out=$(
  cd "$sb" && \
  env PATH="$sb/fake-bin:$PATH" MOCK_DOCKER_LOG="$dlog" \
    sh ./scripts/sccloud-ops.sh promote-admin "bad'; DROP TABLE users;--" 2>&1
)
bad_rc=$?
[ "$bad_rc" -ne 0 ] || { fail "U14" "expected invalid username to be rejected"; ok_u14=0; }
assert_contains "U14" "$bad_out" "非法用户名" || ok_u14=0
if grep -q 'exec' "$dlog"; then
  fail "U14" "invalid username should be rejected before docker compose exec"
  ok_u14=0
fi
[ "$ok_u14" = "1" ] && pass "U14: sccloud-ops.sh 支持 SCCLOUD_ROOTLESS/SCLOUD_ROOTLESS 且拦截非法用户名"

# ---------------- U15: 交互式 pull 超时自动同步代理并重试成功 ----------------
sb=$(setup_sandbox u15)
dlog="$sb/docker.log"
slog="$sb/systemctl.log"
mkdir -p "$sb/home/.config/systemd/user/docker.service.d"
printf '# existing user proxy\n' > "$sb/home/.config/systemd/user/docker.service.d/http-proxy.conf"
conf_file="$sb/home/.config/systemd/user/docker.service.d/sccloud-proxy.conf"
out=$(
  cd "$sb" && \
  printf 'y\n' | env -u XDG_CONFIG_HOME PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    HTTPS_PROXY="http://127.0.0.1:7890" \
    SCCLOUD_ASSUME_TTY=1 \
    MOCK_DOCKER_LOG="$dlog" MOCK_SYSTEMCTL_LOG="$slog" \
    MOCK_DOCKER_ROOTLESS=1 MOCK_DOCKER_HTTP_PROXY="" MOCK_DOCKER_HTTPS_PROXY="" \
    MOCK_RUNNING_CONTAINERS="  - other-job-1 (Up 2 hours)" \
    MOCK_PULL_RC=1 MOCK_PULL_MSG='dial tcp 1.2.3.4:443: i/o timeout' \
    MOCK_PULL_SUCCEED_ON_PROXY_FILE="$conf_file" \
    sh ./start.sh 2>&1
)
rc=$?
ok_u15=1
[ "$rc" -eq 0 ] || { fail "U15" "expected exit 0 after retry, got $rc"; ok_u15=0; }
assert_contains "U15" "$out" "有 1 个正在运行的容器" || ok_u15=0
assert_contains "U15" "$out" "other-job-1" || ok_u15=0
assert_contains "U15" "$out" "自动重试镜像拉取" || ok_u15=0
[ -f "$conf_file" ] || { fail "U15" "sccloud-proxy.conf was not written"; ok_u15=0; }
grep -q 'Environment="HTTPS_PROXY=http://127.0.0.1:7890"' "$conf_file" 2>/dev/null || { fail "U15" "HTTPS_PROXY missing in sccloud-proxy.conf"; ok_u15=0; }
grep -q '# existing user proxy' "$sb/home/.config/systemd/user/docker.service.d/http-proxy.conf" || { fail "U15" "existing http-proxy.conf was modified!"; ok_u15=0; }
grep -q -- '--user daemon-reload' "$slog" 2>/dev/null || { fail "U15" "systemctl --user daemon-reload not called"; ok_u15=0; }
grep -q -- '--user restart docker' "$slog" 2>/dev/null || { fail "U15" "systemctl --user restart docker not called"; ok_u15=0; }
[ "$(grep -Ec '^compose .* pull$' "$dlog")" -eq 2 ] || { fail "U15" "expected exactly 2 compose pull attempts"; ok_u15=0; }
[ "$ok_u15" = "1" ] && pass "U15: 交互确认 y 后自动写 sccloud-proxy.conf、重启 dockerd 并自动重试拉取成功"

# ---------------- U16: 交互式 pull 超时选择 N 不修改代理也不 build ----------------
sb=$(setup_sandbox u16)
dlog="$sb/docker.log"
slog="$sb/systemctl.log"
conf_file="$sb/home/.config/systemd/user/docker.service.d/sccloud-proxy.conf"
out=$(
  cd "$sb" && \
  printf 'n\n' | env -u XDG_CONFIG_HOME PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    HTTPS_PROXY="http://127.0.0.1:7890" \
    SCCLOUD_ASSUME_TTY=1 \
    MOCK_DOCKER_LOG="$dlog" MOCK_SYSTEMCTL_LOG="$slog" \
    MOCK_DOCKER_ROOTLESS=1 MOCK_DOCKER_HTTP_PROXY="" MOCK_DOCKER_HTTPS_PROXY="" \
    MOCK_PULL_RC=1 MOCK_PULL_MSG='dial tcp 1.2.3.4:443: i/o timeout' \
    MOCK_LOCAL_IMAGES="" \
    sh ./start.sh 2>&1
)
rc=$?
ok_u16=1
[ "$rc" -ne 0 ] || { fail "U16" "expected non-zero exit when declining proxy sync"; ok_u16=0; }
[ ! -e "$conf_file" ] || { fail "U16" "sccloud-proxy.conf must not be written when user answers n"; ok_u16=0; }
if grep -q 'restart docker' "$slog" 2>/dev/null; then
  fail "U16" "systemctl restart must not be called when user answers n"
  ok_u16=0
fi
if grep -Eq '^compose .* build' "$dlog" 2>/dev/null; then
  fail "U16" "build must not be called"
  ok_u16=0
fi
[ "$ok_u16" = "1" ] && pass "U16: 交互回答 n 时不改配置、不重启 dockerd、不回退 build"

# ---------------- U17: 非交互终端 pull 超时不阻塞且提示 --sync-proxy ----------------
sb=$(setup_sandbox u17)
conf_file="$sb/home/.config/systemd/user/docker.service.d/sccloud-proxy.conf"
out=$(
  cd "$sb" && \
  env -u XDG_CONFIG_HOME PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    HTTPS_PROXY="http://127.0.0.1:7890" \
    MOCK_DOCKER_ROOTLESS=1 MOCK_DOCKER_HTTP_PROXY="" MOCK_DOCKER_HTTPS_PROXY="" \
    MOCK_PULL_RC=1 MOCK_PULL_MSG='dial tcp 1.2.3.4:443: i/o timeout' \
    MOCK_LOCAL_IMAGES="" \
    sh ./start.sh </dev/null 2>&1
)
rc=$?
ok_u17=1
[ "$rc" -ne 0 ] || { fail "U17" "expected non-zero exit"; ok_u17=0; }
[ ! -e "$conf_file" ] || { fail "U17" "non-interactive run must not write sccloud-proxy.conf"; ok_u17=0; }
assert_contains "U17" "$out" "--sync-proxy" || ok_u17=0
[ "$ok_u17" = "1" ] && pass "U17: 非交互终端不阻塞等待输入，明确提示 --sync-proxy"

# ---------------- U18: --sync-proxy 显式同步与 --clear-proxy 对称清理 ----------------
sb=$(setup_sandbox u18)
slog="$sb/systemctl.log"
mkdir -p "$sb/home/.config/systemd/user/docker.service.d"
printf '# keep me\n' > "$sb/home/.config/systemd/user/docker.service.d/http-proxy.conf"
conf_file="$sb/home/.config/systemd/user/docker.service.d/sccloud-proxy.conf"
out_sync=$(
  cd "$sb" && \
  env -u XDG_CONFIG_HOME PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    HTTPS_PROXY="http://127.0.0.1:7890" NO_PROXY="10.0.0.0/8" \
    MOCK_SYSTEMCTL_LOG="$slog" MOCK_DOCKER_ROOTLESS=1 \
    MOCK_PULL_SUCCEED_ON_PROXY_FILE="$conf_file" \
    sh ./start.sh --sync-proxy 2>&1
)
rc_sync=$?
ok_u18=1
[ "$rc_sync" -eq 0 ] || { fail "U18" "--sync-proxy failed with rc=$rc_sync"; ok_u18=0; }
[ -f "$conf_file" ] || { fail "U18" "sccloud-proxy.conf missing after --sync-proxy"; ok_u18=0; }
grep -q 'Environment="NO_PROXY=localhost,127.0.0.1,::1,10.0.0.0/8"' "$conf_file" 2>/dev/null || { fail "U18" "NO_PROXY merge failed"; ok_u18=0; }

: > "$slog"
out_clear=$(
  cd "$sb" && \
  env -u XDG_CONFIG_HOME PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    MOCK_SYSTEMCTL_LOG="$slog" MOCK_DOCKER_ROOTLESS=1 \
    sh ./start.sh --clear-proxy 2>&1
)
rc_clear=$?
[ "$rc_clear" -eq 0 ] || { fail "U18" "--clear-proxy failed with rc=$rc_clear"; ok_u18=0; }
[ ! -e "$conf_file" ] || { fail "U18" "sccloud-proxy.conf still exists after --clear-proxy"; ok_u18=0; }
grep -q '# keep me' "$sb/home/.config/systemd/user/docker.service.d/http-proxy.conf" || { fail "U18" "--clear-proxy must preserve existing http-proxy.conf"; ok_u18=0; }
grep -q -- '--user restart docker' "$slog" 2>/dev/null || { fail "U18" "--clear-proxy did not restart docker"; ok_u18=0; }
assert_contains "U18" "$out_sync" "已同步代理" || ok_u18=0
assert_contains "U18" "$out_clear" "恢复 Docker daemon 直连" || ok_u18=0
[ "$ok_u18" = "1" ] && pass "U18: --sync-proxy 合并 NO_PROXY 写入，--clear-proxy 仅清理 sccloud-proxy.conf"

# ---------------- U19: 非法代理 URL 拒绝写入 ----------------
sb=$(setup_sandbox u19)
conf_file="$sb/home/.config/systemd/user/docker.service.d/sccloud-proxy.conf"
out=$(
  cd "$sb" && \
  env -u XDG_CONFIG_HOME PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    HTTPS_PROXY='http://127.0.0.1:7890" bad' \
    MOCK_DOCKER_ROOTLESS=1 MOCK_ALL_LOCAL_IMAGES=1 \
    sh ./start.sh --sync-proxy 2>&1
)
rc=$?
ok_u19=1
[ "$rc" -ne 0 ] || { fail "U19" "expected invalid proxy URL to be rejected"; ok_u19=0; }
[ ! -e "$conf_file" ] || { fail "U19" "invalid proxy URL must not write drop-in file"; ok_u19=0; }
assert_contains "U19" "$out" "终端代理地址格式不合法" || ok_u19=0
[ "$ok_u19" = "1" ] && pass "U19: 含非法字符的代理 URL 被安全拦截，不破坏 systemd drop-in"

# ---------------- U20: 默认初始化创建 ./data/projects 脚手架与 .env PROJECTS_DATA_DIR ----------------
sb=$(setup_sandbox u20)
out=$(
  cd "$sb" && \
  PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    MOCK_ALL_LOCAL_IMAGES=1 \
    sh ./start.sh --no-pull 2>&1
)
rc=$?
ok_u20=1
[ "$rc" -eq 0 ] || { fail "U20" "expected exit 0, got $rc"; ok_u20=0; }
[ -d "$sb/data/projects/users" ] || { fail "U20" "./data/projects/users missing"; ok_u20=0; }
[ -d "$sb/data/projects/_tmp/exports" ] || { fail "U20" "./data/projects/_tmp/exports missing"; ok_u20=0; }
[ -d "$sb/data/projects/_tmp/chunks" ] || { fail "U20" "./data/projects/_tmp/chunks missing"; ok_u20=0; }
[ -d "$sb/data/projects/_tmp/inspect" ] || { fail "U20" "./data/projects/_tmp/inspect missing"; ok_u20=0; }
grep -q '^PROJECTS_DATA_DIR=./data/projects$' "$sb/.env" || { fail "U20" "PROJECTS_DATA_DIR missing in .env"; ok_u20=0; }
assert_contains "U20" "$out" "项目数据目录：${sb}/data/projects" || ok_u20=0
[ "$ok_u20" = "1" ] && pass "U20: 一键启动自动初始化 ./data/projects/{users,_tmp/*} 并写入 PROJECTS_DATA_DIR"

# ---------------- U21: 非交互模式下检测到非空旧卷 sccloud_projects_data 拦截 compose up ----------------
sb=$(setup_sandbox u21)
dlog="$sb/docker.log"
out=$(
  cd "$sb" && \
  PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    MOCK_DOCKER_LOG="$dlog" MOCK_ALL_LOCAL_IMAGES=1 \
    MOCK_LEGACY_PROJECTS_VOLUME=1 \
    sh ./start.sh --no-pull </dev/null 2>&1
)
rc=$?
ok_u21=1
[ "$rc" -ne 0 ] || { fail "U21" "expected non-zero exit when legacy volume not migrated"; ok_u21=0; }
assert_contains "U21" "$out" "sccloud_projects_data" || ok_u21=0
assert_contains "U21" "$out" "migrate-projects-dir" || ok_u21=0
if grep -Eq '^compose .* up -d' "$dlog" 2>/dev/null; then
  fail "U21" "compose up -d must NOT run when legacy volume migration is pending"
  ok_u21=0
fi
[ "$ok_u21" = "1" ] && pass "U21: 非交互模式检测到未迁移旧命名卷时安全拦截，不以空目录覆盖启动"

# ---------------- U22: 交互模式确认 y 自动将旧卷数据无损复制到 ./data/projects 后继续启动 ----------------
sb=$(setup_sandbox u22)
dlog="$sb/docker.log"
legacy_src="$sb/mock_legacy_vol"
mkdir -p "$legacy_src/6/0903"
printf 'legacy-ok\n' > "$legacy_src/6/0903/marker.txt"
out=$(
  cd "$sb" && \
  printf 'y\n' | PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    SCCLOUD_ASSUME_TTY=1 \
    MOCK_DOCKER_LOG="$dlog" MOCK_ALL_LOCAL_IMAGES=1 \
    MOCK_LEGACY_PROJECTS_VOLUME=1 MOCK_LEGACY_VOLUME_SRC="$legacy_src" \
    sh ./start.sh --no-pull 2>&1
)
rc=$?
ok_u22=1
[ "$rc" -eq 0 ] || { fail "U22" "expected exit 0 after interactive volume migration, got $rc"; ok_u22=0; }
[ -f "$sb/data/projects/6/0903/marker.txt" ] || { fail "U22" "migrated file missing in ./data/projects/6/0903/marker.txt"; ok_u22=0; }
grep -Eq '^compose .* up -d' "$dlog" || { fail "U22" "compose up -d should run after migration"; ok_u22=0; }
assert_contains "U22" "$out" "旧卷数据已复制到" || ok_u22=0
[ "$ok_u22" = "1" ] && pass "U22: 交互确认 y 后自动无损迁移旧命名卷到 ./data/projects 并启动服务"

# ---------------- U23: sccloud-ops.sh migrate-projects-dir 支持自定义目录且默认不重复覆盖 ----------------
sb=$(setup_sandbox u23)
dlog="$sb/docker.log"
legacy_src="$sb/mock_legacy_vol"
custom_dst="$sb/custom_projects_dir"
mkdir -p "$legacy_src/15/1118"
printf 'v1\n' > "$legacy_src/15/1118/data.txt"
(cd "$sb" && PATH="$sb/fake-bin:$PATH" sh ./scripts/setup-wizard.sh >/dev/null 2>&1)
out1=$(
  cd "$sb" && \
  PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    PROJECTS_DATA_DIR="$custom_dst" \
    MOCK_DOCKER_LOG="$dlog" \
    MOCK_ALL_LOCAL_IMAGES=1 MOCK_LEGACY_PROJECTS_VOLUME=1 MOCK_LEGACY_VOLUME_SRC="$legacy_src" \
    sh ./scripts/sccloud-ops.sh migrate-projects-dir 2>&1
)
rc1=$?
printf 'v2\n' > "$legacy_src/15/1118/data.txt"
out2=$(
  cd "$sb" && \
  PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    PROJECTS_DATA_DIR="$custom_dst" \
    MOCK_DOCKER_LOG="$dlog" \
    MOCK_ALL_LOCAL_IMAGES=1 MOCK_LEGACY_PROJECTS_VOLUME=1 MOCK_LEGACY_VOLUME_SRC="$legacy_src" \
    sh ./scripts/sccloud-ops.sh migrate-projects-dir 2>&1
)
rc2=$?
ok_u23=1
[ "$rc1" -eq 0 ] || { fail "U23" "first migrate failed rc=$rc1"; ok_u23=0; }
[ "$rc2" -eq 0 ] || { fail "U23" "second migrate failed rc=$rc2"; ok_u23=0; }
[ "$(cat "$custom_dst/15/1118/data.txt" 2>/dev/null || true)" = "v1" ] || { fail "U23" "second run without --force should not overwrite"; ok_u23=0; }
if grep -Fq 'cp -a /src/. /dst/' "$dlog" 2>/dev/null; then
  fail "U23" "must copy children instead of /src/. so /dst root ownership is preserved"
  ok_u23=0
fi
assert_contains "U23" "$out1" "迁移完成" || ok_u23=0
assert_contains "U23" "$out2" "已存在项目数据，跳过覆盖" || ok_u23=0
[ "$ok_u23" = "1" ] && pass "U23: sccloud-ops.sh migrate-projects-dir 迁移到自定义目录、保留根属主并幂等防覆盖"

# ---------------- U24: podman-docker Rootless 检测、代理继承与 compose rootless 叠加 ----------------
sb=$(setup_sandbox u24)
dlog="$sb/docker.log"
podman_store="$sb/podman-store"
mkdir -p "$podman_store"
out_doc=$(
  cd "$sb" && \
  env PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    HTTPS_PROXY="http://127.0.0.1:7890" \
    MOCK_IS_PODMAN=1 MOCK_PODMAN_ROOTLESS=1 MOCK_PODMAN_GRAPH_ROOT="$podman_store" \
    MOCK_ALL_LOCAL_IMAGES=1 \
    sh ./start.sh --doctor 2>&1
)
rc_doc=$?
ok_u24=1
[ "$rc_doc" -eq 0 ] || { fail "U24" "--doctor failed under podman mock rc=$rc_doc"; ok_u24=0; }
assert_contains "U24" "$out_doc" "Docker(Podman 兼容) 就绪" || ok_u24=0
assert_contains "U24" "$out_doc" "模式=rootless" || ok_u24=0
assert_contains "U24" "$out_doc" "RootDir=${podman_store}" || ok_u24=0
assert_contains "U24" "$out_doc" "Podman 直接继承当前终端代理" || ok_u24=0
assert_not_contains "U24" "$out_doc" "Docker daemon 未配置代理" || ok_u24=0

out_up=$(
  cd "$sb" && \
  env PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    HTTPS_PROXY="http://127.0.0.1:7890" \
    MOCK_DOCKER_LOG="$dlog" \
    MOCK_IS_PODMAN=1 MOCK_PODMAN_ROOTLESS=1 MOCK_PODMAN_GRAPH_ROOT="$podman_store" \
    MOCK_ALL_LOCAL_IMAGES=1 \
    sh ./start.sh --no-pull 2>&1
)
rc_up=$?
[ "$rc_up" -eq 0 ] || { fail "U24" "start.sh --no-pull failed under podman mock rc=$rc_up"; ok_u24=0; }
assert_contains "U24" "$out_up" "服务已就绪" || ok_u24=0
assert_not_contains "U24" "$out_up" "Docker daemon 未配置代理" || ok_u24=0
grep -q -- '-f docker-compose.yml -f docker-compose.rootless.yml up -d' "$dlog" || { fail "U24" "rootless overlay not applied under rootless podman"; ok_u24=0; }
[ "$ok_u24" = "1" ] && pass "U24: podman-docker 正确识别 rootless/GraphRoot、免报 dockerd 代理错位并叠加 rootless 配置"

# ---------------- U25: Podman 状态仅显示 Up 时仍凭 Health=unhealthy 输出健康日志与容器日志 ----------------
sb=$(setup_sandbox u25)
out=$(
  cd "$sb" && \
  env PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    MOCK_IS_PODMAN=1 MOCK_ALL_LOCAL_IMAGES=1 \
    MOCK_UP_RC=1 MOCK_PS_STATUS="Up 21 minutes" MOCK_PS_HEALTH="unhealthy" \
    MOCK_HEALTH_LOG_OUTPUT="SyntaxError: invalid syntax" \
    MOCK_SVC_LOGS="uvicorn running on 8000" \
    sh ./start.sh --no-pull 2>&1
)
rc=$?
ok_u25=1
[ "$rc" -ne 0 ] || { fail "U25" "expected non-zero exit when compose up fails"; ok_u25=0; }
assert_contains "U25" "$out" "health=unhealthy" || ok_u25=0
assert_contains "U25" "$out" "[healthcheck]" || ok_u25=0
assert_contains "U25" "$out" "SyntaxError: invalid syntax" || ok_u25=0
assert_contains "U25" "$out" "uvicorn running on 8000" || ok_u25=0
[ "$ok_u25" = "1" ] && pass "U25: diagnose_failure 在 Podman Status 不含 unhealthy 时仍输出探活与服务日志"

# ---------------- U26: docker-compose*.yml 中 CMD 健康检查数组元素不得含空白（防 Podman 切分） ----------------
ok_u26=1
if command -v python3 >/dev/null 2>&1; then
  hc_check=$(python3 - "$REPO_ROOT" <<'PY'
import ast, glob, os, re, sys
root = sys.argv[1]
bad = []
for path in sorted(glob.glob(os.path.join(root, "docker-compose*.yml"))):
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            m = re.match(r'^\s*test:\s*(\[.*\])\s*(?:#.*)?$', line)
            if not m:
                continue
            try:
                arr = ast.literal_eval(m.group(1))
            except Exception as exc:
                bad.append(f"{os.path.basename(path)}:{lineno}: parse error: {exc}")
                continue
            if isinstance(arr, list) and arr and arr[0] == "CMD":
                for item in arr[1:]:
                    if isinstance(item, str) and any(ch.isspace() for ch in item):
                        bad.append(f"{os.path.basename(path)}:{lineno}: CMD arg contains whitespace: {item!r}")
if bad:
    print("\n".join(bad))
    sys.exit(1)
PY
  ) || { fail "U26" "$hc_check"; ok_u26=0; }
else
  for cf in "$REPO_ROOT"/docker-compose*.yml; do
    [ -f "$cf" ] || continue
    if grep -nE '^[[:space:]]*test:[[:space:]]*\["CMD"' "$cf" | grep -qE '"[^"]*[[:space:]][^"]*"'; then
      fail "U26" "CMD healthcheck item contains whitespace in $cf"
      ok_u26=0
    fi
  done
fi
[ "$ok_u26" = "1" ] && pass "U26: docker-compose*.yml 中所有 CMD 健康检查参数均不含空白字符"

# ---------------- U27: pull 前预加载离线 R 镜像包并跳过远端拉取 r-engine ----------------
sb=$(setup_sandbox u27)
dlog="$sb/docker.log"
dyn_imgs="$sb/dyn_images"
mkdir -p "$sb/data"
printf 'dummy-tar' | gzip > "$sb/data/sccloud-r-engine-image.tar.gz"
light_five="ghcr.io/cangiolo/sccloud-frontend:latest ghcr.io/cangiolo/sccloud-backend:latest nginx:alpine@sha256:db35bfc6b2951e7f8a72db5db120288c127ffaeeb4a6d4b95a26fead017d5913 mariadb:11@sha256:2439dcd7d14010ecd1ff7a4e1c5abe8e208c34fe35290744deeeaac3569043c3 redis:7-alpine@sha256:ff02b58f971e7d7d156a1267e283fcbbeee91773b6aa36c49dac28ecfe28eadf"
out=$(
  cd "$sb" && \
  env PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    MOCK_DOCKER_LOG="$dlog" \
    MOCK_LOCAL_IMAGES="$light_five" \
    MOCK_DYNAMIC_IMAGES_FILE="$dyn_imgs" \
    MOCK_LOAD_TAG="sccloud-r-engine:latest" \
    sh ./start.sh 2>&1
)
rc=$?
ok_u27=1
[ "$rc" -eq 0 ] || { fail "U27" "expected exit 0, got $rc"; ok_u27=0; }
assert_contains "U27" "$out" "从 data/sccloud-r-engine-image.tar.gz 加载 R 镜像" || ok_u27=0
assert_contains "U27" "$out" "跳过远端拉取 r-engine" || ok_u27=0
grep -Eq '^compose .* pull web frontend backend db redis$' "$dlog" 2>/dev/null || { fail "U27" "expected selective pull without r-engine"; ok_u27=0; }
load_line=$(grep -n '^load$' "$dlog" 2>/dev/null | head -n 1 | cut -d: -f1)
pull_line=$(grep -n '^compose .* pull' "$dlog" 2>/dev/null | head -n 1 | cut -d: -f1)
if [ -z "$load_line" ] || [ -z "$pull_line" ] || [ "$load_line" -ge "$pull_line" ]; then
  fail "U27" "expected docker load before compose pull (load=$load_line pull=$pull_line)"
  ok_u27=0
fi
[ "$ok_u27" = "1" ] && pass "U27: 存在离线 R 镜像包时在 pull 前自动加载并跳过远端拉取 r-engine"

# ---------------- U28: 首次全量拉取前输出体积与断点续传提示 ----------------
sb=$(setup_sandbox u28)
out=$(
  cd "$sb" && \
  env PATH="$sb/fake-bin:$PATH" HOME="$sb/home" \
    MOCK_PULL_RC=1 MOCK_LOCAL_IMAGES="" \
    sh ./start.sh 2>&1
)
rc=$?
ok_u28=1
[ "$rc" -ne 0 ] || { fail "U28" "expected non-zero exit on pull failure"; ok_u28=0; }
assert_contains "U28" "$out" "3.6GB" || ok_u28=0
assert_contains "U28" "$out" "3.15GB" || ok_u28=0
assert_contains "U28" "$out" "断点续传" || ok_u28=0
[ "$ok_u28" = "1" ] && pass "U28: 首次全量拉取前明确提示 3.6GB/3.15GB 体积与断点续传说明"

echo ""
printf 'Summary: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]

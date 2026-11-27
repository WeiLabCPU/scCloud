# 维护者文档

面向改代码、发版、编镜像、管机器的人。最终用户请看仓库根目录 [README.md](../README.md)。

## 架构端口对照

桥接 compose（`start.sh` 默认）对外一般只有 `WEB_PORT`（容器内 nginx 听 8080）。下表是 **host 网络 / 容器内**常见取值，方便对照 `docker-compose.server.yml`。

```
┌─────────────────────────────────────────────────────────────┐
│                     Nginx (:9000 host 网络入口)              │
├──────────────────┬──────────────────┬───────────────────────┤
│  Frontend (:3001)│  Backend (:8000) │   WebSocket (/ws/)    │
├──────────────────┴──────────────────┴───────────────────────┤
│            R-Engine (:8787)  Plumber + worker               │
├──────────────────┬──────────────────────────────────────────┤
│ MariaDB (:3307)  │              Redis (:6380)               │
└──────────────────┴──────────────────────────────────────────┘
```

| 组件 | 技术 | 作用 |
|------|------|------|
| 前端 | Next.js 16, deck.gl, Plotly | UI |
| 后端 | FastAPI, SQLAlchemy 2, Redis | REST、鉴权、编排、WS |
| R 引擎 | R 4.3.2, Seurat 5, Plumber | HTTP 计算 |
| Worker | 同镜像 `worker.R` | 队列重任务 |
| DB | MariaDB 11 | 用户 / 项目 / 任务 |
| 缓存 | Redis 7 | 队列、进度 |

## 预构建镜像（GHCR）

| 镜像 | 说明 |
|------|------|
| `ghcr.io/cangiolo/sccloud-frontend` | CI 推送，**只打 linux/amd64**（arm64 在 QEMU 里 Next 静态生成会 SIGILL） |
| `ghcr.io/cangiolo/sccloud-backend` | CI 推送，**amd64 + arm64** |
| `ghcr.io/cangiolo/sccloud-r-engine` | 不进 FE/BE 的 publish workflow；本机/GPU 有 `r-library` 再 build、push（token 要 `write:packages`） |

| 何时 | tag |
|------|-----|
| `main` 改 `frontend/**` 或 `backend/**` | `latest` + 短 SHA（只建改动的那个） |
| GitHub Release（Release Please 合并后） | 再加 `vX.Y.Z`、`X.Y.Z` |
| Actions 手动 `workflow_dispatch` | FE/BE 都建 `latest` + SHA |

当前**拉取默认**镜像在个人命名空间 `ghcr.io/cangiolo/...`（账号由 `zyzhou-saffron` 更名后，包仍在个人名下且已是 Public，可匿名拉取）。

仓库转到组织 `WeiLabCPU` 后，`github.repository_owner` 现为 `WeiLabCPU`。CI（`.github/workflows/docker-publish.yml`）仍硬编码 `GHCR_OWNER: zyzhou-saffron`；组织仓库的 `GITHUB_TOKEN` 也不能向个人 `cangiolo` 命名空间推送。在组织 Owner 开放 Packages 并完成迁移（路线 B）之前，不要把 CI 改成跨命名空间推送；路线 B 应将 `GHCR_OWNER` 改为 `${{ github.repository_owner }}`（即 `WeiLabCPU`）。

包建议 Public。可选 ACR：Variables/Secrets 配 `ALIYUN_ACR_*`，CI 用 `buildx imagetools` mirror（backend 多架构，frontend 仅 amd64）。

推 R 镜像时加 OCI label，才会出现在仓库 Packages 页：

```dockerfile
LABEL org.opencontainers.image.source="https://github.com/WeiLabCPU/scCloud"
```

## 发版（Release Please）

[release-please](https://github.com/googleapis/release-please) 在 `main` 上根据 `feat:` / `fix:` 维护 Release PR（`CHANGELOG.md`、`version.txt`、`.release-please-manifest.json`）。`ci:` / `chore:` 默认不进 CHANGELOG。

1. 日常 conventional commits  
2. 审未合并的 Release PR，确认 CHANGELOG 后合并  
3. 自动打 `vX.Y.Z` + GitHub Release  
4. `release` 事件触发 docker-publish，FE/BE 推 semver tag  

不要在 main 上手改 `version.txt` 与 release-please 抢跑。未合 Release PR 就不算发过版。

## R 引擎镜像

`r-library/` 不进 git。查找顺序见用户 README；维护者常用：

```bash
cp -r /path/to/R/library r-engine/r-library
docker build -t ghcr.io/cangiolo/sccloud-r-engine:latest ./r-engine
docker push ghcr.io/cangiolo/sccloud-r-engine:latest
```

从零装包约两小时：Dockerfile 用 `install_packages.R` 代替 `COPY r-library/`。

只改 `plumber.R` / `worker.R` / `run_job.R` / `R/` 时，可 `FROM` 现有镜像再 `COPY` 做 thin bake，避免重编 library。注意：若 compose bind-mount 了这些文件，进程读的是挂载内容不是镜像层。

Dockerfile 需 `COPY plumber.R worker.R run_job.R`，无挂载时 worker 才能启动。

## Host 网络部署

`docker-compose.server.yml`：绑核、大内存 worker 等场景。

```bash
cp .env.example .env.server
# 配置 DB / JWT 等；生产勿用默认管理员口令

docker compose --env-file .env.server -f docker-compose.server.yml up -d --build
# 或 pull 预构建镜像后 up -d（按 .env 中 IMAGE 变量）
```

访问 `http://<server-ip>:9000`。

## 环境变量与 secrets

完整列表见 [`.env.example`](../.env.example)。一键部署由 `scripts/setup-wizard.sh` 写 `.env` 与 `./secrets/`。

要点：

- DB / JWT / Redis / bootstrap 管理员密码在 **`./secrets/`**，compose secrets 挂载  
- `R_REDIS_URL` 由向导/start 按 redis 密码生成  
- `PROJECTS_DATA_DIR` 默认 `./data/projects`（宿主机项目数据落盘目录，收口在仓库目录内，避免占满普通服务器 `/var/lib/docker` 根盘；可按需改为绝对路径）；`PROJECTS_ROOT` 默认 `/data/projects`（容器内固定挂载点）  
- `SCCLOUD_ROOTLESS=1|0`（兼容旧名 `SCLOUD_ROOTLESS`）控制是否叠加 `docker-compose.rootless.yml`（默认在 rootless Docker 下自动叠加；监听地址统一由 `.env` 的 `WEB_BIND_ADDRESS` 控制）  
- 基础镜像支持通过 `.env` 覆盖：`NGINX_IMAGE`、`MARIADB_IMAGE`、`REDIS_IMAGE`（默认钉 digest）  
- 安全：`no-new-privileges`、`cap_drop`；部分服务 `read_only`；基础镜像钉 digest  

## 项目数据路径

```text
./data/projects/                                  # 容器内固定挂为 /data/projects
├── users/
│   └── {username}_u{user_id}/
│       ├── {project_name}/                       # 方案 A：最末级保持项目名，R 引擎产物前缀不变
│       │   ├── _uploaded/                        # 上传数据
│       │   └── ...                               # 分析结果
│       ├── _uploads/                             # 未绑定项目时的分片上传
│       └── _convert/                             # 格式转换临时目录
└── _tmp/
    ├── exports/                                  # 导出 ZIP 临时目录
    ├── chunks/                                   # 分片上传暂存目录
    └── inspect/                                  # R inspect 临时合并目录
```

- 游客：`guest_<uuid8>`，目录为 `users/guest_<uuid8>_u{user_id}/`；默认短保留（见 `ROLE_DEFAULTS`）  
- **老新共存**：历史项目 DB 中已记录的 `/data/projects/{user_id}/{project_name}` 继续按 `storage_path` 正常访问；`storage_paths.py` 的归属校验同时兼容新目录、游客升级前历史目录与旧版数字目录  
- **旧卷迁移**：老部署从命名卷 `sccloud_projects_data` 升级时，`start.sh` 会拦截空目录覆盖并引导运行 `sh ./scripts/sccloud-ops.sh migrate-projects-dir` 无损复制到 `PROJECTS_DATA_DIR`  
- **注意**：`storage_path` 存的是容器内路径（`/data/projects/...`），因此只要保持 `PROJECTS_ROOT=/data/projects` 不变，宿主机迁移 `PROJECTS_DATA_DIR` 无需改库；但 server 栈与一键栈仍**不要混用同一套 DB 却不迁文件**  

## 不用 start.sh

```bash
sh ./scripts/setup-wizard.sh
docker compose --env-file .env pull
docker compose --env-file .env up -d
curl -fsS "http://127.0.0.1:${WEB_PORT:-8080}/healthz"
```

桥接栈 R 探活：`http://127.0.0.1:${WEB_PORT}/r-health`（8787 默认不映射到宿主）。

SQL 可放 `data/initdb.d/`，仅空 MariaDB volume 首次导入。库中已有 users 不会再次 bootstrap 管理员。

## 本地开发

```bash
docker compose -f docker-compose.dev.yml up -d   # Redis + MariaDB

cd backend && python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
uvicorn app.main:app --reload --port 8000

cd frontend && npm install && npm run dev

docker run -p 8787:8787 \
  -v "$(pwd)/r-engine/plumber.R:/app/plumber.R:ro" \
  -v "$(pwd)/r-engine/R:/app/R:ro" \
  sccloud-r-engine
```

## 部署后 UI 回归

[`.claude/skills/frontend-ui-test/SKILL.md`](../.claude/skills/frontend-ui-test/SKILL.md) — 浏览器真点击回归（非 Playwright CI）。带上环境 `BASE_URL`。

## 项目结构（摘）

```
sccloud/
├── frontend/          # Next.js；CI 仅 amd64
├── backend/           # FastAPI
├── r-engine/          # plumber + worker + Dockerfile
├── nginx/
├── start.sh
├── docker-compose.yml
├── docker-compose.rootless.yml
├── docker-compose.server.yml
├── secrets/           # gitignore
├── scripts/
└── docs/
```

## API 索引

认证 `/api/auth`：register、login、refresh、me、change-password；另有 guest / upgrade-guest。  
项目 `/api/projects`：CRUD。  
任务 `/api/tasks`：提交、查询、取消、marker。  
上传 `/api/upload`：分片 init/chunk/complete。  
转换 `/api/convert`。  
系统：`GET /api/health`，`WS /ws/tasks/{id}`。

入口健康：桥接 `GET /healthz`（经 nginx）。

## SCENIC 与本地构建

SCENIC 的依赖安装现已纳入 `r-engine/Dockerfile`，包括 SCENIC、RcisTarget、GENIE3、AUCell、Arrow 和人/鼠注释包；构建末尾检查依赖是否可加载，缺包即失败。仍需按 Dockerfile 说明准备现有 `r-library/` 构建上下文。`SCENIC_REF` / `RCISTARGET_REF` 构建参数固定官方源码版本，升级时需验证 motif 注释与 feather 格式兼容性。

R 镜像目前不由前后端发布 workflow 自动构建。合并 R 代码后，维护者仍须构建、验证并发布新 R 镜像，随后让 `R_ENGINE_IMAGE` 指向新标签并重建 `r-engine` 和 `r-engine-worker`。仅重启旧容器不会安装新依赖或更新代码。不要把“修改了 Dockerfile”视为“线上镜像已更新”。

cisTarget 数据库需提前下载到 `r-engine/data/cistarget/`，步骤见[数据库说明](../r-engine/data/cistarget/README.md)。该目录在 compose 中同时挂载给 R API、worker 和后端；数据库不进入 Git 和镜像。小型内置 RDS 与各自 README 则纳入 Git，部署时由后端只读挂载分发。

SCENIC 默认用最多 5,000 个细胞推断网络，参数页可调整；AUCell 仍对全部细胞评分，因此抽样不能保证大样本不会耗尽内存。核数按宿主可检测 CPU 数封顶，容器 CPU 配额和内存仍需管理员合理设置。

前后端支持可选镜像源参数：

```bash
docker build --build-arg PIP_INDEX_URL=https://mirrors.ustc.edu.cn/pypi/simple -t sccloud-backend:local backend
docker build --build-arg NPM_REGISTRY=https://registry.npmmirror.com -t sccloud-frontend:local frontend
```

`backend/Dockerfile.local` 仅用于基于已有后端镜像更新应用与 Alembic 迁移。Python 依赖变化时请使用标准 `backend/Dockerfile` 重建。

标准 compose 保持 `init: true`，用于回收 R 子进程。rootless Podman 若报告缺少 `catatonit`，应由宿主机管理员安装它。确有需要时，可在个人 override 文件中为受影响服务设置 `init: false`，并在本机验证进程回收；不要修改公共 compose 的默认值。

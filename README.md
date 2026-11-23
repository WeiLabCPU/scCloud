# scCloud

浏览器里做单细胞 RNA-seq 分析：上传数据 → 跑全流程 Pipeline（质控、聚类、注释，以及差异基因、富集、CellChat 等）→ 看图和下结果。

技术栈概览：Next.js 前端、FastAPI 后端、R / Seurat 5 计算、MariaDB、Redis，用 Docker 一键拉起。

<p align="left">
  <img src="https://img.shields.io/badge/Next.js-16-000000?style=flat-square&logo=next.js&logoColor=white" alt="Next.js" />
  <img src="https://img.shields.io/badge/FastAPI-009688?style=flat-square&logo=fastapi&logoColor=white" alt="FastAPI" />
  <img src="https://img.shields.io/badge/Seurat-V5-4A90E2?style=flat-square" alt="Seurat V5" />
  <img src="https://img.shields.io/badge/Docker-2496ED?style=flat-square&logo=docker&logoColor=white" alt="Docker" />
</p>

![scCloud Dashboard](docs/images/dashboard.png)

## 部署条件

- 一台 **Linux x86_64（amd64）** 机器（当前预构建计算镜像仅支持 amd64）
- [Docker](https://docs.docker.com/get-docker/) ≥ 24，带 **Compose v2**（`docker compose version` 有输出）
- 内存建议 ≥ 16 GB（大数据集 32 GB+）
- 磁盘预留 ≥ 20 GB（全部镜像解压约 8 GB，另需拉取缓冲与项目数据）
- 能访问 GitHub 容器仓库（`ghcr.io`）与 Docker Hub（`nginx`/`mariadb`/`redis`），受限网络需给 Docker daemon 配置代理或镜像源

## 一键启动

```bash
git clone https://github.com/WeiLabCPU/scCloud.git
cd scCloud
sh ./start.sh
```

脚本会：

1. 检查 Docker / Compose  
2. 首次运行生成配置和密钥（`./.env`、`./secrets/`，不会进 git）  
3. 拉取预构建镜像并启动全部服务  
4. 若默认端口被占用，自动换一个并写进配置  

完成后看终端提示的地址，一般是：

```text
http://localhost:8080
```

（若换过端口，以终端打印的 `WEB_PORT` 为准。）

健康检查：打开 `http://localhost:<端口>/healthz`，应返回正常状态。

### 首次登录

空库第一次启动会创建管理员（仅此一次）：

| | 默认 |
|---|---|
| 用户名 | `admin` |
| 密码 | `admin123`（若你改过 `./secrets/bootstrap-admin-password` 则以文件为准） |

**登录后请立刻改密码。** 若服务绑定在 `0.0.0.0` 且对公网开放，务必先改密并加反向代理 / HTTPS。

### 日常命令

```bash
sh ./scripts/sccloud-ops.sh status   # 看容器是否在跑
sh ./scripts/sccloud-ops.sh logs     # 跟日志（Ctrl+C 退出）
sh ./scripts/sccloud-ops.sh stop     # 停止
sh ./start.sh                       # 再启动 / 更新后拉镜像再起
```

可选：

```bash
sh ./start.sh --doctor       # 只读环境体检（Docker/Rootless/代理/磁盘/端口/镜像）
sh ./start.sh --sync-proxy   # 将终端代理同步到 Docker daemon（sccloud-proxy.conf）并重启后启动
sh ./start.sh --clear-proxy  # 清理 sccloud-proxy.conf 并重启 Docker daemon 恢复直连
sh ./start.sh --no-pull      # 不重新拉镜像，用本机已有的
sh ./start.sh --build        # 本地构建（一般用户不需要；无需 r-engine/r-library）
```

<details>
<summary>共享 Linux 服务器（无 root / Rootless Docker）与代理配置</summary>

共享科研服务器上不建议把普通账号加入 `docker` 组（等同于整机 root 权限），推荐在自己账号下安装 **Rootless Docker**：

1. **检查前置条件**（两个命令需存在，两个文件里都应有当前用户记录且分配数量 ≥ 65536；缺失请联系管理员分配）：
   ```bash
   command -v newuidmap newgidmap
   grep "^$(whoami):" /etc/subuid /etc/subgid
   ```
2. **安装个人 Rootless Docker**：
   ```bash
   # 系统已带安装工具时直接运行（若系统 Docker 正在运行，加 --force，不要停系统服务）
   dockerd-rootless-setuptool.sh install

   # 若系统找不到 dockerd-rootless-setuptool.sh，可用官方脚本安装到 ~/bin
   # curl -fsSL https://get.docker.com/rootless -o /tmp/docker-rootless-install.sh
   # sh /tmp/docker-rootless-install.sh
   # export PATH="$HOME/bin:$PATH"
   ```
3. **启动并验证**：
   ```bash
   systemctl --user enable --now docker
   docker context use rootless
   docker info
   ```
   输出的 `Security Options` 包含 `rootless` 即成功。  
   > **关于 `docker info` 的大量 WARNING**：出现 `No cpu cfs quota support`、`No io.weight support`、`bridge-nf-call-iptables is disabled` 等警告在 Rootless 模式下**属于正常现象，不影响 scCloud 运行**。
4. **退出 SSH 后保持运行（可选）**：请管理员执行 `sudo loginctl enable-linger <你的用户名>`。
5. **配置拉取镜像代理（重要）**：终端里的 `export https_proxy=...` **不会**自动传给 `systemd --user` 中的 `dockerd`。
   - **一键自动配置**：在已设置终端 `https_proxy` 的交互终端里运行 `sh ./start.sh`，若拉取超时，脚本会自动询问是否写入独立配置 `sccloud-proxy.conf` 并重启后重试；也可直接执行 `sh ./start.sh --sync-proxy`（若使用的是临时代理端口，事后运行 `sh ./start.sh --clear-proxy` 可一键还原直连）。
   - **手工配置**（将代理地址替换为实际值）：
   ```bash
   mkdir -p ~/.config/systemd/user/docker.service.d
   cat <<'EOF' > ~/.config/systemd/user/docker.service.d/sccloud-proxy.conf
   [Service]
   Environment="HTTP_PROXY=http://127.0.0.1:7890"
   Environment="HTTPS_PROXY=http://127.0.0.1:7890"
   Environment="NO_PROXY=localhost,127.0.0.1,::1"
   EOF
   systemctl --user daemon-reload
   systemctl --user restart docker
   ```
6. **部署前体检与启动**：
   ```bash
   sh ./start.sh --doctor   # 确认 rootless、代理、磁盘与端口均正常
   sh ./start.sh            # 端口若与他人冲突会自动顺延，或在 .env 中指定 WEB_PORT
   ```

</details>

## 使用方式

1. 登录（或使用站点提供的游客入口，若已开启）  
2. 创建项目并上传单细胞数据（支持常见矩阵 / 10X 等，以界面为准）  
3. 在分析页配置并提交 **全流程 Pipeline**  
   - **Phase 1**：质控 → 降维聚类 → 细胞注释  
   - 确认注释后，按需跑 **Phase 2**（markers、富集、CellChat、轨迹、inferCNV 等）  
4. 在结果页查看 UMAP、表格、下载图表与文件  

<details>
<summary>界面示例</summary>

**UMAP**  
![UMAP](docs/images/umap.png)

**火山图**  
![volcano](docs/images/volcano.png)

**Marker**  
![marker](docs/images/marker.png)

</details>

## 数据存储

- **账号、项目名、任务状态**：存在数据库里（Docker 卷 `db_data` / `redis_data`，随 compose 项目保留）。  
- **表达矩阵、分析结果与导出/上传临时文件**：默认直接落在项目目录内 **`./data/projects`**（可通过 `.env` 中 `PROJECTS_DATA_DIR` 改为独立大盘路径，容器内固定挂载 `/data/projects`，搬迁宿主目录无需修改数据库）。目录结构：
  ```text
  ./data/projects/
  ├── users/{username}_u{user_id}/{project_name}/   # 用户与项目数据（可读且无碰撞）
  └── _tmp/{exports,chunks,inspect}/                # 导出 ZIP、分片上传与临时缓冲（自动定期清理）
  ```
- **老版本升级迁移**：如果你此前使用过旧版 Docker 命名卷 `sccloud_projects_data`，升级后运行 `sh ./start.sh` 会自动检测并引导通过 `sh ./scripts/sccloud-ops.sh migrate-projects-dir` 将旧数据无损复制到 `./data/projects`（旧卷保留作备份；老项目路径与新目录结构共存兼容）。  
- **Rootless Docker 宿主机清理提示**：容器内非 root 进程在 `./data/projects` 中创建的子文件在宿主机上归对应 subuid 所有，如需在宿主机手工删除整个目录可执行 `docker unshare rm -rf ./data/projects`。  
- 执行 `docker compose down -v` 或删除数据库 volume **会清空账号与元数据**，生产环境请先备份。  
- 游客账号若开放，数据保留时间较短，重要分析请注册正式用户。

## 常见问题

**端口被占用**  
`start.sh` 会在 `WEB_PORT` 起自动尝试后面几个端口。也可在 `.env` 里改 `WEB_PORT=8090` 后再 `sh ./start.sh`。

**打不开页面**  
先看 `sh ./scripts/sccloud-ops.sh status` 是否都是 healthy / running，再访问 `/healthz`。日志：`sh ./scripts/sccloud-ops.sh logs`。

**使用 Podman（`podman-docker`，如 RHEL / Rocky / AlmaLinux / CentOS 9）启动报 `sccloud-backend-1 is unhealthy`**  
旧版 `docker-compose.yml` 中 `backend` 健康检查使用了带空格的 `python -c ...` 命令，而 Podman 的 Docker 兼容 API（`podman.socket`）会对 `CMD` 数组按空白二次切分导致探活报 `SyntaxError`；同时 Podman 默认会将宿主代理透传进容器。新版已改用无空格 `curl` 探活并为容器内网地址配置 `NO_PROXY`：  
- 更新仓库后执行 `git pull && sh ./start.sh --no-pull` 即可自动重建 `backend` 并完成启动。  
- 若在非 root 账号下使用 Rootless Podman，请确认已由管理员开启 `sudo loginctl enable-linger $(whoami)`，避免退出 SSH 后健康检查定时器停止。

**拉取镜像失败 / 超时 / 提示缺少 `r-library`**  
- 先跑 `sh ./start.sh --doctor` 检查 Docker 代理、网络连通性和 `.env` 镜像地址。  
- 终端设置了 `https_proxy` 但拉镜像仍超时，说明代理没配进 Docker daemon（见上方「Rootless Docker 与代理配置」）。  
- 普通用户**不需要 `r-engine/r-library` 目录**，直接拉取预构建镜像即可；离线环境可从 [Release](https://github.com/WeiLabCPU/scCloud/releases) 下载 `sccloud-r-engine-image.tar.gz` 放入 `./data/` 后重跑 `sh ./start.sh`。  
- 旧版本已生成过 `.env`（含原 `ghcr.io/zyzhou-saffron/` 地址）的用户，`git pull` 后直接执行 `sh ./start.sh` 会自动迁移到 `ghcr.io/cangiolo/`。

**分析一直失败 / 内存不足**  
大数据集需要更大内存；可在 `.env` 中调整 `R_ENGINE_MEM_LIMIT`、`R_WORKER_MEM_LIMIT`（默认约 16g / 32g）后重启。

**忘记管理员密码**  
若库是空库重来，删 volume 后会按 `./secrets/bootstrap-admin-password` 再创建（**会丢数据**）。已有数据时需在库内改用户密码或联系部署管理员，不要对生产库随意 `down -v`。

**ARM 电脑（Apple Silicon 等）**  
前端与 R 计算镜像当前按 **amd64** 交付；在 ARM 上可能无法直接跑通完整栈。请使用 amd64 服务器或云主机。

## 架构简介

```text
浏览器 → Nginx（对外 WEB_PORT）
           ├─ 前端 Next.js
           ├─ 后端 FastAPI（API / 登录 / 任务）
           └─ R 计算（分析）+ Worker（排队跑重任务）
         MariaDB（元数据）  Redis（队列与进度）
```

一键模式默认只对外暴露 **一个** Web 端口；其它服务在 Docker 网络内部通信。

## 维护者文档

发版、CI 镜像、R 引擎构建与 host 网络部署等，见 **[docs/MAINTAINERS.md](docs/MAINTAINERS.md)**。

## License

Original application code is released under the [MIT License](LICENSE). Third-party dependencies retain their respective licenses.

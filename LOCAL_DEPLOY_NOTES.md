# 本地构建 / 部署说明（2026-11-23）

本文件记录本次「数据集 + SCENIC」功能上线时的本地镜像构建方式。
服务器上的容器运行时是 **rootless Podman**（`docker` 是 podman 兼容层）。

## 本次新增/修改

- 数据集模块
  - 后端：`backend/app/datasets/`（catalog.json + 路由），`main.py` 注册 `/api/datasets`
  - 前端：`/dashboard/datasets` 列表页与详情页、`lib/datasets-api.ts`、导航「数据集」
  - 数据：`r-engine/data/datasets/{pbmc3k,demo-test-subset}/`（挂载到后端 `/app/r-engine-data`）
- SCENIC 模块
  - 后端：step 白名单/超时/内存估算、Phase 2 步骤列表、项目导出目录 `10_SCENIC`
  - 前端：Phase 2 参数面板（参考基因组）、PipelineForm/View、结果标题
  - R：`r-engine/R/scenic.R` + `plumber.R` 的 `/scenic` 端点
  - cisTarget 数据库：`r-engine/data/cistarget/hg38__refseq-r80__10kb...feather`（约 1.2 GB）
  - 结果除了图，还输出 `regulonAUC_matrix.csv`（全部 regulon × 细胞）和
    `regulon_binary_matrix.csv`（二值矩阵），在网页结果页「数据」标签可下载
- 细胞注释（annotate）
  - SingleR 参考集已放到 `r-engine/data/ref/`：HPCA、BPE、DICE、NHD、MID、MRD、IGD
    （共 453 MB，来自 celldex；此前缺失导致 annotate 尝试联网下载 EH3492 失败）
  - inferCNV 用 bed：`r-engine/data/ref/gene_name_pos_human.bed`（小鼠版本目前缺失）
- inferCNV 依赖修复
  - 基础镜像缺 JAGS 运行库，导致 `infercnv`/`rjags` 加载失败
  - 已在镜像中 `apt install jags` 并补软链接：
    `/usr/local/JAGS` 和 `/usr/local/lib/JAGS` → `/usr/lib/x86_64-linux-gnu/JAGS`
- 兼容性修复（`scenic.R`）：单 regulon 时 SCENIC 1.3.1 内部 `rowSums` / `pheatmap` 边界问题

## 镜像与 .env

本地构建的镜像使用独立本地标签，`start.sh` 默认 pull 不会覆盖：

```
FRONTEND_IMAGE=localhost/sccloud-frontend:1.1.0-local
BACKEND_IMAGE=localhost/sccloud-backend:1.1.0-local
R_ENGINE_IMAGE=localhost/sccloud-r-engine-scenic:1.1.0
```

**重启服务请用：**

```bash
cd ~/sccloud/scCloud
sh ./start.sh --no-pull
# 或
docker compose up -d --no-pull
```

> 注意：
> 1. `docker compose up` 重建 backend/frontend 后，nginx 只在启动时解析上游地址，
>    需要顺带 `docker restart sccloud-web-1`，否则会短暂 502。
> 2. 镜像重新构建后，`docker restart` 不会换镜像，必须
>    `docker compose up -d --no-deps --force-recreate r-engine r-engine-worker`。

## 重新构建

- 前端/后端镜像在服务器本地构建，Dockerfile 新增了可选构建参数：
  - `--build-arg PIP_INDEX_URL=https://mirrors.ustc.edu.cn/pypi/simple`
  - `--build-arg NPM_REGISTRY=https://registry.npmmirror.com`
- 后端也可用派生镜像快速更新代码（仅改 Python 代码时）：
  `docker build -f backend/Dockerfile.local -t localhost/sccloud-backend:1.1.0-local backend`
- r-engine SCENIC 镜像的派生 Dockerfile 在 `~/scenic_build/Dockerfile`
  （arrow 15.0.1 预编译 libarrow、SCENIC/RcisTarget/GENIE3/AUCell、doRNG/doMC），
  `Dockerfile.infercnv` 在其上补 JAGS/inferCNV。
  依赖安装源：USTC CRAN / Westlake Bioconductor / 本地 tarball。

## 已知限制

- 当前只安装了 **hg38** cisTarget 数据库；前端选择 hg19/mm10/mm9 会报“未找到数据库”，
  需要时把对应 feather 放入 `r-engine/data/cistarget/` 即可。
- 小鼠 inferCNV 缺少 `gene_name_pos_mouse.bed`（放到 `r-engine/data/ref/` 即可）。
- SCENIC 的 Genie3 阶段较慢，单步超时已设为 12 小时，内存估算按细胞数线性估计。
- 参考脚本 run_SCENIC.R 也同样只把“第一个 regulon”画进 UMAP/Vln 图、热图取前 15 个；
  全部 regulon 请查看上面两个矩阵 CSV。

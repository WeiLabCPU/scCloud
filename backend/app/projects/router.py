"""
scCloud v2 — 项目路由
项目 CRUD 操作，替代旧系统中 app-new.R 的 observeEvent(input$confirmProject)。
"""

import os
import re
import shutil
from datetime import datetime

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, status
from pydantic import BaseModel, Field, field_validator
from sqlalchemy.orm import Session

from app.auth.deps import get_current_user
from fastapi.responses import FileResponse
from app.config import get_settings
from app.db.models import Pipeline, Project, Task, User, get_db
from app.utils.storage_paths import (
    cleanup_empty_user_dir,
    ensure_user_root,
    project_storage_dir,
)

router = APIRouter(prefix="/api/projects", tags=["项目管理"])


# ===== Schemas =====

class ProjectCreate(BaseModel):
    name: str = Field(..., min_length=1, max_length=255)
    description: str | None = None
    species: str = "human"

    @field_validator("name")
    @classmethod
    def validate_name(cls, v: str) -> str:
        """
        项目名称校验 — 防止路径穿越攻击。
        旧系统无此校验，用户可输入 '../../etc/passwd' 作为项目名。
        """
        if re.search(r'[/\\<>:"|?*\x00-\x1f]', v):
            raise ValueError("项目名称包含非法字符")
        if v.startswith(".") or ".." in v:
            raise ValueError("项目名称不能以 . 开头或包含 ..")
        return v.strip()

    @field_validator("species")
    @classmethod
    def validate_species(cls, v: str) -> str:
        if v not in ("human", "mouse"):
            raise ValueError("species 必须是 human 或 mouse")
        return v


class ProjectResponse(BaseModel):
    id: int
    name: str
    description: str | None
    species: str
    status: str
    storage_path: str | None
    created_at: datetime
    updated_at: datetime
    has_analyzed: bool = False

    model_config = {"from_attributes": True}


class ProjectList(BaseModel):
    total: int
    projects: list[ProjectResponse]


# ===== 路由 =====

@router.get("", response_model=ProjectList)
async def list_projects(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """获取当前用户的所有项目。"""
    projects = (
        db.query(Project)
        .filter(Project.user_id == current_user.id)
        .order_by(Project.updated_at.desc())
        .all()
    )
    return ProjectList(total=len(projects), projects=projects)


@router.post("", response_model=ProjectResponse, status_code=201)
async def create_project(
    req: ProjectCreate,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """
    创建项目。
    旧系统中此操作会被正在运行的分析任务阻塞 (BUG-T3)，
    新系统中完全异步，互不影响。
    """
    settings = get_settings()

    # 检查项目数量限制（使用计数器，删除项目不会减少，防止绕过限制）
    if current_user.projects_created >= current_user.max_projects:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=f"试用已结束，项目数量已达上限",
        )

    # 检查同名项目
    existing = (
        db.query(Project)
        .filter(
            Project.user_id == current_user.id,
            Project.name == req.name,
        )
        .first()
    )
    if existing:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="同名项目已存在",
        )

    # 创建存储目录（方案 A：{projects_root}/users/{username}_u{user_id}/{project_name}）
    ensure_user_root(settings.projects_root, current_user.id, current_user.username)
    storage_path = project_storage_dir(
        settings.projects_root,
        current_user.id,
        current_user.username,
        req.name,
    )
    os.makedirs(storage_path, exist_ok=True)
    # 后端容器与 R 引擎容器 UID 不同（10001 vs 1000），显式放开目录权限让 R 引擎可写。
    # (不用 os.umask(0): 它是进程级、并发建目录会竞态; 这里显式 chmod 目标目录即可。)
    try:
        os.chmod(storage_path, 0o777)
    except OSError:
        pass

    project = Project(
        name=req.name,
        user_id=current_user.id,
        description=req.description,
        species=req.species,
        storage_path=storage_path,
    )
    db.add(project)
    db.commit()
    db.refresh(project)

    # 递增项目创建计数（删除项目不减少，防止绕过限制）
    current_user.projects_created = (current_user.projects_created or 0) + 1
    db.commit()

    return project


@router.get("/{project_id}", response_model=ProjectResponse)
async def get_project(
    project_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """获取单个项目详情。"""
    project = (
        db.query(Project)
        .filter(Project.id == project_id, Project.user_id == current_user.id)
        .first()
    )
    if not project:
        raise HTTPException(status_code=404, detail="项目不存在")
    return project


@router.delete("/{project_id}", status_code=204)
async def delete_project(
    project_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """删除项目。"""
    project = (
        db.query(Project)
        .filter(Project.id == project_id, Project.user_id == current_user.id)
        .first()
    )
    if not project:
        raise HTTPException(status_code=404, detail="项目不存在")

    # 删除磁盘文件
    if project.storage_path and os.path.isdir(project.storage_path):
        shutil.rmtree(project.storage_path, ignore_errors=True)
        # 安全清理用户级空目录（绝不删除 projects_root 或 users/）
        cleanup_empty_user_dir(project.storage_path, get_settings().projects_root)

    db.delete(project)
    db.commit()


@router.get("/{project_id}/download")
async def download_project(
    project_id: int,
    background_tasks: BackgroundTasks,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Download all project files as a ZIP archive, organized by analysis step."""
    import errno
    import uuid
    import zipfile

    project = (
        db.query(Project)
        .filter(Project.id == project_id, Project.user_id == current_user.id)
        .first()
    )
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")

    project_dir = project.storage_path
    if not project_dir or not os.path.isdir(project_dir):
        raise HTTPException(status_code=404, detail="Project files not found")

    timestamp = datetime.now().strftime("%Y%m%d")
    zip_name = f"{project.name}-{timestamp}.zip"

    import re as _re

    STEP_DIR = {
        "qc": "1_Data_Preprocessing", "normalize": "1_Data_Preprocessing",
        "reduce": "2_DimRed_Cluster", "cluster": "2_DimRed_Cluster",
        "markers": "4_Differential_Genes", "marker": "4_Differential_Genes",
        "plot_markers": "4_Differential_Genes",
        "annotate": "3_Cell_Annotation",
        "enrich": "5_Pathway_Enrichment", "monocle": "6_Trajectory",
        "cellchat": "7_CellChat", "infercnv": "9_inferCNV",
        "wgcna": "8_WGCNA", "scenic": "10_SCENIC", "scenic_regulon": "10_SCENIC",
        "subset": "2_DimRed_Cluster",
    }
    _ts_re = _re.compile(r"_\d{14}_")
    _steps = set(STEP_DIR.keys())

    # quick/子任务步骤归档到其所属主步骤，避免导出时误判为独立分析。
    _step_alias = {
        "marker": "markers", "plot_markers": "markers", "markers_pairwise": "markers",
        "marker_expr": "markers", "subset_cluster": "subset",
        "cellchat_pathway": "cellchat", "scenic_regulon": "scenic",
        "merge_celltypes": "annotate",
    }

    def _canon_step(step: str | None) -> str | None:
        if step is None:
            return None
        return _step_alias.get(step, step)

    def _get_step(fn):
        base = fn.rsplit(".", 1)[0]
        if fn.endswith("_result.json"):
            s = fn.replace("_result.json", "")
            return s if s in _steps else None
        for p in base.split("_"):
            if p in _steps:
                return _canon_step(p)
        return None

    def _clean_name(fn):
        return _ts_re.sub("_", fn)

    def _safe_unlink(path: str) -> None:
        try:
            os.unlink(path)
        except OSError:
            pass

    # 当前分析结果 = 最近一条有完成步骤的 Pipeline + 其后单独重跑的步骤。
    # 不直接使用“最新 Pipeline 创建时间”，避免失败/取消的新建 Pipeline 误删既有有效结果。
    current_steps: set[str] = set()
    run_started_at = None
    recent_pipelines = (
        db.query(Pipeline)
        .filter(Pipeline.project_id == project.id)
        .order_by(Pipeline.created_at.desc())
        .limit(20)
        .all()
    )
    for pipeline in recent_pipelines:
        completed = (
            db.query(Task.step)
            .filter(Task.pipeline_id == pipeline.id, Task.status == "completed")
            .all()
        )
        steps = {_canon_step(row[0]) for row in completed if row[0]}
        if steps:
            current_steps = steps
            run_started_at = pipeline.started_at or pipeline.created_at
            break

    standalone_query = db.query(Task.step).filter(
        Task.project_id == project.id,
        Task.status == "completed",
    )
    if run_started_at is not None:
        standalone_query = standalone_query.filter(
            Task.pipeline_id.is_(None), Task.created_at >= run_started_at
        )
    for row in standalone_query.all():
        canon = _canon_step(row[0])
        if canon:
            current_steps.add(canon)

    # (step, clean_name) -> (mtime, file_path)
    file_map = {}

    for root, dirs, files in os.walk(project_dir):
        dirs[:] = [d for d in dirs if d not in ("tasks", "__pycache__",) and "_output_" not in d]
        for f in files:
            if f == ".gitkeep":
                continue
            step = _get_step(f)
            if step is None:
                step = "_Other"
            clean = _clean_name(f)
            key = (step, clean)
            fp = os.path.join(root, f)
            mt = os.path.getmtime(fp)
            rel = os.path.relpath(fp, project_dir)
            is_uploaded = rel.startswith("_uploaded" + os.sep)
            if (current_steps and step in _steps
                    and step not in current_steps and not is_uploaded):
                continue
            if key not in file_map or mt > file_map[key][0]:
                file_map[key] = (mt, fp)

    # 写入持久化卷下的 _tmp/exports，避免撑爆容器 128MB /tmp tmpfs；
    # 使用唯一文件名防并发覆盖，并在异常时立刻清理残留半成品。
    export_dir = get_settings().export_tmp_dir
    os.makedirs(export_dir, exist_ok=True)
    tmp_path = os.path.join(
        export_dir,
        f"sccloud_{project_id}_{timestamp}_{uuid.uuid4().hex[:8]}.zip",
    )
    try:
        with zipfile.ZipFile(tmp_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for (step, clean), (mt, fp) in sorted(file_map.items()):
                folder = STEP_DIR.get(step, "_Other")
                arc = os.path.join(project.name, folder, clean)
                try:
                    zf.write(fp, arc)
                except OSError as exc:
                    if exc.errno == errno.ENOSPC:
                        raise
                    # 单个源文件消失或无权读取时跳过，其余文件照常打包
                    pass
    except BaseException:
        _safe_unlink(tmp_path)
        raise

    background_tasks.add_task(_safe_unlink, tmp_path)
    return FileResponse(
        tmp_path,
        media_type="application/zip",
        filename=zip_name,
    )
@router.get("/{project_id}/genes")
async def get_project_genes(
    project_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """
    获取项目 Seurat 对象中所有可用基因名称。
    用于前端基因自动补全搜索。
    """
    import httpx

    project = (
        db.query(Project)
        .filter(Project.id == project_id, Project.user_id == current_user.id)
        .first()
    )
    if not project:
        raise HTTPException(status_code=404, detail="项目不存在")

    settings = get_settings()
    try:
        async with httpx.AsyncClient(
            timeout=httpx.Timeout(connect=10.0, read=120.0, write=10.0, pool=10.0)
        ) as client:
            response = await client.post(
                f"{settings.r_engine_url}/genes",
                json={"project_path": project.storage_path},
            )
        if response.status_code != 200:
            raise HTTPException(
                status_code=502,
                detail=f"R 引擎返回错误: {response.text}",
            )
        return response.json()
    except httpx.TimeoutException:
        raise HTTPException(
            status_code=504,
            detail="R 引擎超时，请稍后重试",
        )


# ===== 基因表达查询 =====

@router.get("/{project_id}/gene_expression")
async def get_gene_expression(
    project_id: int,
    gene: str,
    celltype: str = None,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """获取单个基因在所有细胞上的表达值 + UMAP 坐标，供前端渲染散点图。"""
    import httpx

    project = (
        db.query(Project)
        .filter(Project.id == project_id, Project.user_id == current_user.id)
        .first()
    )
    if not project:
        raise HTTPException(status_code=404, detail="项目不存在")

    settings = get_settings()
    try:
        r_params = {"project_path": project.storage_path, "gene": gene}
        if celltype:
            r_params["celltype"] = celltype
        async with httpx.AsyncClient(
            timeout=httpx.Timeout(connect=10.0, read=60.0, write=10.0, pool=10.0)
        ) as client:
            response = await client.get(
                f"{settings.r_engine_url}/gene_expression",
                params=r_params,
            )
        if response.status_code != 200:
            raise HTTPException(
                status_code=502,
                detail=f"R 引擎返回错误: {response.text}",
            )
        return response.json()
    except httpx.TimeoutException:
        raise HTTPException(
            status_code=504,
            detail="R 引擎超时，请稍后重试",
        )


# ===== 项目文件列表 =====

DATA_EXTENSIONS = {".rds", ".h5ad", ".h5seurat", ".rdata", ".h5"}



class ProjectFile(BaseModel):
    filename: str
    path: str
    size_mb: float


class ProjectFileList(BaseModel):
    files: list[ProjectFile]


@router.get("/{project_id}/files", response_model=ProjectFileList)
async def list_project_files(
    project_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """列出项目存储目录中的数据文件（.rds, .h5ad 等）。"""
    project = (
        db.query(Project)
        .filter(Project.id == project_id, Project.user_id == current_user.id)
        .first()
    )
    if not project:
        raise HTTPException(status_code=404, detail="项目不存在")

    if not project.storage_path:
        return ProjectFileList(files=[])

    # 只列出 _uploaded 子目录中的用户原始上传文件
    uploaded_dir = os.path.join(project.storage_path, "_uploaded")
    if not os.path.isdir(uploaded_dir):
        return ProjectFileList(files=[])

    files = []
    for fname in sorted(os.listdir(uploaded_dir)):
        ext = os.path.splitext(fname)[1].lower()
        if ext not in DATA_EXTENSIONS:
            continue
        fpath = os.path.join(uploaded_dir, fname)
        if os.path.isfile(fpath):
            size_mb = round(os.path.getsize(fpath) / 1024 / 1024, 2)
            # 去掉 UUID 前缀，显示原始文件名
            display_name = fname[9:] if len(fname) > 9 and fname[8] == "_" else fname
            files.append(ProjectFile(filename=display_name, path=fpath, size_mb=size_mb))

    return ProjectFileList(files=files)

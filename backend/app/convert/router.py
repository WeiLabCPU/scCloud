"""
scCloud v2 — 格式转换路由 (双向: 导入 + 导出)

导入方向: H5AD / H5 / CSV / TSV → Seurat RDS
导出方向: RDS → H5Seurat / H5AD
多样本整合: 多个 10X MTX ZIP → merge → RDS
"""

import json
import os
import re
import uuid
import zipfile
import shutil

from fastapi import (
    APIRouter,
    Depends,
    File,
    Form,
    HTTPException,
    UploadFile,
)
from fastapi.responses import FileResponse
from pydantic import BaseModel
from sqlalchemy.orm import Session

from app.auth.deps import get_current_user
from app.config import get_settings
from app.db.models import Project, User, get_db
from app.utils.storage_paths import (
    ensure_dir_mode,
    ensure_user_root,
    is_path_owned_by_user,
    project_storage_dir,
    user_convert_dir,
)

RDS_EXTENSIONS = {".rds", ".h5ad", ".h5seurat", ".h5", ".rdata", ".loom"}

router = APIRouter(prefix="/api/convert", tags=["格式转换"])


# ===== 请求/响应模型 =====

class ConvertRequest(BaseModel):
    """格式转换请求。"""
    direction: str  # "import" | "export"
    input_path: str
    input_format: str | None = None   # 导入时必填 (h5ad/h5/csv/tsv/rds)
    output_format: str | None = None  # 导出时必填 (h5seurat/h5ad/rds)


class ConvertResponse(BaseModel):
    """格式转换响应。"""
    status: str
    input_path: str
    output_path: str
    direction: str
    cells: int | None = None
    genes: int | None = None
    file_size_mb: float | None = None
    download_url: str | None = None


class MtxMergeResponse(BaseModel):
    """多样本整合响应。"""
    status: str
    n_samples: int
    cells: int | None = None
    genes: int | None = None
    file_size_mb: float | None = None
    output_path: str
    download_url: str | None = None


class ConvertImportRequest(BaseModel):
    """将转换/整合产物直接导入目标项目的请求。"""
    source_path: str
    project_id: int
    filename: str | None = None


class ConvertImportResponse(BaseModel):
    """转换/整合产物导入项目响应。"""
    status: str
    project_id: int
    filename: str
    path: str
    size_mb: float
    sample_groups: dict[str, str] = {}


# ===== 上传端点 =====

@router.post("/upload")
async def upload_for_convert(
    file: UploadFile = File(...),
    current_user: User = Depends(get_current_user),
):
    """
    上传文件用于格式转换。
    支持: .rds / .h5ad / .h5 / .csv / .tsv / .txt / .zip
    返回服务端存储路径。
    """
    settings = get_settings()

    allowed_ext = {".rds", ".h5seurat", ".h5ad", ".h5", ".csv", ".tsv", ".txt", ".zip", ".loom", ".rdata"}
    ext = os.path.splitext(file.filename or "")[1].lower()
    if ext not in allowed_ext:
        raise HTTPException(
            status_code=400,
            detail=f"不支持的文件类型: {ext}，支持: {', '.join(allowed_ext)}",
        )

    # 存储到用户的 _convert 临时目录
    ensure_user_root(settings.projects_root, current_user.id, current_user.username)
    upload_dir = user_convert_dir(
        settings.projects_root,
        current_user.id,
        current_user.username,
    )
    ensure_dir_mode(upload_dir, 0o777)

    filename = f"{uuid.uuid4().hex}{ext}"
    filepath = os.path.join(upload_dir, filename)

    content = await file.read()
    with open(filepath, "wb") as f:
        f.write(content)

    return {
        "status": "uploaded",
        "path": filepath,
        "original_name": file.filename,
        "size_mb": round(len(content) / 1024 / 1024, 2),
    }


# ===== 格式转换端点 (双向) =====

@router.post("", response_model=ConvertResponse)
async def convert_format(
    req: ConvertRequest,
    current_user: User = Depends(get_current_user),
):
    """
    执行格式转换 (双向)。
    - direction="import": 外部格式 → RDS
    - direction="export": RDS → 外部格式
    """
    settings = get_settings()

    # 构造输出路径
    input_dir = os.path.dirname(req.input_path)
    input_name = os.path.splitext(os.path.basename(req.input_path))[0]

    if req.direction == "import":
        output_path = os.path.join(input_dir, f"{input_name}_converted.rds")
        payload = {
            "direction": "import",
            "input_path": req.input_path,
            "input_format": req.input_format,
            "output_path": output_path,
        }
    else:
        fmt = req.output_format or "h5ad"
        ext_map = {"rds": ".rds", "h5seurat": ".h5seurat", "h5ad": ".h5ad"}
        out_ext = ext_map.get(fmt, f".{fmt}")
        output_path = os.path.join(input_dir, f"{input_name}{out_ext}")
        payload = {
            "direction": "export",
            "input_path": req.input_path,
            "output_format": fmt,
            "output_path": output_path,
        }

    # 调用 R 引擎
    import httpx

    async with httpx.AsyncClient(
        timeout=httpx.Timeout(connect=10.0, read=600.0, write=30.0, pool=10.0)
    ) as client:
        response = await client.post(
            f"{settings.r_engine_url}/convert",
            json=payload,
        )

    if response.status_code != 200:
        raise HTTPException(
            status_code=500,
            detail=f"R 引擎转换失败: {response.text}",
        )

    result = response.json()

    return ConvertResponse(
        status=result.get("status", "success"),
        input_path=req.input_path,
        output_path=output_path,
        direction=req.direction,
        cells=result.get("cells"),
        genes=result.get("genes"),
        file_size_mb=result.get("file_size_mb"),
        download_url=f"/api/convert/download?path={output_path}",
    )


# ===== 多样本 MTX 整合端点 =====

@router.post("/mtx-merge", response_model=MtxMergeResponse)
async def mtx_merge(
    sample_names: list[str] = Form(...),
    sample_groups: list[str] = Form(...),
    files: list[UploadFile] = File(...),
    current_user: User = Depends(get_current_user),
):
    """
    多样本整合。支持两种格式：
      - 10X MTX ZIP（包含 matrix.mtx.gz / features.tsv.gz / barcodes.tsv.gz）
      - 单文件格式（.rds / .h5ad / .h5seurat / .h5）
    """
    settings = get_settings()

    if len(files) < 1:
        raise HTTPException(status_code=400, detail="请至少提供 1 个样本文件")
    if len(files) != len(sample_names):
        raise HTTPException(
            status_code=400,
            detail="样本名称和文件数量不一致",
        )

    # 读取所有文件内容
    file_contents = []
    file_extensions = []
    for f in files:
        data = await f.read()
        file_contents.append(data)
        ext = os.path.splitext(f.filename or "")[1].lower()
        file_extensions.append(ext)

    # 判断格式：全部 .zip → 10X MTX 模式，否则 → 单文件合并模式
    all_zip = all(ext == ".zip" for ext in file_extensions)
    is_single_file = all(ext in RDS_EXTENSIONS for ext in file_extensions)

    # 存储目录
    ensure_user_root(settings.projects_root, current_user.id, current_user.username)
    convert_root = user_convert_dir(
        settings.projects_root,
        current_user.id,
        current_user.username,
    )
    ensure_dir_mode(convert_root, 0o777)
    merge_dir = os.path.join(
        convert_root,
        f"mtx_merge_{uuid.uuid4().hex[:8]}",
    )
    ensure_dir_mode(merge_dir, 0o777)

    if all_zip:
        # === 10X MTX ZIP 模式（原有逻辑）===
        sample_dirs = []
        for i, (name, data) in enumerate(zip(sample_names, file_contents)):
            zip_path = os.path.join(merge_dir, f"{name}.zip")
            with open(zip_path, "wb") as fp:
                fp.write(data)

            sample_dir = os.path.join(merge_dir, name)
            os.makedirs(sample_dir, exist_ok=True)
            os.chmod(sample_dir, 0o777)

            with zipfile.ZipFile(zip_path, "r") as zf:
                zf.extractall(sample_dir)

            actual_dir = _find_mtx_dir(sample_dir)
            if actual_dir is None:
                shutil.rmtree(merge_dir, ignore_errors=True)
                raise HTTPException(
                    status_code=400,
                    detail=f"样本 {name} 的 ZIP 中找不到 matrix.mtx 文件",
                )
            sample_dirs.append(actual_dir)

        output_path = os.path.join(merge_dir, "merged.rds")

        import httpx
        async with httpx.AsyncClient(
            timeout=httpx.Timeout(connect=10.0, read=1800.0, write=30.0, pool=10.0)
        ) as client:
            response = await client.post(
                f"{settings.r_engine_url}/convert_mtx_merge",
                json={
                    "sample_dirs": sample_dirs,
                    "sample_names": sample_names,
                    "output_path": output_path,
                },
            )
    else:
        # === 单文件模式（H5AD / RDS / H5Seurat）===
        rds_paths = []
        for i, (name, data, ext) in enumerate(zip(sample_names, file_contents, file_extensions)):
            # 保存原始文件
            orig_path = os.path.join(merge_dir, f"{name}{ext}")
            with open(orig_path, "wb") as fp:
                fp.write(data)

            # 非 RDS 格式需要先转换为 RDS
            if ext != ".rds":
                import httpx
                input_format_map = {
                    ".h5ad": "h5ad", ".h5seurat": "h5seurat",
                    ".h5": "h5", ".rdata": "rdata", ".loom": "loom",
                }
                input_format = input_format_map.get(ext)
                if not input_format:
                    shutil.rmtree(merge_dir, ignore_errors=True)
                    raise HTTPException(status_code=400, detail=f"不支持的格式: {ext}")

                rds_path = os.path.splitext(orig_path)[0] + ".rds"
                async with httpx.AsyncClient(
                    timeout=httpx.Timeout(connect=10.0, read=600.0, write=30.0, pool=10.0)
                ) as client:
                    convert_resp = await client.post(
                        f"{settings.r_engine_url}/convert",
                        json={
                            "direction": "import",
                            "input_path": orig_path,
                            "input_format": input_format,
                            "output_path": rds_path,
                        },
                    )
                if convert_resp.status_code != 200:
                    detail = convert_resp.json().get("error", convert_resp.text) if convert_resp.headers.get("content-type", "").startswith("application/json") else convert_resp.text
                    shutil.rmtree(merge_dir, ignore_errors=True)
                    raise HTTPException(status_code=500, detail=f"转换 {name} 失败: {detail}")
                rds_paths.append(rds_path)
            else:
                rds_paths.append(orig_path)

        output_path = os.path.join(merge_dir, "merged.rds")

        import httpx
        async with httpx.AsyncClient(
            timeout=httpx.Timeout(connect=10.0, read=1800.0, write=30.0, pool=10.0)
        ) as client:
            response = await client.post(
                f"{settings.r_engine_url}/convert_merge_rds",
                json={
                    "rds_paths": rds_paths,
                    "sample_names": sample_names,
                    "output_path": output_path,
                },
            )

    if response.status_code != 200:
        raise HTTPException(
            status_code=500,
            detail=f"R 引擎整合失败: {response.text}",
        )

    result = response.json()

    # 保存样本分组映射（供后续 QC 步骤使用）
    # 仅当用户实际设置了分组（至少一个非空值）时才写入
    groups_json_path = output_path + "_groups.json"
    import json
    group_map = {}
    has_real_group = False
    for nm, grp in zip(sample_names, sample_groups):
        if grp and grp.strip():
            group_map[nm] = grp.strip()
            has_real_group = True
    if has_real_group:
        with open(groups_json_path, "w") as gf:
            json.dump(group_map, gf, ensure_ascii=False)
        os.chmod(groups_json_path, 0o666)

    # R jsonlite 将单值包装为数组，需要解包
    def _r(v, default=None):
        if isinstance(v, list) and len(v) == 1:
            return v[0]
        return v if v is not None else default

    return MtxMergeResponse(
        status=_r(result.get("status"), "success"),
        n_samples=_r(result.get("n_samples"), len(files)),
        cells=_r(result.get("cells")),
        genes=_r(result.get("genes")),
        file_size_mb=_r(result.get("file_size_mb")),
        output_path=output_path,
        download_url=f"/api/convert/download?path={output_path}",
    )


# ===== 下载端点 =====

@router.get("/download")
async def download_converted(
    path: str,
    current_user: User = Depends(get_current_user),
):
    """下载转换后的文件。"""
    settings = get_settings()

    # 安全检查: 路径必须严格位于当前用户归属目录下（兼容新旧目录与游客升级，并防前缀穿透）
    abs_path = os.path.realpath(path)
    if not is_path_owned_by_user(
        abs_path,
        settings.projects_root,
        current_user.id,
        current_user.username,
    ):
        raise HTTPException(status_code=403, detail="无权访问此文件")

    if not os.path.isfile(abs_path):
        raise HTTPException(status_code=404, detail="文件不存在")

    return FileResponse(
        abs_path,
        filename=os.path.basename(abs_path),
        media_type="application/octet-stream",
    )


@router.post("/import-to-project", response_model=ConvertImportResponse)
async def import_converted_to_project(
    req: ConvertImportRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """
    将 _convert 目录下的整合/转换结果（如 merged.rds 及 _groups.json）
    安全复制到目标项目的 _uploaded/ 目录，免去用户下载后再分片重传。
    """
    settings = get_settings()

    abs_src = os.path.realpath(req.source_path)
    if not is_path_owned_by_user(
        abs_src,
        settings.projects_root,
        current_user.id,
        current_user.username,
    ):
        raise HTTPException(status_code=403, detail="无权访问此源文件")

    if not os.path.isfile(abs_src):
        raise HTTPException(status_code=404, detail="源文件不存在")

    src_ext = os.path.splitext(abs_src)[1].lower()
    raw_name = (req.filename or "").strip() or os.path.basename(abs_src)
    safe_filename = os.path.basename(raw_name)
    if (
        not safe_filename
        or safe_filename in (".", "..")
        or safe_filename.startswith(".")
        or ".." in safe_filename
        or "/" in raw_name
        or "\\" in raw_name
        or re.search(r'[<>:"|?*\x00-\x1f]', safe_filename)
    ):
        raise HTTPException(status_code=400, detail="目标文件名非法")

    target_ext = os.path.splitext(safe_filename)[1].lower()
    if not target_ext:
        safe_filename = f"{safe_filename}{src_ext}"
        target_ext = src_ext

    if target_ext not in RDS_EXTENSIONS:
        raise HTTPException(
            status_code=400,
            detail=f"不支持导入的文件类型: {target_ext}",
        )

    if current_user.total_quota and (current_user.used_quota or 0) >= current_user.total_quota:
        raise HTTPException(
            status_code=403,
            detail="操作配额使用结束，无法继续进行。",
        )

    project = (
        db.query(Project)
        .filter(
            Project.id == req.project_id,
            Project.user_id == current_user.id,
        )
        .first()
    )
    if not project:
        raise HTTPException(status_code=404, detail="项目不存在或无权访问")

    if project.has_analyzed:
        raise HTTPException(
            status_code=403,
            detail="该项目已完成分析，不能再导入新文件。如需重新分析请新建项目。",
        )

    if not project.storage_path:
        project.storage_path = project_storage_dir(
            settings.projects_root,
            current_user.id,
            current_user.username,
            project.name,
        )

    dest_dir = os.path.join(project.storage_path, "_uploaded")
    ensure_dir_mode(dest_dir, 0o777)

    # 去重：移除同目标文件名的旧副本及伴生分组文件
    for existing in os.listdir(dest_dir):
        if existing.endswith(f"_{safe_filename}") or existing == safe_filename:
            existing_path = os.path.join(dest_dir, existing)
            if os.path.isfile(existing_path):
                os.unlink(existing_path)
                old_groups = existing_path + "_groups.json"
                if os.path.isfile(old_groups):
                    os.unlink(old_groups)

    final_path = os.path.join(dest_dir, f"{uuid.uuid4().hex[:8]}_{safe_filename}")

    # 必须使用 copyfile 而非 os.link：r-engine (uid=1000) 产出的 merged.rds 在 rootless/protected_hardlinks 下
    # 跨 UID 硬链接给 backend (uid=10001) 会触发 EPERM
    shutil.copyfile(abs_src, final_path)
    try:
        os.chmod(final_path, 0o666)
    except OSError:
        pass

    sample_groups: dict[str, str] = {}
    src_groups_path = abs_src + "_groups.json"
    if not os.path.isfile(src_groups_path):
        alt_groups = os.path.realpath(req.source_path + "_groups.json")
        if is_path_owned_by_user(
            alt_groups,
            settings.projects_root,
            current_user.id,
            current_user.username,
        ) and os.path.isfile(alt_groups):
            src_groups_path = alt_groups
    if os.path.isfile(src_groups_path):
        try:
            with open(src_groups_path, "r", encoding="utf-8") as gf:
                parsed = json.load(gf)
            if isinstance(parsed, dict):
                sample_groups = {
                    str(k): str(v)
                    for k, v in parsed.items()
                    if v is not None and str(v).strip()
                }
                if sample_groups:
                    dest_groups = final_path + "_groups.json"
                    with open(dest_groups, "w", encoding="utf-8") as out_gf:
                        json.dump(sample_groups, out_gf, ensure_ascii=False)
                    try:
                        os.chmod(dest_groups, 0o666)
                    except OSError:
                        pass
        except Exception:
            sample_groups = {}

    db_user = db.query(User).filter(User.id == current_user.id).first()
    if db_user is not None:
        db_user.used_quota = (db_user.used_quota or 0) + 1
    db.commit()

    return ConvertImportResponse(
        status="imported",
        project_id=project.id,
        filename=safe_filename,
        path=final_path,
        size_mb=round(os.path.getsize(final_path) / (1024 * 1024), 2),
        sample_groups=sample_groups,
    )


# ===== 辅助函数 =====

def _find_mtx_dir(base_dir: str) -> str | None:
    """
    在解压目录中递归查找包含 matrix.mtx(.gz) 的目录。
    10X CellRanger 输出可能嵌套在子目录中。
    """
    import glob

    # 直接在 base_dir 下查找
    patterns = ["matrix.mtx", "matrix.mtx.gz"]
    for pattern in patterns:
        matches = glob.glob(os.path.join(base_dir, "**", pattern), recursive=True)
        if matches:
            return os.path.dirname(matches[0])

    return None

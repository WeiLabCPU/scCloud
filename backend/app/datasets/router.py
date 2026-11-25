"""
scCloud v2 — 数据集目录路由

两类数据集：
  - mode=local   ：内置小样本，文件存放在挂载目录 datasets/<id>/ 下，登录后由后端流式下载；
  - mode=external：公开外链索引（GEO / GSA / 论文 / 交互浏览器），页面跳转，不在平台内分发。

鉴权分层：
  - 列表 GET /api/datasets、详情 GET /api/datasets/{id}：游客可浏览；
  - 本地文件下载 GET /api/datasets/{id}/files/{filename}：必须登录（401 由前端跳转登录页）。
"""

import json
import os
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import FileResponse

from app.auth.deps import get_current_user
from app.db.models import User

router = APIRouter(prefix="/api/datasets", tags=["数据集目录"])

# 清单文件（随代码走，容器内位于 /app/app/datasets/catalog.json）
CATALOG_PATH = Path(__file__).with_name("catalog.json")

# 本地数据集文件根目录：
#   容器内：/app/r-engine-data/datasets（由 ./r-engine/data 只读挂载）
#   开发兜底：仓库内 r-engine/data/datasets
_CONTAINER_DATA_ROOT = Path("/app/r-engine-data/datasets")
_DEV_DATA_ROOT = Path(__file__).resolve().parents[3] / "r-engine" / "data" / "datasets"


def _data_root() -> Path:
    if _CONTAINER_DATA_ROOT.exists():
        return _CONTAINER_DATA_ROOT
    return _DEV_DATA_ROOT


def _load_catalog() -> dict:
    if not CATALOG_PATH.exists():
        raise HTTPException(status_code=500, detail="数据集清单未找到")
    with open(CATALOG_PATH, encoding="utf-8") as f:
        return json.load(f)


def _get_dataset(dataset_id: str) -> dict:
    catalog = _load_catalog()
    for ds in catalog["datasets"]:
        if ds["id"] == dataset_id:
            return ds
    raise HTTPException(status_code=404, detail="数据集不存在")


def _public_summary(ds: dict) -> dict:
    """列表用精简视图：不暴露服务器路径，只保留前端展示字段。"""
    return {
        "id": ds["id"],
        "mode": ds["mode"],
        "name": ds["name"],
        "en": ds["en"],
        "cells": ds.get("cells"),
        "cells_num": ds.get("cells_num"),
        "quality": ds.get("quality", False),
        "tissue": ds.get("tissue"),
        "disease": ds.get("disease"),
        "disease_group": ds.get("disease_group"),
        "cell": ds.get("cell"),
        "organism": ds.get("organism"),
        "year": ds.get("year"),
        "journal": ds.get("journal"),
        "platform": ds.get("platform"),
        "samples": ds.get("samples"),
        "n_files": len(ds.get("files", [])),
        "n_links": len(ds.get("links", [])),
    }


@router.get("")
async def list_datasets():
    """数据集目录（公开浏览）。"""
    catalog = _load_catalog()
    return {
        "total": len(catalog["datasets"]),
        "datasets": [_public_summary(ds) for ds in catalog["datasets"]],
    }


@router.get("/scenic/references")
async def scenic_references():
    """只开放已挂载的 v9 gene-ranking 数据库；下载中的 .part 文件不计入。"""
    db_root = _data_root().parent / "cistarget"
    references = [
        ref for ref in ("hg38", "hg19", "mm10", "mm9")
        if any(p.is_file() and p.stat().st_size > 0
               for p in db_root.glob(f"{ref}*mc9nr*.genes_vs_motifs.rankings.feather"))
    ]
    return {"references": references}


@router.get("/{dataset_id}")
async def get_dataset(dataset_id: str):
    """数据集详情（公开浏览）。"""
    ds = _get_dataset(dataset_id)
    return ds


@router.get("/{dataset_id}/files/{filename}")
async def download_local_file(
    dataset_id: str,
    filename: str,
    current_user: User = Depends(get_current_user),
):
    """
    下载内置本地数据集文件（强制登录）。
    仅允许下载清单 files 中登记的文件名，禁止路径穿越。
    """
    ds = _get_dataset(dataset_id)

    # 游客临时账号不可下载内置样本，需注册/正式登录后获取
    if getattr(current_user, "is_guest", False):
        raise HTTPException(status_code=403, detail="请先注册或登录后下载数据集")

    if ds["mode"] != "local":
        raise HTTPException(status_code=400, detail="该数据集为外链索引，请通过详情页链接访问")

    allowed = {f["name"] for f in ds.get("files", [])}
    # 只取文件名，剥掉任何目录成分，防止 ../ 穿越
    safe_name = os.path.basename(filename)
    if safe_name != filename:
        raise HTTPException(status_code=404, detail="文件不存在")
    if safe_name not in allowed:
        raise HTTPException(status_code=404, detail="文件不存在或未开放下载")

    file_path = (_data_root() / ds["id"] / safe_name).resolve()
    root = _data_root().resolve()
    if not file_path.is_relative_to(root) or not file_path.is_file():
        raise HTTPException(status_code=404, detail="文件不存在")

    media_type = "text/markdown" if safe_name.lower().endswith(".md") else "application/octet-stream"
    return FileResponse(
        file_path,
        media_type=media_type,
        filename=safe_name,
    )

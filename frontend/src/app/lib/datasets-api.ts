/**
 * scCloud v2 — 数据集目录 API
 *
 * 两类数据集：
 *  - local    ：内置小样本，登录后由后端流式下载（blob）；
 *  - external ：公开外链索引，页面跳转 GEO/GSA/论文/浏览器。
 *
 * 列表与详情可公开浏览；本地文件下载强制登录，401 时抛 DatasetAuthError，
 * 由前端弹窗/跳转登录。
 */

import { apiFetch, authedFetch, getAuthToken, tryRefresh } from "./api";

export interface DatasetFile {
  name: string;
  kind: "rds" | "h5ad" | "readme" | string;
  desc: string;
}

export interface DatasetLink {
  t: string;
  u: string;
}

export interface DatasetSummary {
  id: string;
  mode: "local" | "external";
  name: string;
  en: string;
  cells: string | null;
  cells_num: number | null;
  quality: boolean;
  tissue: string | null;
  disease: string | null;
  disease_group: string | null;
  cell: string | null;
  organism: string | null;
  year: number | null;
  journal: string | null;
  platform: string | null;
  samples: string | null;
  n_files: number;
  n_links: number;
}

export interface DatasetDetail {
  id: string;
  mode: "local" | "external";
  name: string;
  en: string;
  cells: string | null;
  cells_num: number | null;
  quality: boolean;
  tissue: string | null;
  disease: string | null;
  disease_group: string | null;
  cell: string | null;
  organism: string | null;
  year: number | null;
  journal: string | null;
  platform: string | null;
  samples: string | null;
  desc: string | null;
  paper: string | null;
  doi: string | null;
  acc: string | null;
  files: DatasetFile[];
  links: DatasetLink[];
}

interface DatasetList {
  total: number;
  datasets: DatasetSummary[];
}

/** 未登录访问本地下载 — 前端据此弹出/跳转登录 */
export class DatasetAuthError extends Error {
  constructor() {
    super("需要登录后下载");
    this.name = "DatasetAuthError";
  }
}

export async function listDatasets(): Promise<DatasetList> {
  return apiFetch<DatasetList>("/api/datasets");
}

export async function getDataset(id: string): Promise<DatasetDetail> {
  return apiFetch<DatasetDetail>(`/api/datasets/${encodeURIComponent(id)}`);
}

/**
 * 下载内置本地数据集文件。
 * 401（未登录/过期）抛 DatasetAuthError；其余错误抛普通 Error。
 */
export async function downloadDatasetFile(
  id: string,
  filename: string
): Promise<{ blob: Blob; filename: string }> {
  const path = `/api/datasets/${encodeURIComponent(id)}/files/${encodeURIComponent(filename)}`;

  let res = await authedFetch(path);
  if (res.status === 401) {
    const nt = await tryRefresh();
    if (nt) {
      res = await fetch(path, { headers: { Authorization: `Bearer ${nt}` } });
    }
  }
  if (res.status === 401 || res.status === 403) {
    throw new DatasetAuthError();
  }
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`下载失败（HTTP ${res.status}）：${text.slice(0, 120)}`);
  }
  const blob = await res.blob();
  if (blob.size === 0) throw new Error("下载文件为空");
  return { blob, filename };
}

/** 触发浏览器保存 blob（复用现有项目打包下载的同款做法） */
export function saveBlob(blob: Blob, filename: string): void {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

/** 是否当前持有登录态（用于按钮态判断，不替代后端鉴权） */
export function hasLoginToken(): boolean {
  return !!getAuthToken();
}

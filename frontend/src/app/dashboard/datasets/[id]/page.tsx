/**
 * scCloud v2 — 数据集详情页（整页）
 *
 *  - local    ：展示内置文件表，登录后站内下载；
 *  - external ：展示论文、GEO/GSA/浏览器等外链，新标签跳转。
 */
"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import AuthModal from "../../../components/AuthModal";
import { isGuest } from "../../../lib/api";
import {
  getDataset,
  downloadDatasetFile,
  saveBlob,
  hasLoginToken,
  DatasetAuthError,
  type DatasetDetail,
} from "../../../lib/datasets-api";

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div className="min-w-0">
      <span className="block text-[10px]" style={{ color: "var(--clr-text-faint)" }}>{label}</span>
      <span className="block truncate text-sm" style={{ color: "var(--clr-text-muted)" }}>{value}</span>
    </div>
  );
}

export default function DatasetDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const [authOpen, setAuthOpen] = useState(false);
  const [downloadError, setDownloadError] = useState<string | null>(null);
  const [id, setId] = useState("");
  const [ds, setDs] = useState<DatasetDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [downloading, setDownloading] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    params.then((p) => {
      setId(p.id);
      getDataset(p.id)
        .then((data) => { if (alive) setDs(data); })
        .catch((e) => { if (alive) setError(e instanceof Error ? e.message : "数据集不存在"); })
        .finally(() => { if (alive) setLoading(false); });
    });
    return () => { alive = false; };
  }, [params]);

  const handleDownload = async (filename: string) => {
    if (!hasLoginToken() || isGuest()) {
      setAuthOpen(true);
      return;
    }
    setDownloadError(null);
    setDownloading(filename);
    try {
      const { blob, filename: fname } = await downloadDatasetFile(id, filename);
      saveBlob(blob, fname);
    } catch (e) {
      if (e instanceof DatasetAuthError) {
        setAuthOpen(true);
      } else {
        setDownloadError(e instanceof Error ? e.message : "下载失败");
      }
    } finally {
      setDownloading(null);
    }
  };

  if (loading) {
    return <p className="text-sm" style={{ color: "var(--clr-text-muted)" }}>加载中…</p>;
  }
  if (error || !ds) {
    return (
      <div>
        <p className="text-sm" style={{ color: "var(--clr-danger)" }}>{error || "数据集不存在"}</p>
        <Link href="/dashboard/datasets" className="mt-3 inline-block text-sm" style={{ color: "var(--clr-amber)" }}>
          ← 返回数据集目录
        </Link>
      </div>
    );
  }

  return (
    <div className="animate-fade-in max-w-5xl">
      <Link href="/dashboard/datasets" className="inline-flex items-center gap-1 text-xs" style={{ color: "var(--clr-text-muted)" }}>
        ← 返回数据集目录
      </Link>

      <AuthModal open={authOpen} onClose={() => setAuthOpen(false)} defaultTab="login" />
      {downloadError && <p role="alert" className="mt-3 text-sm" style={{ color: "var(--clr-danger)" }}>{downloadError}</p>}

      {/* Hero */}
      <section
        className="mt-4 rounded-[var(--radius)] p-6"
        style={{ background: "var(--clr-bg-card)", border: "1px solid var(--clr-border)", boxShadow: "var(--shadow-sm)" }}
      >
        <div className="flex flex-wrap items-center gap-2 mb-3">
          <span
            className="px-2.5 py-0.5 rounded text-xs font-medium"
            style={{ background: "var(--clr-bg-alt)", color: "var(--clr-amber-dark)" }}
          >
            {ds.journal || "示例"}
            {ds.year ? ` · ${ds.year}` : ""}
          </span>
          {ds.mode === "local" ? (
            <span className="px-2.5 py-0.5 rounded text-xs font-medium" style={{ background: "var(--clr-gold-soft)", color: "var(--clr-amber-dark)" }}>
              内置样本 · 站内下载
            </span>
          ) : (
            <span className="px-2.5 py-0.5 rounded text-xs font-medium" style={{ background: "var(--clr-bg-alt)", color: "var(--clr-text-muted)" }}>
              公开研究数据 · 外链访问
            </span>
          )}
        </div>

        <h1 className="text-2xl font-bold" style={{ color: "var(--clr-text)", fontFamily: "var(--font-serif)" }}>
          {ds.name}
        </h1>
        <p className="mt-1 text-sm italic" style={{ color: "var(--clr-text-faint)" }}>{ds.en}</p>

        {ds.desc && (
          <p className="mt-4 text-sm leading-relaxed" style={{ color: "var(--clr-text-muted)" }}>{ds.desc}</p>
        )}

        <div className="mt-5 grid grid-cols-2 md:grid-cols-4 gap-x-4 gap-y-3">
          <Field label="细胞数" value={ds.cells || "—"} />
          <Field label="疾病" value={ds.disease || "—"} />
          <Field label="细胞类型" value={ds.cell || "—"} />
          <Field label="组织" value={ds.tissue || "—"} />
          <Field label="物种" value={ds.organism || "—"} />
          <Field label="测序技术" value={ds.platform || "—"} />
          <Field label="样本" value={ds.samples || "—"} />
          <Field label="编号" value={ds.acc || "—"} />
        </div>
      </section>

      {/* 内置文件下载 */}
      {ds.files && ds.files.length > 0 && (
        <section className="mt-6">
          <h2 className="mb-3 text-base font-semibold" style={{ color: "var(--clr-text)" }}>可下载文件</h2>
          <div
            className="rounded-[var(--radius)] overflow-hidden"
            style={{ background: "var(--clr-bg-card)", border: "1px solid var(--clr-border)" }}
          >
            {ds.files.map((f, i) => (
              <div
                key={f.name}
                className="flex items-center justify-between gap-4 px-4 py-3"
                style={{ borderTop: i === 0 ? "none" : "1px solid var(--clr-border)" }}
              >
                <div className="min-w-0">
                  <p className="text-sm font-medium truncate" style={{ color: "var(--clr-text)" }}>{f.name}</p>
                  <p className="text-xs" style={{ color: "var(--clr-text-faint)" }}>{f.desc}</p>
                </div>
                <button
                  onClick={() => handleDownload(f.name)}
                  disabled={downloading === f.name}
                  className="flex-shrink-0 px-4 py-2 rounded-lg text-sm font-medium text-white transition-opacity disabled:opacity-60"
                  style={{ background: "linear-gradient(135deg, var(--clr-amber-dark), var(--clr-amber))" }}
                >
                  {downloading === f.name ? "下载中…" : "下载"}
                </button>
              </div>
            ))}
          </div>
          <p className="mt-2 text-xs" style={{ color: "var(--clr-text-faint)" }}>
            内置文件需登录后下载；下载的 RDS 可在新建项目时作为上传数据直接分析。
          </p>
        </section>
      )}

      {/* 论文卡片 */}
      {ds.paper && (
        <section className="mt-6">
          <h2 className="mb-3 text-base font-semibold" style={{ color: "var(--clr-text)" }}>来源论文</h2>
          <div
            className="rounded-[var(--radius)] p-4"
            style={{ background: "var(--clr-bg-card)", border: "1px solid var(--clr-border)" }}
          >
            <p className="text-sm font-medium leading-snug" style={{ color: "var(--clr-text)" }}>{ds.paper}</p>
            {ds.doi && (
              <a
                href={`https://doi.org/${ds.doi}`}
                target="_blank"
                rel="noopener noreferrer"
                className="mt-1 inline-block text-xs"
                style={{ color: "var(--clr-amber)" }}
              >
                DOI: {ds.doi}
              </a>
            )}
          </div>
        </section>
      )}

      {/* 外链 */}
      {ds.links && ds.links.length > 0 && (
        <section className="mt-6">
          <h2 className="mb-3 text-base font-semibold" style={{ color: "var(--clr-text)" }}>数据来源与访问链接</h2>
          <div className="flex flex-col gap-2">
            {ds.links.map((link, i) => (
              <a
                key={i}
                href={link.u}
                target="_blank"
                rel="noopener noreferrer"
                className="flex items-center justify-between gap-3 px-4 py-3 rounded-[var(--radius)] transition-colors hover:bg-[var(--clr-surface-hover)]"
                style={{ background: "var(--clr-bg-card)", border: "1px solid var(--clr-border)" }}
              >
                <span className="text-sm" style={{ color: "var(--clr-text-muted)" }}>{link.t}</span>
                <span className="text-xs" style={{ color: "var(--clr-amber)" }}>新标签打开 ↗</span>
              </a>
            ))}
          </div>
          <p className="mt-2 text-xs" style={{ color: "var(--clr-text-faint)" }}>
            受控访问数据（EGA / EGA 类）需在对应平台提交使用申请后获取；请遵守原始研究的数据使用协议。
          </p>
        </section>
      )}
    </div>
  );
}

/**
 * scCloud v2 — 数据集目录列表页
 *
 *  - local    ：内置小样本，登录后站内下载；
 *  - external ：公开外链索引，跳转 GEO/GSA/论文/交互浏览器。
 * 搜索、疾病组与模式筛选均在前端完成。
 */
"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import {
  listDatasets,
  type DatasetSummary,
} from "../../lib/datasets-api";
import { IconDatabase } from "../../components/Icons";

type ModeFilter = "all" | "local" | "external";

export default function DatasetsPage() {
  const [items, setItems] = useState<DatasetSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [query, setQuery] = useState("");
  const [diseaseGroup, setDiseaseGroup] = useState<string>("all");
  const [mode, setMode] = useState<ModeFilter>("all");

  useEffect(() => {
    let alive = true;
    setLoading(true);
    listDatasets()
      .then((data) => {
        if (alive) setItems(data.datasets);
      })
      .catch((e) => {
        if (alive) setError(e instanceof Error ? e.message : "数据集加载失败");
      })
      .finally(() => {
        if (alive) setLoading(false);
      });
    return () => {
      alive = false;
    };
  }, []);

  const diseaseGroups = useMemo(() => {
    const set = new Set<string>();
    items.forEach((d) => d.disease_group && set.add(d.disease_group));
    return ["all", ...Array.from(set).sort()];
  }, [items]);

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    return items.filter((d) => {
      if (mode !== "all" && d.mode !== mode) return false;
      if (diseaseGroup !== "all" && d.disease_group !== diseaseGroup) return false;
      if (!q) return true;
      const hay = [d.name, d.en, d.disease, d.cell, d.tissue, d.journal, d.platform, d.samples]
        .filter(Boolean)
        .join(" ")
        .toLowerCase();
      return hay.includes(q);
    });
  }, [items, query, diseaseGroup, mode]);

  const localCount = items.filter((d) => d.mode === "local").length;
  const externalCount = items.filter((d) => d.mode === "external").length;

  return (
    <div className="animate-fade-in">
      {/* Hero */}
      <section className="mb-6">
        <div className="flex items-center gap-2 text-xs font-medium tracking-widest" style={{ color: "var(--clr-amber)" }}>
          <IconDatabase size={14} />
          DATASET CATALOG
        </div>
        <h1
          className="mt-2 text-2xl font-bold"
          style={{ color: "var(--clr-text)", fontFamily: "var(--font-serif)" }}
        >
          单细胞数据集目录
        </h1>
        <p className="mt-1 text-sm" style={{ color: "var(--clr-text-muted)" }}>
          内置示例样本可直接下载跑通流程；公开研究数据集提供原始数据库与论文外链，需按对应协议申请使用。
        </p>
        <div className="mt-4 flex flex-wrap gap-6">
          <Stat label="收录数据集" value={items.length} />
          <Stat label="内置样本" value={localCount} />
          <Stat label="公开外链" value={externalCount} />
        </div>
      </section>

      {/* 工具栏 */}
      <section
        className="mb-5 rounded-[var(--radius)] p-3 flex flex-wrap items-center gap-3"
        style={{ background: "var(--clr-bg-card)", border: "1px solid var(--clr-border)" }}
      >
        <input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="搜索名称、疾病、细胞类型、组织、期刊…"
          className="flex-1 min-w-[220px] px-3 py-2 text-sm rounded-lg outline-none"
          style={{ background: "var(--clr-bg-alt)", border: "1px solid var(--clr-border)", color: "var(--clr-text)" }}
        />
        <div className="flex items-center gap-1.5">
          <ModeChip active={mode === "all"} onClick={() => setMode("all")}>全部</ModeChip>
          <ModeChip active={mode === "local"} onClick={() => setMode("local")}>内置下载</ModeChip>
          <ModeChip active={mode === "external"} onClick={() => setMode("external")}>公开外链</ModeChip>
        </div>
      </section>

      {/* 疾病组筛选 */}
      {diseaseGroups.length > 1 && (
        <div className="mb-5 flex flex-wrap gap-1.5">
          {diseaseGroups.map((g) => (
            <button
              key={g}
              onClick={() => setDiseaseGroup(g)}
              className="px-3 py-1 rounded-full text-xs transition-colors"
              style={{
                background: diseaseGroup === g ? "var(--clr-amber)" : "var(--clr-bg-card)",
                color: diseaseGroup === g ? "#fff" : "var(--clr-text-muted)",
                border: "1px solid var(--clr-border)",
              }}
            >
              {g === "all" ? "全部疾病" : g}
            </button>
          ))}
        </div>
      )}

      {/* 列表 */}
      {loading && <p className="text-sm" style={{ color: "var(--clr-text-muted)" }}>加载中…</p>}
      {error && (
        <p className="text-sm" style={{ color: "var(--clr-danger)" }}>数据集加载失败：{error}</p>
      )}
      {!loading && !error && filtered.length === 0 && (
        <p className="text-sm" style={{ color: "var(--clr-text-faint)" }}>没有匹配的数据集。</p>
      )}

      <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4">
        {filtered.map((d) => (
          <DatasetCard key={d.id} dataset={d} />
        ))}
      </div>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: number }) {
  return (
    <div>
      <div className="text-2xl font-bold" style={{ color: "var(--clr-text)", fontFamily: "var(--font-serif)" }}>
        {value}
      </div>
      <div className="text-xs" style={{ color: "var(--clr-text-faint)" }}>{label}</div>
    </div>
  );
}

function ModeChip({ active, onClick, children }: { active: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <button
      onClick={onClick}
      className="px-3 py-1.5 rounded-lg text-xs font-medium transition-colors"
      style={{
        background: active ? "var(--clr-dark)" : "var(--clr-bg-alt)",
        color: active ? "#fff" : "var(--clr-text-muted)",
      }}
    >
      {children}
    </button>
  );
}

function DatasetCard({ dataset: d }: { dataset: DatasetSummary }) {
  return (
    <Link
      href={`/dashboard/datasets/${d.id}`}
      className="group flex flex-col rounded-[var(--radius)] p-4 transition-all hover:-translate-y-0.5"
      style={{
        background: "var(--clr-bg-card)",
        border: "1px solid var(--clr-border)",
        boxShadow: "var(--shadow-sm)",
      }}
    >
      <div className="flex items-center justify-between gap-2 mb-2">
        <div className="flex items-center gap-1.5">
          <span
            className="px-2 py-0.5 rounded text-[11px] font-medium"
            style={{ background: "var(--clr-bg-alt)", color: "var(--clr-amber-dark)" }}
          >
            {d.journal || "示例"}
            {d.year ? ` · ${d.year}` : ""}
          </span>
          {d.mode === "local" ? (
            <span
              className="px-2 py-0.5 rounded text-[11px] font-medium"
              style={{ background: "var(--clr-gold-soft)", color: "var(--clr-amber-dark)" }}
            >
              内置下载
            </span>
          ) : (
            <span
              className="px-2 py-0.5 rounded text-[11px] font-medium"
              style={{ background: "var(--clr-bg-alt)", color: "var(--clr-text-muted)" }}
            >
              公开外链
            </span>
          )}
        </div>
        {d.quality && (
          <span title="高质量整理" className="text-[11px]" style={{ color: "var(--clr-amber)" }}>◆</span>
        )}
      </div>

      <h3 className="text-sm font-semibold leading-snug" style={{ color: "var(--clr-text)" }}>
        {d.name}
      </h3>
      <p className="mt-0.5 text-xs italic" style={{ color: "var(--clr-text-faint)" }}>{d.en}</p>

      <div className="mt-3 grid grid-cols-2 gap-x-3 gap-y-1.5 text-xs">
        <Meta label="细胞数" value={d.cells || "—"} />
        <Meta label="疾病" value={d.disease || "—"} />
        <Meta label="细胞类型" value={d.cell || "—"} />
        <Meta label="组织" value={d.tissue || "—"} />
      </div>

      <div
        className="mt-3 pt-3 text-xs font-medium transition-colors"
        style={{ borderTop: "1px solid var(--clr-border)", color: "var(--clr-amber)" }}
      >
        查看详情 →
      </div>
    </Link>
  );
}

function Meta({ label, value }: { label: string; value: string }) {
  return (
    <div className="min-w-0">
      <span className="block text-[10px]" style={{ color: "var(--clr-text-faint)" }}>{label}</span>
      <span className="block truncate" style={{ color: "var(--clr-text-muted)" }}>{value}</span>
    </div>
  );
}

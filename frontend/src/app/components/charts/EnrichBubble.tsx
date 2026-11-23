/**
 * scCloud v2 — 富集分析气泡图
 *
 * 对应旧系统 plotOutput("enrichPlot")
 * 旧实现: Shiny renderPlot → dotplot(enrichResult)
 * 新实现: clusterProfiler JSON 结果 → Plotly bubble chart
 *
 * 数据格式:
 * {
 *   terms: string[],       // GO/KEGG 通路名
 *   gene_ratio: number[],  // 基因比例
 *   p_adjust: number[],    // 校正后 P 值
 *   count: number[],       // 基因数
 *   category: string[],    // BP/CC/MF / KEGG pathway
 * }
 */
"use client";

import dynamic from "next/dynamic";
import { useMemo } from "react";

const Plot = dynamic(() => import("react-plotly.js"), { ssr: false });

export interface EnrichData {
  terms: string[];
  gene_ratio: number[];
  p_adjust: number[];
  count: number[];
  category?: string[];
}

interface EnrichBubbleProps {
  data: EnrichData | null;
  title?: string;
  height?: number;
}

export default function EnrichBubble({
  data,
  title = "富集分析",
  height = 500,
}: EnrichBubbleProps) {
  const trace = useMemo(() => {
    if (!data || !data.terms?.length) return null;

    /* Truncate long term names */
    const labels = data.terms.map((t) =>
      t.length > 40 ? t.slice(0, 38) + "…" : t
    );

    /* p_adjust <= 0 时避免 -log10(0) 得到 Infinity */
    const finiteLogs = data.p_adjust
      .map((p) => (Number.isFinite(p) && p > 0 ? -Math.log10(p) : null))
      .filter((v): v is number => v !== null);
    const maxFinite = finiteLogs.length > 0 ? Math.max(...finiteLogs) : 10;
    const zeroCap = Math.min(300, Math.ceil(maxFinite + 1));
    const colors = data.p_adjust.map((p) =>
      Number.isFinite(p) && p > 0 ? Math.min(300, -Math.log10(p)) : zeroCap
    );

    /* 将 count 平方根归一化映射到 [8, 28] 像素，避免大基因集气泡遮挡整图 */
    const validCounts = data.count.filter((c) => Number.isFinite(c) && c >= 0);
    const minCount = validCounts.length > 0 ? Math.min(...validCounts) : 0;
    const maxCount = validCounts.length > 0 ? Math.max(...validCounts) : 0;
    const sqrtMin = Math.sqrt(minCount);
    const sqrtMax = Math.sqrt(maxCount);
    const sizes = data.count.map((c) => {
      const val = Number.isFinite(c) && c >= 0 ? c : minCount;
      if (sqrtMax <= sqrtMin) return 16;
      const ratio = (Math.sqrt(val) - sqrtMin) / (sqrtMax - sqrtMin);
      return Number((8 + ratio * 20).toFixed(1));
    });

    return {
      x: data.gene_ratio,
      y: labels,
      mode: "markers" as const,
      type: "scatter" as const,
      marker: {
        size: sizes,
        color: colors,
        colorscale: "YlOrBr",
        colorbar: {
          title: {
            text: "-log₁₀(p.adj)",
            font: { size: 11, color: "#78716c" },
          },
          tickfont: { size: 11, color: "#78716c" },
          thickness: 12,
          len: 0.5,
        },
      },
      text: data.terms.map(
        (t, i) => {
          const gr = Number.isFinite(data.gene_ratio[i]) ? data.gene_ratio[i].toFixed(3) : "-";
          const pa = Number.isFinite(data.p_adjust[i]) ? data.p_adjust[i].toExponential(2) : "-";
          return `${t}<br>Gene Ratio: ${gr}<br>Count: ${data.count[i] ?? "-"}<br>p.adj: ${pa}`;
        }
      ),
      hovertemplate: "%{text}<extra></extra>",
    };
  }, [data]);

  if (!data) {
    return (
      <div
        className="flex items-center justify-center bg-stone-900/50 rounded-xl border border-stone-800"
        style={{ height }}
      >
        <div className="text-center text-stone-600">
          <div className="text-3xl mb-2">🔗</div>
          <p className="text-xs">{title}</p>
          <p className="text-[11px] mt-1">等待数据加载</p>
        </div>
      </div>
    );
  }

  return (
    <Plot
      data={trace ? [trace] : []}
      layout={{
        height,
        title: {
          text: title,
          font: { color: "#44403c", size: 14 },
        },
        paper_bgcolor: "transparent",
        plot_bgcolor: "transparent",
        font: { color: "#57534e", family: "Inter, sans-serif", size: 11 },
        xaxis: {
          title: { text: "Gene Ratio" },
          gridcolor: "rgba(168, 162, 158, 0.25)",
          zerolinecolor: "rgba(168, 162, 158, 0.3)",
        },
        yaxis: {
          autorange: "reversed",
          gridcolor: "rgba(168, 162, 158, 0.2)",
        },
        margin: { l: 200, r: 30, t: 40, b: 50 },
        showlegend: false,
      }}
      config={{ responsive: true, displaylogo: false, displayModeBar: true }}
      style={{ width: "100%" }}
    />
  );
}

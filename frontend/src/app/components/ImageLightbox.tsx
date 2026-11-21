/**
 * scCloud v2 — 高清科研图表灯箱弹窗组件
 * 支持鼠标滚轮/按钮缩放 (0.5x ~ 5x)、左键拖拽平移、双击切换 1x/2x、Esc/遮罩关闭与下载。
 */
"use client";

import React, { useCallback, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";

interface ImageLightboxProps {
  src: string;
  alt?: string;
  open: boolean;
  onClose: () => void;
  downloadFilename?: string;
}

const MIN_SCALE = 0.5;
const MAX_SCALE = 5;
const SCALE_STEP = 0.25;

export default function ImageLightbox({
  src,
  alt = "科研图表预览",
  open,
  onClose,
  downloadFilename,
}: ImageLightboxProps) {
  const [scale, setScale] = useState(1);
  const [pan, setPan] = useState({ x: 0, y: 0 });
  const [dragging, setDragging] = useState(false);

  const stageRef = useRef<HTMLDivElement>(null);
  const dragStartRef = useRef<{ x: number; y: number; panX: number; panY: number } | null>(null);
  const movedRef = useRef(false);

  const resetView = useCallback(() => {
    setScale(1);
    setPan({ x: 0, y: 0 });
  }, []);

  // 打开或切换图片时重置缩放和平移状态
  useEffect(() => {
    if (open) {
      resetView();
    }
  }, [open, src, resetView]);

  // Esc 关闭 + 锁定页面滚动
  useEffect(() => {
    if (!open) return;
    const prevOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        onClose();
      } else if (e.key === "+" || e.key === "=") {
        setScale((s) => Math.min(MAX_SCALE, Number((s + SCALE_STEP).toFixed(2))));
      } else if (e.key === "-") {
        setScale((s) => Math.max(MIN_SCALE, Number((s - SCALE_STEP).toFixed(2))));
      } else if (e.key === "0") {
        resetView();
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => {
      document.body.style.overflow = prevOverflow;
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, [open, onClose, resetView]);

  // 使用非 passive 的 wheel 监听以阻止背景页面滚动
  useEffect(() => {
    const el = stageRef.current;
    if (!open || !el) return;

    const handleWheel = (e: WheelEvent) => {
      e.preventDefault();
      const delta = e.deltaY < 0 ? 0.2 : -0.2;
      setScale((prev) => {
        const next = Math.max(MIN_SCALE, Math.min(MAX_SCALE, Number((prev + delta).toFixed(2))));
        return next;
      });
    };

    el.addEventListener("wheel", handleWheel, { passive: false });
    return () => el.removeEventListener("wheel", handleWheel);
  }, [open]);

  const handleMouseDown = (e: React.MouseEvent) => {
    if (e.button !== 0) return;
    movedRef.current = false;
    dragStartRef.current = {
      x: e.clientX,
      y: e.clientY,
      panX: pan.x,
      panY: pan.y,
    };
    setDragging(true);
  };

  const handleMouseMove = (e: React.MouseEvent) => {
    const start = dragStartRef.current;
    if (!start) return;
    const dx = e.clientX - start.x;
    const dy = e.clientY - start.y;
    if (Math.abs(dx) > 3 || Math.abs(dy) > 3) {
      movedRef.current = true;
    }
    setPan({ x: start.panX + dx, y: start.panY + dy });
  };

  const handleMouseUp = () => {
    dragStartRef.current = null;
    setDragging(false);
  };

  const handleBackdropClick = (e: React.MouseEvent<HTMLDivElement>) => {
    if (movedRef.current) {
      movedRef.current = false;
      return;
    }
    if (e.target === e.currentTarget) {
      onClose();
    }
  };

  const handleDoubleClick = (e: React.MouseEvent) => {
    e.stopPropagation();
    if (Math.abs(scale - 1) < 0.05) {
      setScale(2);
    } else {
      resetView();
    }
  };

  if (!open || typeof document === "undefined") return null;

  const safeDownloadName =
    downloadFilename ||
    `${(alt || "figure").replace(/[^\w\u4e00-\u9fa5.-]+/g, "_").replace(/^_+|_+$/g, "") || "figure"}.png`;

  return createPortal(
    <div
      className="fixed inset-0 z-[10000] flex flex-col select-none"
      style={{
        background: "rgba(15, 12, 10, 0.85)",
        backdropFilter: "blur(4px)",
      }}
      role="dialog"
      aria-modal="true"
      aria-label={alt}
      onMouseMove={handleMouseMove}
      onMouseUp={handleMouseUp}
      onMouseLeave={handleMouseUp}
    >
      {/* 顶部工具栏 */}
      <div
        className="flex items-center justify-between gap-3 px-4 py-2.5 text-white shrink-0"
        style={{
          background: "rgba(20, 17, 15, 0.72)",
          borderBottom: "1px solid rgba(255, 255, 255, 0.12)",
        }}
      >
        <div className="min-w-0 flex-1">
          <p className="text-xs font-medium truncate" title={alt}>
            {alt}
          </p>
          <p className="text-[10px] text-stone-400">
            滚轮缩放 · 拖拽平移 · 双击切换 1:1 / 2:1 · Esc 关闭
          </p>
        </div>

        <div className="flex items-center gap-1.5 shrink-0">
          <button
            type="button"
            onClick={() => setScale((s) => Math.max(MIN_SCALE, Number((s - SCALE_STEP).toFixed(2))))}
            disabled={scale <= MIN_SCALE}
            className="px-2.5 py-1 rounded text-xs font-medium bg-white/10 hover:bg-white/20 disabled:opacity-40 transition-colors"
            title="缩小 (-)"
          >
            −
          </button>
          <span
            className="min-w-[52px] text-center text-xs tabular-nums font-medium text-stone-200"
            style={{ fontFamily: "var(--font-mono)" }}
          >
            {Math.round(scale * 100)}%
          </span>
          <button
            type="button"
            onClick={() => setScale((s) => Math.min(MAX_SCALE, Number((s + SCALE_STEP).toFixed(2))))}
            disabled={scale >= MAX_SCALE}
            className="px-2.5 py-1 rounded text-xs font-medium bg-white/10 hover:bg-white/20 disabled:opacity-40 transition-colors"
            title="放大 (+)"
          >
            +
          </button>
          <button
            type="button"
            onClick={resetView}
            className="px-2.5 py-1 rounded text-xs font-medium bg-white/10 hover:bg-white/20 transition-colors"
            title="恢复原始比例 (0)"
          >
            1:1
          </button>
          <a
            href={src}
            download={safeDownloadName}
            className="inline-flex items-center gap-1 px-2.5 py-1 rounded text-xs font-medium bg-white/10 hover:bg-white/20 transition-colors"
            title="下载当前图片"
            onClick={(e) => e.stopPropagation()}
          >
            <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
              <polyline points="7 10 12 15 17 10" />
              <line x1="12" y1="15" x2="12" y2="3" />
            </svg>
            下载
          </a>
          <button
            type="button"
            onClick={onClose}
            className="ml-1 w-8 h-8 inline-flex items-center justify-center rounded-lg bg-white/10 hover:bg-white/20 transition-colors text-base"
            title="关闭 (Esc)"
            aria-label="关闭大图预览"
          >
            ×
          </button>
        </div>
      </div>

      {/* 图像舞台 */}
      <div
        ref={stageRef}
        className="flex-1 overflow-hidden flex items-center justify-center p-4"
        onClick={handleBackdropClick}
      >
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          src={src}
          alt={alt}
          draggable={false}
          onMouseDown={handleMouseDown}
          onDoubleClick={handleDoubleClick}
          className="max-w-[92vw] max-h-[82vh] object-contain rounded shadow-2xl bg-white"
          style={{
            transform: `translate(${pan.x}px, ${pan.y}px) scale(${scale})`,
            transformOrigin: "center center",
            transition: dragging ? "none" : "transform 0.12s ease-out",
            cursor: dragging ? "grabbing" : scale > 1 ? "grab" : "zoom-in",
          }}
        />
      </div>
    </div>,
    document.body
  );
}

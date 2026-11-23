"use client";

import React, { useEffect } from "react";
import { createPortal } from "react-dom";

interface ConfirmDialogProps {
  open: boolean;
  title: string;
  message: string;
  confirmLabel?: string;
  cancelLabel?: string;
  danger?: boolean;
  loading?: boolean;
  onConfirm: () => void | Promise<void>;
  onCancel: () => void;
}

export default function ConfirmDialog({
  open,
  title,
  message,
  confirmLabel = "确定",
  cancelLabel = "取消",
  danger = false,
  loading = false,
  onConfirm,
  onCancel,
}: ConfirmDialogProps) {
  useEffect(() => {
    if (!open) return;
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape" && !loading) {
        onCancel();
      }
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [open, loading, onCancel]);

  if (!open || typeof document === "undefined") return null;

  return createPortal(
    <div
      className="fixed inset-0 z-[70] flex items-center justify-center p-4"
      role="dialog"
      aria-modal="true"
      aria-labelledby="confirm-dialog-title"
    >
      <div
        className="absolute inset-0"
        style={{ background: "rgba(30,27,24,0.45)", backdropFilter: "blur(2px)" }}
        onClick={() => {
          if (!loading) onCancel();
        }}
      />
      <div
        className="relative w-full max-w-md rounded-xl shadow-2xl p-6 animate-fade-in-fast"
        style={{
          background: "var(--clr-bg-card)",
          border: "1px solid var(--clr-border)",
        }}
      >
        <div className="flex items-start gap-3 mb-4">
          <div
            className="w-9 h-9 rounded-full flex items-center justify-center shrink-0"
            style={{
              background: danger ? "rgba(184,84,80,0.1)" : "rgba(200,96,25,0.1)",
              color: danger ? "var(--clr-danger)" : "var(--clr-amber)",
            }}
          >
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <circle cx="12" cy="12" r="10" />
              <line x1="12" y1="8" x2="12" y2="12" />
              <line x1="12" y1="16" x2="12.01" y2="16" />
            </svg>
          </div>
          <div className="min-w-0 flex-1">
            <h3
              id="confirm-dialog-title"
              className="text-base font-bold"
              style={{ fontFamily: "var(--font-serif)", color: "var(--clr-dark-deep)" }}
            >
              {title}
            </h3>
            <p className="text-xs mt-1.5 leading-relaxed" style={{ color: "var(--clr-text-muted)" }}>
              {message}
            </p>
          </div>
        </div>

        <div className="flex justify-end gap-2.5 pt-2">
          <button
            type="button"
            disabled={loading}
            onClick={onCancel}
            className="px-4 py-2 rounded-lg text-xs font-medium transition-colors disabled:opacity-50"
            style={{
              border: "1px solid var(--clr-border)",
              background: "var(--clr-bg-alt)",
              color: "var(--clr-text-muted)",
              cursor: loading ? "not-allowed" : "pointer",
            }}
          >
            {cancelLabel}
          </button>
          <button
            type="button"
            disabled={loading}
            onClick={onConfirm}
            className="px-4 py-2 rounded-lg text-xs font-semibold text-white transition-all disabled:opacity-50"
            style={{
              background: danger ? "var(--clr-danger)" : "var(--clr-amber)",
              cursor: loading ? "not-allowed" : "pointer",
            }}
          >
            {loading ? "处理中..." : confirmLabel}
          </button>
        </div>
      </div>
    </div>,
    document.body
  );
}

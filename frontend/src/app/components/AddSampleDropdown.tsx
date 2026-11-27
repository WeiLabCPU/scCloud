/**
 * 添加样本下拉菜单
 * 两个选项：本地上传 / 从项目文件选择
 * 下拉菜单关闭后，模态框仍保持挂载
 */
"use client";

import React, { useCallback, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import FileUploadModal from "./FileUploadModal";
import ProjectFilesModal from "./ProjectFilesModal";

interface UploadedFile {
  name: string;
  path: string;
  metadata_columns?: string[];
  n_cells?: number;
  n_genes?: number;
  n_rows?: number;
  n_cols?: number;
  file_size_mb?: number;
  samples?: { name: string; cell_count: number }[];
  ensembl_version?: string;
}

interface AddSampleDropdownProps {
  isOpen: boolean;
  onClose: () => void;
  onFileUploaded: (file: UploadedFile) => void;
  onFilesSelected: (files: UploadedFile[]) => void;
  projectId: number;
  token: string;
  existingPaths: string[];
  sampleGroups?: Record<string, string>;
  triggerRef?: React.RefObject<HTMLElement | null>;
}

export default function AddSampleDropdown({
  isOpen,
  onClose,
  onFileUploaded,
  onFilesSelected,
  projectId,
  token,
  existingPaths,
  sampleGroups,
  triggerRef,
}: AddSampleDropdownProps) {
  const ref = useRef<HTMLDivElement>(null);
  const [showUpload, setShowUpload] = useState(false);
  const [showProjectFiles, setShowProjectFiles] = useState(false);
  const [menuPos, setMenuPos] = useState<{ top: number; left: number; openAbove: boolean } | null>(null);

  // 有模态框打开时，不渲染下拉菜单，但组件保持挂载
  const hasModal = showUpload || showProjectFiles;

  const updateMenuPosition = useCallback(() => {
    const el = triggerRef?.current;
    if (!el) {
      setMenuPos(null);
      return;
    }
    const rect = el.getBoundingClientRect();
    const openAbove = window.innerHeight - rect.bottom < 110;
    const clampedLeft = Math.max(104, Math.min(window.innerWidth - 104, rect.left + rect.width / 2));
    setMenuPos({
      top: openAbove ? rect.top - 6 : rect.bottom + 6,
      left: clampedLeft,
      openAbove,
    });
  }, [triggerRef]);

  useEffect(() => {
    if (!isOpen || hasModal) {
      setMenuPos(null);
      return;
    }
    updateMenuPosition();

    const handleClick = (e: MouseEvent) => {
      const target = e.target as Node;
      if (ref.current && !ref.current.contains(target) && !(triggerRef?.current && triggerRef.current.contains(target))) {
        onClose();
      }
    };
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("mousedown", handleClick);
    document.addEventListener("keydown", handleKeyDown);
    window.addEventListener("scroll", updateMenuPosition, true);
    window.addEventListener("resize", updateMenuPosition);
    return () => {
      document.removeEventListener("mousedown", handleClick);
      document.removeEventListener("keydown", handleKeyDown);
      window.removeEventListener("scroll", updateMenuPosition, true);
      window.removeEventListener("resize", updateMenuPosition);
    };
  }, [isOpen, onClose, hasModal, triggerRef, updateMenuPosition]);

  const menuContent = (
    <>
      <button
        type="button"
        onClick={() => setShowUpload(true)}
        className="w-full flex items-center gap-2.5 px-3 py-2.5 text-xs transition-colors hover:bg-black/5 cursor-pointer"
        style={{ borderBottom: "1px solid var(--clr-border)", color: "var(--clr-text)" }}
      >
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="var(--clr-amber)" strokeWidth="2" strokeLinecap="round"><path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4M17 8l-5-5-5 5M12 3v12" /></svg>
        本地上传
      </button>
      <button
        type="button"
        onClick={() => setShowProjectFiles(true)}
        className="w-full flex items-center gap-2.5 px-3 py-2.5 text-xs transition-colors hover:bg-black/5 cursor-pointer"
        style={{ color: "var(--clr-text)" }}
      >
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="var(--clr-amber)" strokeWidth="2" strokeLinecap="round"><path d="M22 19a2 2 0 01-2 2H4a2 2 0 01-2-2V5a2 2 0 012-2h5l2 3h9a2 2 0 012 2z" /></svg>
        从项目文件选择
      </button>
    </>
  );

  return (
    <>
      {/* Dropdown menu — 仅在 isOpen 且没有模态框打开时显示 */}
      {isOpen && !hasModal && (
        menuPos && typeof document !== "undefined" ? (
          createPortal(
            <div
              ref={ref}
              className="fixed w-48 rounded-lg overflow-hidden z-[60] animate-fade-in-fast"
              style={{
                top: menuPos.top,
                left: menuPos.left,
                transform: menuPos.openAbove ? "translate(-50%, -100%)" : "translateX(-50%)",
                background: "var(--clr-bg-card)",
                border: "1px solid var(--clr-border)",
                boxShadow: "var(--shadow-lg, 0 10px 25px rgba(0,0,0,0.12))",
              }}
            >
              {menuContent}
            </div>,
            document.body
          )
        ) : !triggerRef ? (
          <div
            ref={ref}
            className="absolute top-full left-1/2 -translate-x-1/2 mt-1 w-48 rounded-lg overflow-hidden z-50 animate-fade-in-fast"
            style={{
              background: "var(--clr-bg-card)",
              border: "1px solid var(--clr-border)",
              boxShadow: "var(--shadow-lg, 0 10px 25px rgba(0,0,0,0.12))",
            }}
          >
            {menuContent}
          </div>
        ) : null
      )}

      {/* Upload modal */}
      <FileUploadModal
        isOpen={showUpload}
        onClose={() => { setShowUpload(false); onClose(); }}
        sampleGroups={sampleGroups}
        onFileUploaded={(file) => {
          onFileUploaded({
            name: file.name,
            path: file.path,
            metadata_columns: file.metadata_columns,
            n_cells: file.n_cells,
            n_genes: file.n_genes,
            n_rows: file.n_rows,
            n_cols: file.n_cols,
            file_size_mb: file.file_size_mb,
            samples: file.samples,
            ensembl_version: file.ensembl_version,
          });
        }}
        projectId={projectId}
        token={token}
      />

      {/* Project files modal */}
      <ProjectFilesModal
        isOpen={showProjectFiles}
        onClose={() => { setShowProjectFiles(false); onClose(); }}
        projectId={projectId}
        existingPaths={existingPaths}
        onFilesSelected={(results) => {
          const files: UploadedFile[] = results.map((r) => ({
            name: r.inspect.filename,
            path: r.path,
            metadata_columns: r.inspect.metadata_columns,
            n_cells: r.inspect.n_cells,
            n_genes: r.inspect.n_genes,
            n_rows: r.inspect.n_rows,
            n_cols: r.inspect.n_cols,
            file_size_mb: r.inspect.file_size_mb,
            samples: r.inspect.samples,
            ensembl_version: r.inspect.ensembl_version,
          }));
          onFilesSelected(files);
        }}
      />
    </>
  );
}

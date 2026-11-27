# =====================================================================
# scCloud v2 — SCENIC 转录因子调控分析
# 来源: run_SCENIC.R (SCENIC 1.3.1 全流程脚本)
# 移植原则: 保留原脚本的算法参数，去掉命令行参数解析与硬编码路径，
#           改为接收 Seurat 对象 + 输出目录，供 plumber.R 的 /scenic 端点调用
#
# 输入: 已注释的 Seurat 对象（含 CellType 列）
# 输出: regulon AUC 矩阵、二进制矩阵、可视化图、regulon 清单 CSV
# =====================================================================

# 保持 AUCell 支持的矩阵类型；对稀疏矩阵直接 +1 会生成 dgeMatrix。
scenic_logcounts <- function(exprMat) {
  if (inherits(exprMat, "CsparseMatrix")) {
    result <- as(exprMat, "dgCMatrix")
    result@x <- log2(result@x + 1)
    return(result)
  }
  as.matrix(log2(exprMat + 1))
}

#' SCENIC 转录因子调控分析
#'
#' @param pro     Seurat 对象（需含 RNA assay 的 counts 层，且已完成注释含 CellType）
#' @param outdir  输出目录
#' @param ref     参考基因组: hg38 / hg19 / mm10 / mm9
#' @param nCores  并行核数
#' @param dbDir   cisTarget 数据库目录
#' @param maxCells 推断 regulon 时抽取的最大细胞数；默认 5000；仅限制网络推断，AUCell 仍对全部细胞评分
#' @param progress_callback 进度回调函数 function(pct, msg)
#' @return list(plot_path, stat_plot_path, heatmap_path, table_path, stats, scenic_data)
RunScenic <- function(pro, outdir, ref = "hg38", nCores = 8,
                      dbDir = "/app/data/cistarget", maxCells = 5000,
                      plot_format = "png",
                      progress_callback = NULL) {

  if (length(maxCells) != 1L || !is.finite(maxCells) || maxCells < 1 || maxCells != floor(maxCells)) {
    stop("max_cells 必须为正整数")
  }
  available_cores <- parallel::detectCores()
  if (is.na(available_cores)) available_cores <- 1L
  if (length(nCores) != 1L || !is.finite(nCores) || nCores < 1) stop("n_cores 必须为正整数")
  nCores <- min(as.integer(nCores), available_cores)

  send_msg <- function(pct, msg) {
    if (!is.null(progress_callback)) progress_callback(pct, msg)
    else message(sprintf("[%d%%] %s", pct, msg))
  }

  suppressMessages({
    library(SCENIC)
    library(RcisTarget)
    library(GENIE3)
    library(AUCell)
    library(Seurat)
    library(dplyr)
    library(pheatmap)
    library(ggplot2)
  })

  # -------------------------------------------------------------------
  # 兼容补丁：SCENIC 1.3.1 内部 checkAnnots() 硬编码数据库索引列为 "features"，
  # 而新版 RcisTarget(1.29+) 的 hg38/mm10 数据库用 "motifs" 列作索引，
  # 不改的话 initializeScenic 会报 "Column `features` doesn't exist"。
  # 这里在运行时替换该内部函数，保持其余逻辑不变。
  # -------------------------------------------------------------------
  local({
    if (isTRUE(getOption("scc_scenic_patched"))) return(invisible(NULL))
    patched <- function(object, motifAnnot) {
      allFeaturesInAnnot <- unlist(motifAnnot[, 1])
      featuresWithAnnot <- lapply(getDatabases(object), function(dbFile) {
        rnktype <- "motifs"
        nRnks <- getRanking(RcisTarget::importRankings(dbFile, columns = rnktype))
        nRnks <- dplyr::pull(nRnks, rnktype)
        length(intersect(allFeaturesInAnnot, nRnks)) /
          length(unique(c(allFeaturesInAnnot, nRnks)))
      })
      featuresWithAnnot
    }
    environment(patched) <- asNamespace("SCENIC")
    tryCatch({
      assignInNamespace("checkAnnots", patched, ns = "SCENIC")
      options(scc_scenic_patched = TRUE)
      message("[SCENIC] checkAnnots patched for RcisTarget 'motifs' index")
    }, error = function(e) message("[SCENIC] patch failed: ", e$message))
  })

  dir.create(outdir, recursive = TRUE, showWarnings = FALSE)
  int_dir <- file.path(outdir, "int")
  dir.create(int_dir, recursive = TRUE, showWarnings = FALSE)

  # SCENIC 内部用相对路径（int/、output/）读写中间文件，
  # 必须把工作目录切到输出目录，否则文件会散落到进程当前目录，
  # 后续按 int/3.4_regulonAUC.Rds 读取时会找不到
  old_wd <- getwd()
  on.exit(setwd(old_wd), add = TRUE)
  setwd(outdir)

  # -------------------------------------------------------------------
  # 1. 提取表达矩阵（counts，与原脚本一致）
  # -------------------------------------------------------------------
  send_msg(3, "提取表达矩阵...")
  if (inherits(pro@assays$RNA, "Assay5")) {
    tryCatch({
      pro@assays$RNA <- JoinLayers(pro@assays$RNA)
    }, error = function(e) message("[SCENIC] JoinLayers skipped: ", e$message))
  }
  exprMat <- GetAssayData(pro, assay = "RNA", layer = "counts")

  # -------------------------------------------------------------------
  # 2. 基因名标准化（去版本号 + 转符号 + 去重）
  #    对应原脚本 convert_gene_ids()：ENSEMBL ID 转基因符号，已是符号则原样保留
  # -------------------------------------------------------------------
  rownames(exprMat) <- gsub("\\..*$", "", rownames(exprMat))
  gene_ids <- rownames(exprMat)

  if (any(grepl("^ENSG", gene_ids))) {
    suppressMessages(library(org.Hs.eg.db))
    org_db <- org.Hs.eg.db
    is_ensembl <- grepl("^ENSG", gene_ids)
  } else if (any(grepl("^ENSMUSG", gene_ids))) {
    suppressMessages(library(org.Mm.eg.db))
    org_db <- org.Mm.eg.db
    is_ensembl <- grepl("^ENSMUSG", gene_ids)
  } else {
    is_ensembl <- rep(FALSE, length(gene_ids))
  }

  if (any(is_ensembl)) {
    gene_symbols <- gene_ids
    suppressMessages({
      converted <- AnnotationDbi::mapIds(org_db,
                                         keys = gene_ids[is_ensembl],
                                         column = "SYMBOL",
                                         keytype = "ENSEMBL",
                                         multiVals = "first")
    })
    gene_symbols[is_ensembl] <- converted
    keep <- !is.na(gene_symbols) & gene_symbols != ""
    exprMat <- exprMat[keep, , drop = FALSE]
    rownames(exprMat) <- gene_symbols[keep]
  }

  if (any(duplicated(rownames(exprMat)))) {
    gene_means <- if (inherits(exprMat, "sparseMatrix")) Matrix::rowMeans(exprMat) else rowMeans(exprMat)
    exprMat <- exprMat[order(gene_means, decreasing = TRUE), , drop = FALSE]
    exprMat <- exprMat[!duplicated(rownames(exprMat)), , drop = FALSE]
  }

  # -------------------------------------------------------------------
  # 3. 在稀疏矩阵上抽样，仅将网络推断所需子集稠密化
  # -------------------------------------------------------------------
  if (is.finite(maxCells) && ncol(exprMat) > maxCells) {
    send_msg(6, sprintf("细胞数 %d 超过 %d，抽样用于 regulon 推断...", ncol(exprMat), maxCells))
    set.seed(123)
    sub_cells <- sample(colnames(exprMat), maxCells)
    exprMat_sub <- exprMat[, sub_cells, drop = FALSE]
  } else {
    exprMat_sub <- exprMat
  }

  # -------------------------------------------------------------------
  # 4. 初始化 SCENIC 环境（挑选 cisTarget 数据库 + motif 注释）
  # -------------------------------------------------------------------
  exprMat_sub <- as.matrix(exprMat_sub)
  send_msg(10, "初始化 SCENIC 环境...")
  mydbs <- list.files(dbDir, pattern = paste0("^", ref, ".*mc9nr.*[.]genes_vs_motifs[.]rankings[.]feather$"))
  if (length(mydbs) == 0) {
    stop(paste0("未找到 ", ref, " 的 cisTarget 数据库文件（目录: ", dbDir,
                "）。请先下载并挂载对应物种的数据库。"))
  }
  names(mydbs) <- sapply(strsplit(mydbs, "_|-|__"), function(x) paste(x[1:4], collapse = "_"))

  if (ref %in% c("hg19", "hg38")) {
    myorg <- "hgnc"
    data(list = "motifAnnotations_hgnc_v9", package = "RcisTarget")
    # SCENIC 内部按无后缀名取对象，新版 RcisTarget 只提供 _v9，这里做别名
    assign("motifAnnotations_hgnc", motifAnnotations_hgnc_v9, envir = globalenv())
  } else if (ref %in% c("mm9", "mm10")) {
    myorg <- "mgi"
    data(list = "motifAnnotations_mgi_v9", package = "RcisTarget")
    assign("motifAnnotations_mgi", motifAnnotations_mgi_v9, envir = globalenv())
  } else {
    stop("未识别的参考基因组: ", ref, "。请使用 hg19, hg38, mm9 或 mm10")
  }

  # dbIndexCol: 新版 RcisTarget 的 feather 以 "motifs" 列作索引，
  # SCENIC 1.3.1 默认按 "features" 检查会判为"数据库无法加载"
  scenicOptions <- initializeScenic(org = myorg, nCores = nCores,
                                    dbDir = dbDir, dbs = mydbs,
                                    datasetTitle = ref,
                                    dbIndexCol = "motifs")
  saveRDS(scenicOptions, file.path(outdir, "scenicOptions.rds"))
  # SCENIC 内部若干函数（regulonSelections/getIntName 等）写死从全局环境取
  # 名为 "scenicOptions" 的对象，因此这里同步一份到 globalenv，否则 Step4 会报
  # object 'scenicOptions' not found
  assign("scenicOptions", scenicOptions, envir = globalenv())

  # -------------------------------------------------------------------
  # 5. 基因过滤（与原脚本阈值一致）
  # -------------------------------------------------------------------
  send_msg(15, "基因过滤...")
  genesKept <- geneFiltering(exprMat_sub, scenicOptions,
                             minCountsPerGene = 0.8 * ncol(exprMat_sub),
                             minSamples = ncol(exprMat_sub) * 0.3)
  exprMat_filtered <- exprMat_sub[genesKept, , drop = FALSE]

  # -------------------------------------------------------------------
  # 6. 共表达网络: 相关性 + Genie3（最耗时阶段）
  # -------------------------------------------------------------------
  send_msg(25, "计算 TF-靶基因相关性（Genie3，最耗时）...")
  runCorrelation(exprMat_filtered, scenicOptions)

  exprMat_log <- log2(exprMat_filtered + 1)
  nParts <- ceiling(nrow(exprMat_log) / 2000)
  runGenie3(exprMat_log, scenicOptions, nParts = nParts)
  gc(verbose = FALSE)

  # -------------------------------------------------------------------
  # 7. 构建 co-expression modules + motif 验证生成 regulon
  # -------------------------------------------------------------------
  send_msg(55, "构建共表达模块...")
  # 兼容修复：RcisTarget 的 motif 注释阶段用 fork 多核时，子进程会被 OOM 回收
  # （日志特征: "scheduled cores 1, 2 did not deliver results"），随后 BiocParallel
  # 回收结果时抛出 "wrong args for environment subassignment"。此处起统一单核 +
  # SerialParam，牺牲一点速度换取稳定性；GENIE3 阶段（Step 6）仍保留用户核数。
  scenicOptions@settings$nCores <- 1
  options(SCENIC_PARALLEL = NULL)
  Sys.setenv(SCENIC_PARALLEL = "")
  BiocParallel::register(BiocParallel::SerialParam(), default = TRUE)
  gc(verbose = FALSE)
  runSCENIC_1_coexNetwork2modules(scenicOptions)

  send_msg(65, "motif 验证，生成 regulon（依赖 cisTarget 数据库）...")
  # dbIndexCol = "motifs"：同 initializeScenic，适配新版 RcisTarget 数据库索引列
  runSCENIC_2_createRegulons(scenicOptions, dbIndexCol = "motifs")

  # -------------------------------------------------------------------
  # 8. Regulon 活性打分（全部细胞）+ 二值化
  # -------------------------------------------------------------------
  send_msg(78, "AUCell 活性打分（全部细胞）...")
  scenicOptions@settings$nCores <- 1
  options(SCENIC_PARALLEL = NULL)
  Sys.setenv(SCENIC_PARALLEL = "")
  assign("scenicOptions", scenicOptions, envir = globalenv())
  exprMat_all <- scenic_logcounts(exprMat)
  # 前端展示图由下方生成；跳过 SCENIC 内部额外图和 t-SNE，保留评分及阈值。
  runSCENIC_3_scoreCells(scenicOptions, exprMat = exprMat_all,
                        skipHeatmap = TRUE, skipTsne = TRUE)

  send_msg(88, "regulon 二值化...")
  # SCENIC 1.3.1 的已知边界问题：样本里只剩下 1 个 regulon 时，
  # runSCENIC_4_aucell_binarize 内部用 binaryRegulonActivity[which(...), ] 取子集
  # 会 drop 成向量，随后 rowSums() 报 "'x' must be an array of at least two dimensions"。
  # 该函数在报错前已经把 4.1/4.2 二值化结果落盘，因此这里保留结果继续，
  # 只有连二值化文件都没生成时才重新抛出错误。
  tryCatch(
    runSCENIC_4_aucell_binarize(scenicOptions, exprMat = exprMat_all,
                              skipBoxplot = TRUE, skipHeatmaps = TRUE, skipTsne = TRUE),
    error = function(e) {
      bin_file <- file.path(int_dir, "4.1_binaryRegulonActivity.Rds")
      if (!file.exists(bin_file)) stop(e)
      message("[SCENIC] 二值化绘图阶段报错（单 regulon 边界情况），已保留二值化结果继续: ",
              conditionMessage(e))
    }
  )

  # -------------------------------------------------------------------
  # 9. 结果可视化（AUC 矩阵 + 二进制矩阵 + 热图）
  # -------------------------------------------------------------------
  send_msg(92, "生成可视化图...")

  AUCmatrix <- readRDS(file.path(int_dir, "3.4_regulonAUC.Rds"))
  AUC <- AUCmatrix@assays@data@listData$AUC
  AUC_df <- data.frame(t(AUC), check.names = FALSE)
  RegulonName_AUC <- gsub("\\)", "", gsub(" \\(", "_", colnames(AUC_df)))
  colnames(AUC_df) <- RegulonName_AUC

  # 默认热图和前端下拉均以“活性方差最高”排序，保证 top1–5 是当前样本最有区分度的 regulon。
  regulon_order <- colnames(AUC_df)[order(apply(AUC_df, 2, stats::var), decreasing = TRUE)]
  AUC_df <- AUC_df[, regulon_order, drop = FALSE]

  proauc <- AddMetaData(pro, AUC_df)
  proauc@assays$integrated <- NULL

  BINmatrix <- readRDS(file.path(int_dir, "4.1_binaryRegulonActivity.Rds"))
  BIN_df <- data.frame(t(BINmatrix), check.names = FALSE)
  RegulonName_BIN <- gsub("\\)", "", gsub(" \\(", "_", colnames(BIN_df)))
  colnames(BIN_df) <- RegulonName_BIN
  BIN_df <- BIN_df[, intersect(regulon_order, colnames(BIN_df)), drop = FALSE]

  probin <- if (ncol(BIN_df) > 0) AddMetaData(pro, BIN_df) else pro
  probin@assays$integrated <- NULL

  # 展示用 regulon：必须同时存在于 AUC 与二值矩阵。
  # 二值化(Step4)会把在该样本中不活跃的 regulon 剔除，若直接取 AUC 第一列，
  # FeaturePlot(probin, ...) 会报 "requested variables were not found"
  my_regulon <- intersect(colnames(AUC_df), colnames(BIN_df))
  if (length(my_regulon) == 0) {
    my_regulon <- colnames(AUC_df)[1]
  } else {
    my_regulon <- my_regulon[1]
  }
  has_bin <- my_regulon %in% colnames(probin@meta.data)
  message(sprintf("[SCENIC] 展示 regulon: %s（二值矩阵可用: %s）", my_regulon, has_bin))

  # 主图: AUC / 二进制 / CellType 三联 UMAP（与原脚本一致）
  p1 <- FeaturePlot(proauc, features = my_regulon, label = TRUE, reduction = "umap")
  p3 <- DimPlot(pro, reduction = "umap", group.by = "CellType", label = TRUE) +
    guides(color = guide_legend(override.aes = list(size = 2), ncol = 2)) +
    theme(legend.title = element_text(size = 8), legend.text = element_text(size = 7))

  if (has_bin) {
    p2 <- FeaturePlot(probin, features = my_regulon, label = TRUE, reduction = "umap")
    p_main <- p1 | p2 | p3
  } else {
    p_main <- p1 | p3
  }

  # 统计图: RidgePlot + VlnPlot
  p_ridge <- RidgePlot(proauc, features = my_regulon, group.by = "CellType") +
    theme(legend.position = "none")
  p_vln <- VlnPlot(proauc, features = my_regulon, pt.size = 0, group.by = "CellType") +
    theme(legend.position = "none")
  p_stat <- p_ridge + p_vln

  # 热图: 默认展示活性最高的前 5 个 regulon；用户可在结果页多选重绘
  AUCmatrix_t <- t(AUC_df)
  BINmatrix_t <- t(BIN_df)
  my_regulons <- rownames(AUCmatrix_t)[seq_len(min(5, nrow(AUCmatrix_t)))]
  myAUCmatrix <- AUCmatrix_t[rownames(AUCmatrix_t) %in% my_regulons, , drop = FALSE]
  myBINmatrix <- BINmatrix_t[rownames(BINmatrix_t) %in% my_regulons, , drop = FALSE]

  # 健壮性：二值化后可能只剩 1 个 regulon（或 0 个细胞含活性 regulon），
  # pheatmap 的 hclust 要求 >=2 行；注释行必须与各自矩阵的细胞一致。
  draw_regulon_heatmap <- function(mat, file) {
    if (is.null(dim(mat)) || nrow(mat) == 0 || ncol(mat) == 0) {
      message("[SCENIC] 跳过热图（矩阵为空）: ", basename(file))
      return(invisible(NULL))
    }
    vals <- as.vector(mat)
    vals <- vals[!is.na(vals)]
    if (length(unique(vals)) < 2) {
      # 常量矩阵（如只剩 1 个 regulon 且全部为同一值）会让 pheatmap 的 breaks 重复
      message("[SCENIC] 跳过热图（矩阵为常量）: ", basename(file))
      return(invisible(NULL))
    }
    ann <- data.frame(
      CellType = pro@meta.data[colnames(mat), "CellType"],
      row.names = colnames(mat)
    )
    heatmap <- tryCatch(
      pheatmap(mat, show_colnames = FALSE, annotation_col = ann,
               silent = TRUE, fontsize = 6, fontsize_col = 8,
               fontsize_row = 8, annotation_legend = TRUE, width = 6, height = 5,
               cluster_rows = nrow(mat) >= 2),
      error = function(e) { message("[SCENIC] 热图生成失败（跳过）: ", conditionMessage(e)); NULL }
    )
    if (!is.null(heatmap)) {
      open_plot_device(file, 1800, 1500, plot_format, units = "px")
      tryCatch(grid::grid.draw(heatmap$gtable), finally = dev.off())
    }
    invisible(NULL)
  }

  heatmap_file <- file.path(outdir, paste0("myAUCmatrix_heatmap.", plot_format))
  draw_regulon_heatmap(myAUCmatrix, heatmap_file)
  if (!file.exists(heatmap_file)) heatmap_file <- NULL

  bin_heatmap_file <- file.path(outdir, paste0("myBINmatrix_heatmap.", plot_format))
  draw_regulon_heatmap(myBINmatrix, bin_heatmap_file)
  if (!file.exists(bin_heatmap_file)) bin_heatmap_file <- NULL

  # regulon 清单 CSV
  table_path <- file.path(outdir, "scenic_regulons.csv")
  write.csv(data.frame(regulon = colnames(AUC_df),
                       stringsAsFactors = FALSE),
            table_path, row.names = FALSE)

  # 完整 regulon 活性矩阵（参考 run_SCENIC.R 中 3.4/4.1 两份矩阵）：
  # 前端结果页可下载；行列分别为 细胞 × regulon 和 细胞 × 二值 regulon
  auc_matrix_path <- file.path(outdir, "regulonAUC_matrix.csv")
  write.csv(data.frame(cell = rownames(AUC_df), AUC_df, check.names = FALSE),
            auc_matrix_path, row.names = FALSE)
  bin_matrix_path <- file.path(outdir, "regulon_binary_matrix.csv")
  write.csv(data.frame(cell = rownames(BIN_df), BIN_df, check.names = FALSE),
            bin_matrix_path, row.names = FALSE)

  send_msg(100, "SCENIC 分析完成")

  # 维度数兜底：ncol 异常/NA 时回退 0，避免序列化出 null
  safe_ncol <- function(x) {
    v <- tryCatch(ncol(x), error = function(e) NULL)
    if (is.null(v) || length(v) == 0L || is.na(v)) 0L else as.integer(v)
  }

  list(
    plot = p_main,
    stat_plot = p_stat,
    heatmap_path = heatmap_file,
    bin_heatmap_path = bin_heatmap_file,
    table_path = table_path,
    auc_matrix_path = auc_matrix_path,
    bin_matrix_path = bin_matrix_path,
    n_regulons = safe_ncol(AUC_df),
    n_cells = safe_ncol(exprMat),
    n_cells_sub = safe_ncol(exprMat_sub),
    regulons = as.list(colnames(AUC_df))
  )
}

# =====================================================================
# Regulon 结果按需重绘
# 复用 /scenic 已归档的轻量 CSV 与 seurat_annotated.rds，避免复制完整对象。
# =====================================================================

.scenic_plot_format <- function(plot_format) {
  plot_format <- as.character(plot_format)[1]
  if (is.na(plot_format) || !nzchar(plot_format)) plot_format <- "png"
  if (!plot_format %in% c("png", "pdf", "svg", "tiff")) plot_format <- "png"
  plot_format
}

.scenic_result_paths <- function(project_path) {
  result_json <- file.path(project_path, "scenic_result.json")
  auc_path <- NULL
  bin_path <- NULL
  if (file.exists(result_json)) {
    result <- tryCatch(jsonlite::read_json(result_json, simplifyVector = FALSE),
                       error = function(e) NULL)
    if (!is.null(result$data_paths)) {
      auc_value <- result$data_paths$regulon_auc
      if (is.null(auc_value)) auc_value <- result$data_paths$regulon_auc_csv
      bin_value <- result$data_paths$regulon_binary
      if (is.null(bin_value)) bin_value <- result$data_paths$regulon_binary_csv
      auc_path <- as.character(auc_value)[1]
      bin_path <- as.character(bin_value)[1]
    }
  }
  find_latest <- function(pattern) {
    files <- list.files(project_path, pattern = pattern, full.names = TRUE)
    if (length(files) == 0) return(NULL)
    files[which.max(file.mtime(files))]
  }
  if (is.null(auc_path) || is.na(auc_path) || !file.exists(auc_path)) {
    auc_path <- find_latest("_scenic_\\d{14}_regulon_auc(_csv)?[.]csv$")
  }
  if (is.null(bin_path) || is.na(bin_path) || !file.exists(bin_path)) {
    bin_path <- find_latest("_scenic_\\d{14}_regulon_binary(_csv)?[.]csv$")
  }
  list(auc = auc_path, binary = bin_path)
}

.scenic_read_matrix <- function(path, cell_names = NULL) {
  if (is.null(path) || is.na(path) || !file.exists(path)) return(NULL)
  df <- utils::read.csv(path, check.names = FALSE, stringsAsFactors = FALSE)
  if (ncol(df) < 2) return(NULL)
  first_col <- as.character(df[[1]])
  value_cols <- colnames(df)[-1]
  if (!is.null(cell_names)) {
    first_is_cells <- any(first_col %in% cell_names)
    cols_are_cells <- any(value_cols %in% cell_names)
    if (cols_are_cells && !first_is_cells) {
      mat <- t(as.matrix(df[, -1, drop = FALSE]))
      rownames(mat) <- value_cols
      colnames(mat) <- first_col
      return(mat)
    }
  }
  mat <- as.matrix(df[, -1, drop = FALSE])
  rownames(mat) <- first_col
  mat
}

.scenic_load_project <- function(project_path) {
  rds_path <- file.path(project_path, "seurat_annotated.rds")
  if (!file.exists(rds_path)) stop("未找到 seurat_annotated.rds，请先完成细胞注释步骤")
  pro <- readRDS(rds_path)
  if (exists("sync_celltype_from_json", mode = "function")) {
    pro <- sync_celltype_from_json(pro, project_path)
  }
  pro
}

.scenic_group_col <- function(pro) {
  candidates <- c("CellType", "celltype", "cell_type", "Annotation", "seurat_clusters")
  hit <- candidates[candidates %in% colnames(pro@meta.data)]
  if (length(hit) == 0) NULL else hit[1]
}

.scenic_plot_prefix <- function(project_path, label) {
  ts <- format(Sys.time(), "%Y%m%d%H%M%S", tz = "Asia/Shanghai")
  tag <- gsub("[^A-Za-z0-9]+", "_", label)
  paste0(basename(project_path), "_scenic_", ts, "_regulon_", tag)
}

run_scenic_regulon_plots <- function(project_path, regulon, plot_format = "png",
                                     report = function(pct, msg) NULL) {
  suppressPackageStartupMessages({
    library(Seurat); library(ggplot2); library(patchwork)
  })
  ext <- .scenic_plot_format(plot_format)
  paths <- .scenic_result_paths(project_path)
  pro <- .scenic_load_project(project_path)
  auc <- .scenic_read_matrix(paths$auc, colnames(pro))
  if (is.null(auc)) stop("未找到 SCENIC regulon 活性矩阵，请先完成转录因子分析")
  if (!(regulon %in% colnames(auc))) {
    stop("Regulon '", regulon, "' 不存在；可选: ", paste(colnames(auc), collapse = ", "))
  }

  report(10, "加载细胞注释与 regulon 活性...")
  common <- intersect(rownames(auc), colnames(pro))
  if (length(common) == 0) stop("regulon 活性矩阵与注释对象没有匹配的细胞")

  proauc <- AddMetaData(pro, data.frame(auc[common, , drop = FALSE], check.names = FALSE))
  group_col <- .scenic_group_col(proauc)
  reductions <- SeuratObject::Reductions(proauc)
  if (length(reductions) == 0) stop("未找到降维结果，无法绘制 UMAP")
  red <- if ("umap" %in% reductions) "umap" else reductions[1]

  report(35, paste0("绘制 ", regulon, " UMAP..."))
  p_auc <- FeaturePlot(proauc, features = regulon, reduction = red, label = TRUE) +
    ggtitle(paste0(regulon, " (AUC)"))
  p_cell <- DimPlot(proauc, reduction = red, group.by = group_col, label = !is.null(group_col)) +
    ggtitle(if (is.null(group_col)) "Cell" else "CellType")

  bin <- .scenic_read_matrix(paths$binary, colnames(pro))
  has_binary <- !is.null(bin) && regulon %in% colnames(bin)
  if (has_binary) {
    bin_common <- intersect(rownames(bin), colnames(pro))
    if (length(bin_common) > 0) {
      probin <- AddMetaData(pro, data.frame(bin[bin_common, , drop = FALSE], check.names = FALSE))
      p_bin <- FeaturePlot(probin, features = regulon, reduction = red, label = TRUE) +
        ggtitle(paste0(regulon, " (binary)"))
      p_umap <- p_auc | p_bin | p_cell
    } else {
      has_binary <- FALSE
      p_umap <- p_auc | p_cell
    }
  } else {
    p_umap <- p_auc | p_cell
  }

  prefix <- .scenic_plot_prefix(project_path, regulon)
  umap_path <- file.path(project_path, paste0(prefix, "_umap.", ext))
  ggsave(umap_path, p_umap, width = if (has_binary) 15 else 10, height = 4.6,
         dpi = 300, limitsize = FALSE)

  report(75, paste0("绘制 ", regulon, " 小提琴图..."))
  p1 <- RidgePlot(proauc, features = regulon, group.by = group_col) + theme(legend.position = "none")
  p2 <- VlnPlot(proauc, features = regulon, pt.size = 0, group.by = group_col) + theme(legend.position = "none")
  violin_path <- file.path(project_path, paste0(prefix, "_violin.", ext))
  ggsave(violin_path, p1 + p2, width = 11, height = 8, dpi = 300, limitsize = FALSE)

  report(100, "完成")
  list(
    status = "success",
    regulon = regulon,
    binary_available = has_binary,
    plot_paths = list(regulon_umap = umap_path, regulon_vln = violin_path)
  )
}

run_scenic_heatmap <- function(project_path, regulons, plot_format = "png",
                               report = function(pct, msg) NULL) {
  suppressPackageStartupMessages({ library(Seurat); library(pheatmap); library(ggplot2) })
  ext <- .scenic_plot_format(plot_format)
  regulons <- unique(as.character(unlist(regulons)))
  regulons <- regulons[nzchar(regulons)]
  if (length(regulons) == 0) stop("请至少选择一个 regulon")

  report(15, "加载 regulon 活性...")
  paths <- .scenic_result_paths(project_path)
  pro <- .scenic_load_project(project_path)
  auc <- .scenic_read_matrix(paths$auc, colnames(pro))
  if (is.null(auc)) stop("未找到 SCENIC regulon 活性矩阵，请先完成转录因子分析")
  missing <- setdiff(regulons, colnames(auc))
  if (length(missing) > 0) stop("以下 regulon 不存在: ", paste(missing, collapse = ", "))

  common <- intersect(rownames(auc), colnames(pro))
  if (length(common) == 0) stop("regulon 活性矩阵与注释对象没有匹配的细胞")
  group_col <- .scenic_group_col(pro)
  if (is.null(group_col)) stop("注释对象缺少 CellType 列，无法生成细胞类型均值热图")
  cell_types <- as.character(pro@meta.data[common, group_col])
  cell_types[is.na(cell_types) | !nzchar(cell_types)] <- "Unknown"
  idx_list <- split(seq_along(common), cell_types)
  agg <- sapply(idx_list, function(idx) {
    colMeans(auc[common[idx], regulons, drop = FALSE], na.rm = TRUE)
  })
  if (is.null(dim(agg))) {
    agg <- matrix(agg, nrow = length(regulons), dimnames = list(regulons, names(idx_list)))
  } else {
    agg <- agg[regulons, , drop = FALSE]
  }

  report(65, "绘制 regulon 热图...")
  ts <- format(Sys.time(), "%Y%m%d%H%M%S", tz = "Asia/Shanghai")
  heat_path <- file.path(project_path, paste0(
    basename(project_path), "_scenic_", ts, "_regulon_heatmap_",
    length(regulons), "regs.", ext
  ))
  vals <- as.vector(agg)
  if (length(unique(vals[!is.na(vals)])) < 2) stop("所选 regulon 活性为常量，无法生成热图")
  hm <- pheatmap(
    agg,
    cluster_rows = length(regulons) > 1,
    cluster_cols = ncol(agg) > 1,
    fontsize = 8, fontsize_row = 8, fontsize_col = 9,
    color = colorRampPalette(c("#2C4A7C", "white", "#C86019"))(100),
    silent = TRUE
  )
  open_plot_device(heat_path,
                   width = max(1800, 1200 + ncol(agg) * 120),
                   height = max(1200, 800 + length(regulons) * 90),
                   format = ext, units = "px")
  tryCatch(grid::grid.draw(hm$gtable), finally = dev.off())

  bar_path <- file.path(project_path, paste0(
    basename(project_path), "_scenic_", ts, "_regulon_bar_",
    length(regulons), "regs.", ext
  ))
  bar_df <- data.frame(
    CellType = rep(colnames(agg), each = nrow(agg)),
    Regulon = rep(rownames(agg), times = ncol(agg)),
    Activity = as.vector(agg),
    stringsAsFactors = FALSE
  )
  p_bar <- ggplot(bar_df, aes(x = CellType, y = Activity, fill = CellType)) +
    geom_col(show.legend = FALSE) +
    facet_wrap(~Regulon, scales = "free_y") +
    theme_bw(base_size = 10) +
    labs(x = NULL, y = "Mean regulon activity") +
    theme(axis.text.x = element_text(angle = 45, hjust = 1))
  ggsave(bar_path, p_bar,
         width = max(8, min(18, 5 + length(regulons) * 1.8)),
         height = 5, dpi = 300, limitsize = FALSE)

  report(100, "完成")
  list(status = "success", regulons = regulons,
       plot_paths = list(regulon_heatmap = heat_path, regulon_bar = bar_path))
}

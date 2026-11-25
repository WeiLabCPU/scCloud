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

  proauc <- AddMetaData(pro, AUC_df)
  proauc@assays$integrated <- NULL

  BINmatrix <- readRDS(file.path(int_dir, "4.1_binaryRegulonActivity.Rds"))
  BIN_df <- data.frame(t(BINmatrix), check.names = FALSE)
  RegulonName_BIN <- gsub("\\)", "", gsub(" \\(", "_", colnames(BIN_df)))
  colnames(BIN_df) <- RegulonName_BIN

  probin <- AddMetaData(pro, BIN_df)
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

  # 热图: 前 15 个 regulon，AUC 版 + 二进制版（与原脚本一致）
  AUCmatrix_t <- t(AUC_df)
  BINmatrix_t <- t(BIN_df)
  my_regulons <- rownames(AUCmatrix_t)[seq_len(min(15, nrow(AUCmatrix_t)))]
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

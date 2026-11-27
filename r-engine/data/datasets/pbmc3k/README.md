# 内置经典数据集 pbmc3k.rds

## 说明
10x Genomics 公开的健康供体外周血单个核细胞（PBMC）经典教学数据集，也是 Seurat 官方教程首推数据。
本文件由官方 filtered gene/barcode 矩阵读入后做基础 QC、标准化、降维（PCA/UMAP）与聚类整理而成，
可直接上传到 scCloud 跑通降维、聚类、细胞注释及下游分析，适合新用户上手练习。

## 基本信息
- 对象类型：Seurat 对象（RDS）
- 物种：H. sapiens（人）
- 参考基因组：hg19（10x v1  Chemistry）
- 细胞数：2,638（基础 QC 过滤后）
- 基因数：13,714（RNA assay）
- 保留 assay：RNA（标准化后数据 + counts）
- 保留降维：pca、umap
- 来源：10x Genomics 公开演示数据，Illumina NextSeq 500 测序，单一健康女性供体（去除粒细胞）

## 聚类结果（seurat_clusters，resolution=0.5）
| 聚类 | 细胞数 |
| --- | ---: |
| 0 | 711 |
| 1 | 480 |
| 2 | 472 |
| 3 | 344 |
| 4 | 279 |
| 5 | 162 |
| 6 | 144 |
| 7 | 32 |
| 8 | 14 |

> 本内置对象未预置细胞类型注释；上传后可由平台「细胞注释」步骤自动标注，常见类型包括
> CD4+ T 细胞、CD8+ T 细胞、B 细胞、NK 细胞、单核细胞与树突状细胞。

## meta.data 主要字段
| 字段 | 含义 |
| --- | --- |
| orig.ident / Sample | 原始样本编号（pbmc3k） |
| nCount_RNA | 每个细胞 UMIs 总数 |
| nFeature_RNA | 每个细胞检出基因数 |
| percent.mt | 线粒体基因比例 |
| seurat_clusters / Cluster | 聚类编号（0–8 / C1–C9） |

## 使用方式
1. 在平台新建项目，物种选择「人」；
2. 上传本 RDS 文件作为输入数据；
3. 可直接进入降维、聚类、细胞注释及下游分析（细胞通讯、拟时序、WGCNA、SCENIC 等）。

## 许可与引用
- 数据为 10x Genomics 公开演示数据，仅用于教学与平台演示；
- 原始矩阵：https://cf.10xgenomics.com/samples/cell/pbmc3k/pbmc3k_filtered_gene_bc_matrices.tar.gz
- 教程参考：Seurat Guided Clustering Tutorial（Satija Lab）；
- 如需用于正式研究，请遵循 10x 数据使用条款并引用对应来源。

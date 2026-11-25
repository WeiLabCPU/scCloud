# 内置示例数据集 demo_subset.rds

## 说明
本文件由平台测试数据集分层抽样整理而成，已完成标准化、降维（PCA/UMAP）、聚类与细胞注释，
可直接上传到 scCloud 跑通分析流程各步骤，作为新用户的上手示例。

## 基本信息
- 对象类型：Seurat 对象（RDS）
- 物种：H. sapiens（人）
- 细胞数：1000
- 基因数：38,606（RNA assay）
- 保留 assay：RNA
- 保留降维：pca、umap
- 原始样本：SRR7692288、SRR7692289（平台 test 数据集）

## 细胞类型分布（meta.data$CellType）
| 细胞类型 | 细胞数 |
| --- | ---: |
| B-cells | 127 |
| CD4+ T cells | 224 |
| CD8+ T-cells | 284 |
| Macrophages | 38 |
| Neurons | 284 |
| NK cells | 43 |

## meta.data 主要字段
| 字段 | 含义 |
| --- | --- |
| orig.ident / Sample | 原始样本编号 |
| nCount_RNA | 每个细胞 UMIs 总数 |
| nFeature_RNA | 每个细胞检出基因数 |
| percent.mt | 线粒体基因比例 |
| seurat_clusters / Cluster | 聚类编号（0–9 / C1–C10） |
| singleR / CellType | 细胞注释类型 |

## 使用方式
1. 在平台新建项目，物种选择「人」；
2. 上传本 RDS 文件作为输入数据；
3. 可直接进入降维、聚类、细胞注释及下游分析（细胞通讯、拟时序、WGCNA、SCENIC 等）。

## 许可
本数据集仅用于教学与平台演示，整理自公开测试样本；如需用于正式研究，请引用对应原始文献与数据库来源。

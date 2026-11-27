# SCENIC cisTarget 数据库

数据库通过 `docker-compose.yml` 的 `./r-engine/data:/app/data:ro` 同时挂载给 R API 和 worker，后端从同一个宿主目录读取文件清单。
数据库为 GB 级资源，不随 Git 或镜像分发。请在部署前手动下载；不要在启动请求中自动下载。

当前算法使用 RcisTarget 的 v9 motif 注释，因此需要 **mc9nr、genes_vs_motifs.rankings.feather** 数据库。请勿混用 v10 注释或 scores 数据库。
官方目录：<https://resources.aertslab.org/cistarget/databases/homo_sapiens/hg38/refseq_r80/mc9nr/gene_based/>

在仓库根目录执行以下命令，先下载到 `.part`，成功后改名，避免前端把未下载完的文件识别为可用数据库：

```bash
base=https://resources.aertslab.org/cistarget/databases/homo_sapiens/hg38/refseq_r80/mc9nr/gene_based
name=hg38__refseq-r80__10kb_up_and_down_tss.mc9nr.genes_vs_motifs.rankings.feather
curl --fail --location --retry 3 --continue-at - \
  --output "r-engine/data/cistarget/$name.part" "$base/$name" && \
  mv "r-engine/data/cistarget/$name.part" "r-engine/data/cistarget/$name"
```

下载后应对照发布方校验信息检查文件完整性。前端仅按文件名、非零大小和物种发现已安装数据库；实际 feather 内容和 motif 兼容性由 RcisTarget 加载时校验。

其他参考基因组请从 [官方数据库目录](https://resources.aertslab.org/cistarget/databases/) 选择相应物种的兼容 v9 gene-ranking 文件，放入同一目录。前端仅显示当前项目物种实际已配置的参考基因组；缺失时拒绝提交 SCENIC。不要仅改文件名来冒充其他物种或数据库版本。

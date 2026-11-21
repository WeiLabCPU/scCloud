# scCloud 前端 UI/UX 与核心交互分级整改计划

- **日期**：2026-11-20
- **状态**：分批实施中 — Batch 1 实施中（已确认：1选方案A隐藏空壳按钮、2选方案B中英文字体子集全量本地打包、3先推进 Batch 1）
- **基线**：`origin/main` @ `903379b`（PR #100–#103 部署加固与本地 `./data/projects` 存储改造已全部合入）
- **审计与核查范围**：
  - `frontend/src/` 全量 45 个源文件（约 15,756 行）；
  - 关联后端接口（[backend/app/auth/router.py](../../backend/app/auth/router.py)、[backend/app/convert/router.py](../../backend/app/convert/router.py)）；
  - 构建与 CI 链路（在规划期实测 `cd frontend && ./node_modules/.bin/tsc --noEmit` 检出 **14 个文件共 60 处 TypeScript 错误**，此前被 [next.config.ts](../../frontend/next.config.ts) 中 `typescript.ignoreBuildErrors: true` 掩盖；同时 [.github/workflows/](../../.github/workflows) 目前缺少前端 PR 构建与类型检查工作流）。

---

## 一、背景与拆分原则

### 1.1 整改原则

1. **功能正确性与数据安全优先**：先堵住“正式用户 Token 续期失败静默降级为匿名新游客”“小鼠项目按人类参考跑 Phase 2”“注释编辑保存失败吞错”“参数框按 `Enter` 误提交流水线”等直接损害科研结果与用户信任的 P0 硬伤。
2. **零假按钮、零写死假数据**：所有可见控件与账户/角色展示必须真实可用或明确隐藏，清除硬编码个人用户名 `'Linli'`、写死角色/配额及错误外链。
3. **国内/内网离线构建与访问双友好**：移除运行时直连 Google Fonts 外链，同时**避免**简单替换为在构建期仍需联网拉取 Google 资源的 `next/font/google`（防止国内无代理服务器执行 `sh ./start.sh --build` 时失败）。
4. **三批独立 PR 渐进交付**：每批 PR 职责边界清晰、可独立验证与回滚，逐批合入 `main`。

### 1.2 三批 PR 路线图总览

| 批次 | 建议分支名 | 优先级 | 核心目标 | 涉及主要文件 |
| --- | --- | --- | --- | --- |
| **Batch 1** | `fix/frontend-p0-p1-core-ux` | **P0 + P1** | 修复权限降级/物种错传/吞错/误提交/异步竞态、清理假按钮/假数据/硬编码、字体本地化 | `api.ts`、`Phase2ParamPage.tsx`、`AnnotateResult.tsx`、`GeneExpressionPopup.tsx`、`NumberInput.tsx`、`ResultViewer.tsx`、`PipelineView.tsx`、`ProjectSelector.tsx`、`dashboard/layout.tsx`、`page.tsx`、`settings/page.tsx`、`admin/page.tsx`、`convert/page.tsx`、`AuthModal.tsx`、`layout.tsx`、`globals.css`、`package.json`（共约 17 个） |
| **Batch 2** | `feat/frontend-p2-viz-and-upload` | **P2** | 图片点击放大灯箱与 Blob 泄漏修复、`DeckScatterPlot` 悬停性能与 PCA 缩放修复、富集/DEG 表格增强、分片上传可取消与续期、多样本整合一键导入项目 | `ImageLightbox.tsx`（新增）、`ResultViewer.tsx`、`QCResultTabs.tsx`、`DeckScatterPlot.tsx`、`EnrichBubble.tsx`、`FileUploadModal.tsx`、`convert/page.tsx`、`backend/app/convert/router.py`、`backend/tests/`（共约 9 个） |
| **Batch 3** | `chore/frontend-p3-responsive-and-types` | **P3** | 窄屏/超宽屏响应式与定位修复、对比度与卡片微抖打磨、Plotly 去重与死代码清理、清零全仓 60 处 TS 错误并补齐前端 CI 门禁 | `dashboard/layout.tsx`、`page.tsx`、`PipelineView.tsx`、`AddSampleDropdown.tsx`、`AnnotateResult.tsx`、`globals.css`、`next.config.ts`、`package.json`、`.github/workflows/frontend-ci.yml`（新增）及受影响的图表/组件类型修复（约 18+ 个） |

---

## 二、分批详细改动清单

### Batch 1：核心正确性修复、假按钮/假数据清理与字体本地化（P0 + P1）

- **建议分支**：`fix/frontend-p0-p1-core-ux`（基于最新 `origin/main` 创建）

#### T1.1 登录态续期隔离：杜绝正式用户被静默降级为匿名新游客
- **位置**：[frontend/src/app/lib/api.ts](../../frontend/src/app/lib/api.ts#L46-L212)、[frontend/src/app/components/ResultViewer.tsx](../../frontend/src/app/components/ResultViewer.tsx#L216-L226)
- **根因**：
  1. `apiFetch` 在收到 401 且 `tryRefresh()` 失败后，无条件调用 `guestLoginFallback()` 向 `sessionStorage` 写入新游客 token；由于 `getAuthItem()` 优先读 `sessionStorage`，直接遮蔽 `localStorage` 中已登录的正式账号或管理员凭证，导致页面瞬间切换成“空项目游客态”。
  2. `guestLoginFallback()` 缺乏并发互斥锁，多个并发请求同时 401 时会在后端刷出多个多余游客账号。
  3. `ResultViewer.tsx` 重复手写了不完整且缺少共享刷新保护的 `fetchWithAuth`。
- **改法**：
  1. 将游客重建严格限制为 **仅当当前会话原本就是游客（`isGuest() === true`）** 时才允许触发，且为 `guestLoginFallback()` 增加共享 `guestFallbackPromise` 并发互斥锁；
  2. 正式用户（`!isGuest()`）当 `/api/auth/refresh` 明确返回 `401` 或 `403` 时调用 `forceLogout()` 清态并跳回登录页；若 `refresh` 因瞬时网络错误或 `5xx` 失败，保留本地已有凭证并向上抛出可感知的错误提示，绝不降级游客；
  3. 删除 `ResultViewer.tsx` 中的 `fetchWithAuth`，统一复用 `api.ts` 导出的 `authedFetch`。

#### T1.2 小鼠（Mouse）数据集 Phase 2 物种参数透传修复
- **位置**：[frontend/src/app/dashboard/analysis/components/Phase2ParamPage.tsx](../../frontend/src/app/dashboard/analysis/components/Phase2ParamPage.tsx#L23-L53)、[Phase2ParamPage.tsx](../../frontend/src/app/dashboard/analysis/components/Phase2ParamPage.tsx#L192-L199)
- **根因**：`DEFAULT_PARAMS.infercnv.species` 硬编码 `"Human"`，`DEFAULT_PARAMS.cellchat` 默认对象缺少 `species` 字段，且 `handleSubmit` 组装 `resumePipeline` 请求体时漏注入 `species` prop，导致小鼠项目仍以 `"Human"` 跑 CellChat / inferCNV。
- **改法**：
  - 新增物种规范化工具函数（兼容 `"mouse"` / `"Mouse"` → `"Mouse"`，其他默认 `"Human"`）；
  - 在 `params` 初始化、`useEffect([species])` 同步以及 `handleSubmit` 最终组装提交载荷时，显式写入规范化后的 `cellchat.species` 与 `infercnv.species`。

#### T1.3 WGCNA 细胞亚群多选下拉框内部滚动误关闭修复
- **位置**：[frontend/src/app/dashboard/analysis/components/Phase2ParamPage.tsx](../../frontend/src/app/dashboard/analysis/components/Phase2ParamPage.tsx#L146-L150)、[Phase2ParamPage.tsx](../../frontend/src/app/dashboard/analysis/components/Phase2ParamPage.tsx#L590-L601)
- **根因**：`window.addEventListener("scroll", handleScroll, true)` 在捕获阶段监听全页面所有滚动事件，用户在 Portal 弹出的下拉列表内部滚轮向下滚动 1px 也会触发关闭。
- **改法**：为 Portal 下拉菜单容器绑定 `wgcnaMenuRef`；在 `handleScroll(e: Event)` 中检查 `if (wgcnaMenuRef.current && e.target instanceof Node && wgcnaMenuRef.current.contains(e.target)) return;`，仅外部视口滚动时关闭下拉菜单。

#### T1.4 细胞注释编辑防静默丢数据 + 基因表达弹窗“打不开/关不掉”修复
- **位置**：[frontend/src/app/components/AnnotateResult.tsx](../../frontend/src/app/components/AnnotateResult.tsx#L525-L571)、[AnnotateResult.tsx](../../frontend/src/app/components/AnnotateResult.tsx#L961-L1034)、[frontend/src/app/components/GeneExpressionPopup.tsx](../../frontend/src/app/components/GeneExpressionPopup.tsx#L235-L271)
- **改法**：
  1. `AnnotateResult.tsx` 的 `handleSaveResults` 改为等待 `await updateTaskResult(...)` 成功返回后才清空 `editedResults` 并退出编辑状态；新增 `isSaving` 防重复提交与保存失败提示条，接口异常时保留用户的全部待保存编辑；
  2. 为簇注释输入控件补齐 `data-cluster={cluster}` 属性（或改用 React ref 映射），解决点击推荐 Marker 基因时 `document.querySelector('input[data-cluster=...]')` 恒为 `null` 导致无法弹出表达图的问题；
  3. `GeneExpressionPopup.tsx` 增加右上角明确 `×` 关闭按钮、`Esc` 键关闭监听以及外部区域点击关闭处理。

#### T1.5 参数数字输入框 `Enter` 键误提交流水线修复
- **位置**：[frontend/src/app/dashboard/analysis/components/NumberInput.tsx](../../frontend/src/app/dashboard/analysis/components/NumberInput.tsx#L73-L76)、[PipelineForm.tsx](../../frontend/src/app/dashboard/analysis/components/PipelineForm.tsx#L421)
- **根因**：`NumberInput` 按下 `Enter` 时调用 `blur()` 却漏掉 `e.preventDefault()`，既触发外层 `<form onSubmit>` 原生提交，又在 `setState` 更新完成前把旧数值发给后端。
- **改法**：在 `onKeyDown` 处理 `e.key === "Enter"` 时先执行 `e.preventDefault()`，再提交当前输入值并调用 `blur()`。

#### T1.6 结果查看器异步竞态与跨项目状态串台修复
- **位置**：[frontend/src/app/components/ResultViewer.tsx](../../frontend/src/app/components/ResultViewer.tsx#L280-L303)、[ResultViewer.tsx](../../frontend/src/app/components/ResultViewer.tsx#L371-L381)、[ResultViewer.tsx](../../frontend/src/app/components/ResultViewer.tsx#L1232-L1263)、[ResultViewer.tsx](../../frontend/src/app/components/ResultViewer.tsx#L1581-L1628)
- **改法**：
  1. `fetchTaskResult` 与认证图片 `Blob` 加载 `useEffect` 接入 `AbortController` 并在 cleanup 中 `abort()`，丢弃慢请求后返回的陈旧数据；
  2. 为 `<MarkersResult key={task.id} ... />` 等含内部状态的步骤子组件补齐 `key={task.id}`，确保切换项目或任务时彻底重置基因补全列表与旧图表；
  3. `MarkersResult` 的 Tab 3 / Tab 4 拆分为“筛选勾选草稿态（draft）”与“已提交查询态（applied）”，仅在点击「生成」后才更新图片路径与展示标题，消除刚勾选新簇还未点生成就闪烁「图片暂不可用」的问题。

#### T1.7 分析流水线状态文案、误取消保护与项目选择器同步
- **位置**：[frontend/src/app/dashboard/analysis/components/PipelineView.tsx](../../frontend/src/app/dashboard/analysis/components/PipelineView.tsx#L309-L326)、[PipelineView.tsx](../../frontend/src/app/dashboard/analysis/components/PipelineView.tsx#L371-L402)、[PipelineView.tsx](../../frontend/src/app/dashboard/analysis/components/PipelineView.tsx#L513-L519)、[frontend/src/app/components/ProjectSelector.tsx](../../frontend/src/app/components/ProjectSelector.tsx#L70-L170)
- **改法**：
  1. `PipelineView.tsx` 第 2 步运行中 `<ProgressTracker>` 补传 `stepLabel={rcStepLabel}`，并删除组件并不接收的 `onMessage={() => {}}` prop，修复界面显示 `"正在执行 undefined..."`；
  2. 点击「重新设置 Phase 2」时，若 `pipeline.status === "running"`（含 Phase 1 运行中），必须先弹出二次确认避免误取消正在执行的任务；全部步骤完成时顶部状态横幅改为明确完成态文案；`Phase2ParamPage` 展开态顶部提供「收起参数面板」按钮方便用户查看下方注释结果；
  3. `ProjectSelector.tsx` 在通过 URL `?project=<id>` 命中目标项目时同步触发 `onSelect(match)`，消除页面同时显示“已选项目”与“请先选择一个项目”的冲突状态；项目数达到配额上限时，按 `isGuest()` 区分文案（游客引导升级注册，正式用户提示已达当前账户项目上限）。

#### T1.8 顶栏假按钮/错链接、设置页假数据、管理后台硬编码与整合页背景修复
- **位置**：[frontend/src/app/dashboard/layout.tsx](../../frontend/src/app/dashboard/layout.tsx#L58-L75)、[dashboard/layout.tsx](../../frontend/src/app/dashboard/layout.tsx#L151-L165)、[frontend/src/app/page.tsx](../../frontend/src/app/page.tsx#L199-L230)、[frontend/src/app/dashboard/settings/page.tsx](../../frontend/src/app/dashboard/settings/page.tsx#L24-L55)、[frontend/src/app/dashboard/admin/page.tsx](../../frontend/src/app/dashboard/admin/page.tsx#L44-L55)、[admin/page.tsx](../../frontend/src/app/dashboard/admin/page.tsx#L230-L305)、[admin/page.tsx](../../frontend/src/app/dashboard/admin/page.tsx#L363-L370)、[frontend/src/app/dashboard/convert/page.tsx](../../frontend/src/app/dashboard/convert/page.tsx#L135)、[convert/page.tsx](../../frontend/src/app/dashboard/convert/page.tsx#L209)、[frontend/src/app/components/AuthModal.tsx](../../frontend/src/app/components/AuthModal.tsx#L177-L216)
- **改法**：
  1. **顶栏与首页导航**：GitHub 图标链接统一指向 `https://github.com/WeiLabCPU/scCloud`；首页导航修复 `#tech` 锚点（补齐对应锚点或移除无效项）；顶栏无实际功能的月亮图标与 `中` 按钮按确认项收口（默认推荐隐藏，待后续完整实现深色主题/国际化后再启用）；
  2. **设置页 (`settings/page.tsx`)**：通过 `apiFetch("/api/auth/me")` 拉取真实用户信息（`username`、`role`、`max_projects`、`total_quota`、`used_quota`、`retention_days`），并用 `getAuthItem()` 兼容 `sessionStorage`/`localStorage`，替换写死的 `"user"` 与 `5`；
  3. **用户管理后台 (`admin/page.tsx` + `dashboard/layout.tsx`)**：移除硬编码 `'Linli'`，改为依据 `/api/auth/me` 获取的当前管理员 `id`/`username` 禁止删除自身且不参与批量全选；角色列渲染补齐 `super`（付费用户）；8 列表格的加载与空态行修正为 `colSpan={8}`；编辑弹窗切回 `user` 角色时默认配额设 `10`（与后端 `register` 一致）；`dashboard/layout.tsx` 拿到 `/api/auth/me` 返回 `admin` 后立即更新 `navItems`；
  4. **样式变量与重复 JSX 属性**：`convert/page.tsx` 两处不存在的 `var(--clr-card)` 改为 `var(--clr-bg-card)`；合并 `AuthModal.tsx`（L177/196/216）三处重复 `style` 属性。

#### T1.9 字体完全本地化（消除国内首屏卡顿，且支持无代理离线 `docker build`）
- **位置**：[frontend/src/app/layout.tsx](../../frontend/src/app/layout.tsx#L16-L24)、[frontend/src/app/globals.css](../../frontend/src/app/globals.css#L41-L46)、[frontend/package.json](../../frontend/package.json)
- **关键工程约束**：`frontend/Dockerfile` 在国内或无外网环境执行 `npm run build` 时，若改用 `next/font/google` 会在编译阶段请求 `fonts.googleapis.com` 导致构建超时失败。
- **改法（已确认方案 B：中英文字体子集全量本地打包）**：
  1. 删除 `layout.tsx` 中所有指向 `fonts.googleapis.com` / `fonts.gstatic.com` 的外部 `<link>`；
  2. 英文、等宽与中文字体子集全部通过 `@fontsource/dm-sans`、`@fontsource/playfair-display`、`@fontsource/jetbrains-mono`、`@fontsource/noto-sans-sc`、`@fontsource/noto-serif-sc`（unicode-range 分片 `.woff2`）随前端静态资源本地打包构建，同时保留系统原生字体栈作回退，实现**构建期 + 运行期双 100% 离线零外链**。

---

### Batch 2：科研可视化、大数据散点性能、表格增强与大文件上传可控性（P2）

- **建议分支**：`feat/frontend-p2-viz-and-upload`

#### T2.1 科研结果图点击放大灯箱（`ImageLightbox`）与 Blob 内存泄漏修复
- **位置**：新增 `frontend/src/app/components/ImageLightbox.tsx`、修改 [ResultViewer.tsx](../../frontend/src/app/components/ResultViewer.tsx)、[QCResultTabs.tsx](../../frontend/src/app/components/QCResultTabs.tsx#L138-L147)
- **改法**：
  - 封装支持全屏预览、滚轮/按钮缩放平移、原图下载、`Esc`/点击背景关闭的 `ImageLightbox` 组件，接入 WGCNA、CellChat、Monocle、inferCNV、热图、小提琴图等限高图卡片；
  - 修复 `QCResultTabs.tsx` 中 `let objectUrl` 未赋值的 Bug，切换 Tab 或卸载时正确执行 `URL.revokeObjectURL(...)`。

#### T2.2 `DeckScatterPlot` 大规模散点图悬停 60fps 优化与 PCA 缩放修复
- **位置**：[frontend/src/app/components/charts/DeckScatterPlot.tsx](../../frontend/src/app/components/charts/DeckScatterPlot.tsx#L169-L316)、[DeckScatterPlot.tsx](../../frontend/src/app/components/charts/DeckScatterPlot.tsx#L558-L680)、[QCResultTabs.tsx](../../frontend/src/app/components/QCResultTabs.tsx)
- **改法**：
  - 使用 `useMemo` 预聚合每簇/每细胞类型数量映射表 `Map<string, number>` 并对 `LegendSidebar` 做 `React.memo`，消除悬停触发 60Hz 重渲染时每帧执行 `O(簇数 × 细胞数)` 全量遍历；
  - 根据坐标跨度动态计算 `minZoom`（允许负值 `minZoom`，如 `Math.min(-4, initialZoom - 2)`），彻底解决 PCA 大范围坐标下滚轮一动即剧烈跳变且无法缩回全景的问题。

#### T2.3 富集分析与 DEG 差异基因表格增强
- **位置**：[frontend/src/app/components/charts/EnrichBubble.tsx](../../frontend/src/app/components/charts/EnrichBubble.tsx#L57-L58)、[ResultViewer.tsx](../../frontend/src/app/components/ResultViewer.tsx)
- **改法**：
  - `EnrichBubble.tsx`：当 `p_adjust <= 0` 时使用非零极小值（如 `1e-300`）兜底避免 `Infinity`，并按数据范围做平方根缩放控制气泡像素直径；
  - `ResultViewer.tsx`：修复 `EnrichResult` 在 `plot_format === "pdf"` 时 CSV 下载路径替换错误；为 DEG 差异基因表增加基因名搜索过滤与按 `avg_log2FC` / `p_val_adj` / `pct.1` 点击列头排序；前端导出 CSV 统一做 RFC 4180 双引号转义（兼容含逗号的细胞类型名称）。

#### T2.4 大文件分片上传弹窗可控中断、状态重置与自动续期
- **位置**：[frontend/src/app/components/FileUploadModal.tsx](../../frontend/src/app/components/FileUploadModal.tsx#L50-L205)
- **改法**：
  - 接入 `AbortController` 与明确的「取消上传」按钮，取消时立即中止在途分片请求；上传进行中阻止误点遮罩关闭；
  - 每次重新打开弹窗时干净重置上一文件的完成状态与进度；
  - 分片上传及完成回调改走 `authedFetch`，支持长耗时上传期间 Access Token 过期自动续期。

#### T2.5 多样本整合页“一键导入到项目”（前后端联动）
- **位置**：[backend/app/convert/router.py](../../backend/app/convert/router.py)、`backend/tests/`、[frontend/src/app/dashboard/convert/page.tsx](../../frontend/src/app/dashboard/convert/page.tsx)
- **改法**：
  - 后端新增 `POST /api/convert/import-to-project`：校验 `is_path_owned_by_user()` 与目标项目归属 `project.user_id == current_user.id`，在服务端直接将整合产出的 `merged.rds`（及如存在的 `_groups.json`）复制到项目目录并保证权限；
  - 前端整合成功后支持下拉选择目标项目（或新建项目）并「直接导入并前往分析」，省去几百 MB RDS 先下载本地再重传服务器的往返等待；同时放开前端 `<input type="file">` 的 `accept` 以匹配后端已支持的 `.zip,.rds,.h5ad,.h5seurat,.h5,.loom`。

---

### Batch 3：响应式适配、对比度优化、依赖瘦身与 TypeScript / CI 门禁收口（P3）

- **建议分支**：`chore/frontend-p3-responsive-and-types`

#### T3.1 小屏/超宽屏响应式与定位修复
- **位置**：[dashboard/layout.tsx](../../frontend/src/app/dashboard/layout.tsx#L120)、[page.tsx](../../frontend/src/app/page.tsx#L291-L317)、[PipelineView.tsx](../../frontend/src/app/dashboard/analysis/components/PipelineView.tsx#L105)、[AddSampleDropdown.tsx](../../frontend/src/app/components/AddSampleDropdown.tsx)、[AnnotateResult.tsx](../../frontend/src/app/components/AnnotateResult.tsx#L1176)
- **改法**：
  - `dashboard/layout.tsx`：`< 768px` 增加移动端导航汉堡菜单抽屉；
  - `page.tsx`：移除导致窄屏标题缩成 22% 的非标准 `zoom: vw / 1680`，改用 CSS `clamp()` 与响应式栅格；
  - `PipelineView.tsx`：侧栏拖拽宽度改为基于容器 `getBoundingClientRect().left` 计算，消除宽屏居中偏移；
  - `AddSampleDropdown.tsx`：下拉锚点贴近触发按钮而不是固定在整张表顶部 `bottom-full`；
  - `AnnotateResult.tsx`：横向滚动表左侧 `sticky` 列补齐实色暖白背景，解决透字重叠。

#### T3.2 可读性对比度与交互细节打磨
- **位置**：[globals.css](../../frontend/src/app/globals.css) 及弹窗组件
- **改法**：
  - 适度加深 `--clr-text-faint`（提升暖白底色下的 WCAG 可读对比度）并收敛正文区 `< 11px` 极小字号；
  - 将 `.card:hover` 的 `translateY(-1px)` 限定到 `.card-interactive` 可点击卡片，消除参数大表单悬停时的整体微抖；
  - 将阻塞式的原生 `alert()` / `confirm()` 逐步替换为页面内联反馈与轻量确认弹窗，并统一支持 `Esc` 关闭。

#### T3.3 依赖瘦身、死代码清理与 TypeScript + GitHub Actions 前端门禁
- **位置**：[frontend/package.json](../../frontend/package.json)、[frontend/next.config.ts](../../frontend/next.config.ts)、`frontend/src/app/components/MarkersResult.tsx.txt`、`frontend/src/app/dashboard/page.tsx`、`.github/workflows/frontend-ci.yml`（新增）
- **改法**：
  1. 删除废弃草稿 [MarkersResult.tsx.txt](../../frontend/src/app/components/MarkersResult.tsx.txt)、冗余的不可达页面及未被引用的旧图表文件；移除重复引入的 `plotly.js` 与 `plotly.js-dist-min` 其一，降低前端镜像打包体积；
  2. 逐一修复 `tsc --noEmit` 检出的 **14 个文件共 60 处类型错误**（含 `PipelineView.tsx`、`ResultViewer.tsx`、`QCResultTabs.tsx`、`Phase2ParamPage.tsx`、`DeckScatterPlot.tsx` 等），随后移除 `next.config.ts` 中的 `typescript.ignoreBuildErrors: true`；
  3. 新增 `.github/workflows/frontend-ci.yml`，在 `frontend/**` 变更的 PR / `main` push 时自动运行 `npm ci` + `npx tsc --noEmit` + `npm run build`，补齐仓库前端 CI 门禁。

---

## 三、验证与本机 `:8091` 生效策略

### 3.1 每批 PR 交付验收标准
1. **类型检查**：
   - Batch 1 / Batch 2：执行 `cd frontend && ./node_modules/.bin/tsc --noEmit`，确保本次改动涉及文件 **0 错误**（不引入新增 TS 错误）；
   - Batch 3：移除 `ignoreBuildErrors: true` 后全仓 `./node_modules/.bin/tsc --noEmit` **0 错误**。
2. **生产构建**：`cd frontend && npm run build` 完整通过（含离线字体打包验证）。
3. **后端单测（Batch 2 涉及接口改动时）**：`cd backend && pytest -q` 全量通过。
4. **PR Review & CI**：每批以独立 PR 提至 `WeiLabCPU/scCloud`，关联并等待 CI / Bot Review 绿灯通过。

### 3.2 本机线上 `:8091` 生效方式
- PR 合入 `main` 后，拉取最新 `main` 并在仓库根目录执行：
  ```bash
  sh ./start.sh --build --no-pull
  ```
  （`start.sh` 已支持缺少 `r-engine/r-library` 时自动跳过 R 镜像构建，仅重建并重启 `frontend` / `backend` 容器）
- 重启后验证 `GET http://127.0.0.1:8091/`、`GET /healthz` 及核心界面交互回归。

---

## 四、开写代码前待确认的 3 个选项

1. **顶栏「月亮（深色模式）」与「`中`（语言切换）」空壳按钮怎么处理？**
   - **方案 A（推荐）**：在未做全站深色样式与英文词条前，**先隐藏这两个无响应空壳按钮**（保留已修正为 `WeiLabCPU/scCloud` 的 GitHub 图标），界面保持诚实干净；
   - **方案 B**：保留图标，点击弹出“功能开发/规划中”轻提示，或顺手接入基础深色变量切换。
2. **字体本地化范围怎么选？**
   - **方案 A（推荐）**：英文展示/正文/等宽字体（`DM Sans`、`Playfair Display`、`JetBrains Mono`）使用 `@fontsource` 本地随包构建，中文字体走高质量系统原生字体栈（`PingFang SC` / `Microsoft YaHei` / `Noto Sans CJK SC` / `Songti SC`）——完全离线、打包体积最小、首屏最快；
   - **方案 B**：连同中文字体子集一并本地打包（包体积会明显增大）。
3. **推进顺序**：确认以上两项后，是否按本计划先开分支实施 **Batch 1（P0 + P1）** 并提交第一个 PR？

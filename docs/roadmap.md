# 对标 Lightroom 的问题清单与演进路线

以原生 macOS（SwiftUI + Metal + GRDB）对标 Lightroom Classic 工作流，记录当前实现中的硬伤、功能缺口与分阶段优化方向。已完成项完成后直接删除，只保留现行待处理内容；已拍板的“不做”与“暂缓”边界见 [已定决策](decisions.md)，短期验收状态见 [当前状态](STATUS.md)。

## 一、当前存在的问题

### 1. 输入格式与机内色彩

- **底层仍强依赖 Apple `CIRAWFilter`**：[PhotoFileType.swift](../Sources/Imaging/PhotoFileType.swift) 与 [RAWDecoder.swift](../Sources/Imaging/RAWDecoder.swift) 已通过声明式格式注册表、容器完整性校验与薄解码抽象层开放 15 种常见 RAW 扩展名及静态 SDR HEIC／HEIF／HIF，但仍缺独立第三方 RAW 后端——个别损坏 RAW（如已复现的富士 RAF）在 Apple RAW 解码器下可能静默输出黑块，新机型与无损压缩支持受制于 macOS 更新；Apple DNG／ProRAW 与 HDR PQ／HLG HEIF 亦暂未开放。
- **相机风格缺少正式品牌资源**：[CameraLooks/manifest.json](../Sources/Imaging/CameraLooks/manifest.json) 目前仅有开发验证用的 `diagnostic.test-table`，正式版菜单为空；缺少跨品牌的机内色彩配置文件与自动识别，RAW 默认显色观感弱于 Lightroom 的相机匹配配置文件。

### 2. 显示与色彩管线

- **全线锁定 8-bit SDR sRGB**：[ImagePipeline.swift](../Sources/Imaging/ImagePipeline.swift) 与 [MetalPhotoView.swift](../Sources/UI/MetalPhotoView.swift) 将显示与输出统一固定在 `sRGB`／`RGBA8`，不支持 Display P3 广色域、10-bit 色深或 Apple XDR 屏幕的 HDR／EDR 显影预览。
- **限制软打样表现力**：内置软打样插件已落地（[插件系统方案](plugin-system.md)），但画布本身被裁切在 sRGB 内，超出 sRGB 但在打印机与 P3 屏范围内的颜色无法准确呈现。

### 3. 大图库查询与浏览性能

- **网格 200 张硬分页**：[AppModel.swift](../Sources/App/AppModel.swift) 仍以 `pageSize = 200` 分页，大图库选片需手动翻页，连续浏览体验不如虚拟滚动网格（查询、排序、堆叠翻页、关键词计数与集合计数已通过会话级 `temp.photoIndex` 与 `browseRevision` 缓存大幅提速，且未改动 schema 13）。
- **冷缓存整屏 RAW 浏览仍需等待逐张显影**：[ImagePipeline.swift](../Sources/Imaging/ImagePipeline.swift) 的 `ThumbnailService` 已启用双路有界渲染池与多路 JPEG 缩略图并发，但仍仅缓存 320 px 小图，缺少标准预览前置与“先出内嵌预览、再替换精准渲染”的分层机制（按 [decisions.md](decisions.md#暂缓) 暂缓）。

### 4. 渲染缓存与导出吞吐

- **RAW 高质量解码缓存命中条件偏严**：[ImagePipeline.swift](../Sources/Imaging/ImagePipeline.swift) 的栅格解码缓存已落地，但 RAW 的 `canCacheDecoded` 仍要求未做常规色调、裁剪、蒙版、暗角、颗粒或相机风格调整才复用解码缓冲；裁剪或调整下游色彩／曲线时仍常触发整图重解码（`ExportService` 已升级为有界多核并发导出，保留中断注入测试与结果顺序）。
- **已知性能与稳定性遗留**：质量图计算完成到主线程发布仍有约 0.1 s 等待；原 1 秒卡顿根因未完全证伪；构建与测试日志偶现 `MDB_MAP_FULL`（详见 [STATUS.md](STATUS.md#已知问题)）；合成精修重算等待时间仍长，16 GB 内存设备在大尺寸暗场／累计 PNG 场景容易触发内存预检拦截。

### 5. 分发合规、功能一致性与架构耦合

- **普通图像曝光响应表的合规风险**：[RasterExposure.swift](../Sources/Imaging/RasterExposure.swift) 采用 Lightroom 合成图输出拟合表，公开使用依据尚未判定，且大曝光下与 Lightroom 仍有差异。
- **正式版智能蒙版功能退化**：Release 构建会移除全部研究权重（[智能蒙版模型](smart-mask-models.md)），导致正式版对象选区禁用、人物部位不可用；`FaceParsing` 权重受训练数据非商业协议限制，LiteRT 完整依赖清单与正式模型分发机制尚未落地。
- **实现细节与文档不一致**：
  - [SpotRepair.swift](../Sources/Imaging/SpotRepair.swift) 中 `heal` 与 `remove` 共用完全相同的色调融合算法，缺少与模式名匹配的消除差异；
  - [Masking.swift](../Sources/Imaging/Masking.swift) 已定义 `intersect`（交集），但 [MaskPanel.swift](../Sources/UI/MaskPanel.swift) 未暴露 UI 入口；
  - [README.md](../README.md) 与 [README.zh.md](../README.zh.md) 仍称软打样未实现，部分缓存与支持目录仍沿用历史名 `OhMyLRC`，英文界面存在少量截断与措辞待打磨。
- **核心文件耦合偏重**：[AppModel.swift](../Sources/App/AppModel.swift)、[WorkspaceView.swift](../Sources/UI/WorkspaceView.swift)、[ImagePipeline.swift](../Sources/Imaging/ImagePipeline.swift) 与 [MetalPhotoView.swift](../Sources/UI/MetalPhotoView.swift) 体积过大，工具状态互斥与跨区交互高度集中，后续演进容易引入回归。

---

## 二、对标 Lightroom 的功能缺口

以下排除 [已定决策](decisions.md#不做) 中明确不做的项目（水印、完整 XMP sidecar 双向同步、自有预设包导出、持久恢复区）。

### 1. 显影、光学与蒙版

- **镜头光学与几何变换**：JPEG／TIFF 缺少镜头校正；全格式缺少手动畸变、裁剪前手动镜头暗角、手动缩放与 X/Y 位移，以及独立镜头配置库（如 Lensfun）。
- **相机原色校准与正式机内风格**：缺少红／绿／蓝三原色色相与饱和度校准（影响调色及 Lightroom／XMP 预设迁移还原度），以及正式校准的各品牌机内风格资源。
- **高频智能选区与交集操作**：缺少一键**选择天空**、**选择主体**、**选择背景**，以及蒙版**交集（Intersect）**的界面入口。
- **局部调整参数范围**：[Masking.swift](../Sources/Imaging/Masking.swift) 的 `LocalDevelopSettings` 暂不支持局部锐化、局部降噪、局部去边与局部点颜色。
- **跨照片同步范围**：[EditRecipe.swift](../Sources/Imaging/EditRecipe.swift) 的 `RecipePasteOptions` 尚不支持批量同步污点修复（如传感器批量除尘）和局部蒙版。
- **内容感知消除与 AI 降噪**：缺少真正的内容感知填补与现代 RAW AI 降噪（后者适合依托插件派生照片接入口承接）。

### 2. 图库管理、检索与画布交互

- **原生 macOS 画布手势**：[MetalPhotoView.swift](../Sources/UI/MetalPhotoView.swift) 未实现 `magnify(with:)` 触控板捏合缩放与 `scrollWheel(with:)` 滚动画布平移。
- **检索、排序与批量清理**：
  - 文本筛选仅支持文件名（[CatalogQueries.swift](../Sources/Catalog/CatalogQueries.swift)），不能检索题注、关键词或虚拟副本名；
  - 排序仅支持文件名、拍摄时间与星级，缺标旗、色标、文件类型、修改时间与宽高比；
  - 缺一键删除已排除（标 `X`）照片的快捷操作；
  - 关键词仅支持扁平列表，缺层级关键词与常用关键词组。
- **元数据编辑与图库快速调整**：图库右侧栏（[WorkspaceView.swift](../Sources/UI/WorkspaceView.swift)）元数据为只读，缺批量偏移／修正拍摄时间（多机位对表）和图库快速显影（Quick Develop）。
- **物理文件管理与副屏支持**：暂不支持在 App 内建子文件夹、移动或批量重命名原片；暂为单窗口，缺少独立副屏检片视图。

### 3. 导入与导出工作流

- **导入时批处理**：[ImportSheet.swift](../Sources/UI/ImportSheet.swift) 的导入时应用仅支持加入集合，缺自动套用显影预设／相机风格、批量添加关键词、复制导入时按模板重命名，以及监视文件夹自动导入。
- **导出规格与后处理**：[ExportOptions.swift](../Sources/Export/ExportOptions.swift) 仅支持长边像素上限与 sRGB JPEG／PNG／TIFF16，缺短边／宽高框／百分比缩放、输出文件体积上限、PPI／DPI 分辨率、现代格式（HEIF／AVIF／WebP／JXL）以及导出后动作。

### 4. 已暂缓但影响主力替代度的大项

以下已在 [已定决策](decisions.md#暂缓) 暂缓，待用户恢复优先级时再立项：

- 外部编辑往返（Edit In Photoshop／Affinity 等）；
- 离线可编辑代理（Smart Previews）；
- 集合组（Collection Sets）；
- 广色域输出与输出锐化。

---

## 三、分阶段优化优先级

### P0：扫清主力可用与正式分发阻塞

1. **大图库浏览续项**
   - 评估用连续虚拟滚动替代 200 张硬分页，并在用户恢复标准预览前置方案后补齐分层预览（当前会话级物化索引、`browseRevision` 缓存与双路缩略图渲染池已落地）。
2. **渲染缓存与交互手势续项**
   - 进一步放宽 RAW 解码／上游缓存复用条件（当前栅格解码缓存与 `ExportService` 有界多核并发已落地）；
   - 在 [MetalPhotoView.swift](../Sources/UI/MetalPhotoView.swift) 补齐触控板捏合缩放与滚动平移手势。
3. **解决正式发布阻塞项**
   - 分批校准并上架首批真实品牌机内相机风格资源，验证按机身／拍摄风格识别。
   - 先确立 Apache-2.0 模型（SAM 2.1 Tiny + SelfieMulticlass）的正式分发与按需安装机制，替换或隔离有非商业争议的 `FaceParsing` 权重，补全 LiteRT 依赖声明。
   - 明确 [RasterExposure.swift](../Sources/Imaging/RasterExposure.swift) 的合规决策或切换为独立开放曝光模型。

### P1：补齐高频摄影工作流

1. **实拍 RAW 验证与光学能力扩充**：基于 `CameraDiagnostics` 逐类补齐真实 CR2／ORF／RW2／PEF／3FR 样片实证，并推进独立 LibRaw 解码通道（覆盖坏片比特流检出与新机压缩模式）；补齐手动畸变、裁剪前暗角与位移缩放，评估接入 Lensfun 镜头库。
2. **高频闭环补齐**：
   - 复制／同步支持污点修复与蒙版；
   - 补齐蒙版 `Intersect` 入口、局部锐化／降噪／去边，以及选天空／主体／背景；
   - 明确区分或收敛 `SpotRepair` 的 `heal` 与 `remove` 模式；
   - 导入补齐预设、关键词与重命名；导出补齐文件大小限制、短边／宽高约束与 PPI；筛选补齐题注与关键词检索及一键清理标 `X` 废片。
3. **显示管线升级**：将画布升级至 Display P3 与 10-bit 色彩，释放软打样与广色域屏幕潜力。

### P2：架构治理与放大差异化优势

1. **渐进拆分超大核心文件**：按领域拆分 `AppModel`（图库查询、预览调度、局部工具、任务编排）与 `WorkspaceView`，降低回归面；清理遗留 `OhMyLRC` 目录名并同步过时文档表述。
2. **放大插件与 Agent 护城河**：
   - 完成第三方跨团队公证插件验证后，开放“派生照片”接入口（承接 AI 降噪、人像精修等重算插件），并按实测决定是否引入 `IOSurface` 减少大图跨进程拷贝开销；
   - 深化 Agent 摄影工作流能力（如连拍闭眼／合焦筛选、批量风格统一建议与语义检索），同时按主线逐步收敛 [STATUS.md](STATUS.md#待用户验收) 中积压的验收条目。

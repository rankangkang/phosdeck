# 对标 Lightroom 的问题清单与演进路线

以原生 macOS（SwiftUI + Metal + GRDB）对标 Lightroom Classic 工作流，记录当前实现中的硬伤、功能缺口与分阶段优化方向。已完成项完成后直接删除，只保留现行待处理内容；已拍板的“不做”与“暂缓”边界见 [已定决策](decisions.md)，短期验收状态见 [当前状态](STATUS.md)。

## 一、当前存在的问题

### 1. 输入格式与机内色彩

- **RAW 解码覆盖**：Metal Bayer 去马赛克已接入 Olympus E-10。扩展到其他机型前，需分别验证 CFA 排列、色彩、细节和重开一致性。iPhone XS 传感器 DNG 与 iPhone 12 Pro 线性 DNG 已验证，其他 Apple DNG 模式仍待实证。[实拍兼容性记录](getting-started.md#raw-兼容性记录)
- **相机风格**：随包提供富士 20 项、索尼 ST、佳能 EOS M50 与尼康 D750／D850 近似色表。佳能与尼康仅覆盖已测参考外观；索尼 α7R V 其余 9 项的再分发授权待确认。[资源清单](../Sources/Imaging/CameraLooks/manifest.json)

### 2. 显示与色彩管线

- **HDR 显示实证**：静态 PQ／HLG HEIF、HDR 合成母版与可选的 Apple RAW 高光预览已有浮点 EDR 输出。XDR 实屏亮度、外屏切换与不同环境光下的观感仍待验收。导出支持 SDR sRGB 与 Display P3。

### 3. 大图库查询与浏览性能

- **冷库长滚**：主网格支持连续虚拟滚动。缺少内嵌图及标准预览时仍需首次解码；外置卷、低电量与实拍大库的长滚表现待测。

### 4. 显影与精修性能

- **质量预览**：裁剪、色调和蒙版可复用同源、同上游参数的解码图，仍须区分 Core Image 延迟求值与实际像素缓存。复杂 RAW 的主线程尾延迟、IOSurface 峰值及实屏呈现待量测。
- **合成精修**：切换覆盖层可复用已渲染的来源与结果。新建全尺寸融合、复杂精修与 16 GB 设备内存预检仍需实拍验证。历史 `MDB_MAP_FULL` 缺可归因日志。

### 5. 分发合规、功能一致性与架构耦合

- **普通图像曝光响应表的合规风险**：[RasterExposure.swift](../Sources/Imaging/RasterExposure.swift) 采用 Lightroom 合成图输出拟合表，公开使用依据尚未判定，且大曝光下与 Lightroom 仍有差异。
- **正式版智能蒙版功能退化**：Release 构建会移除全部研究权重（[智能蒙版模型](smart-mask-models.md)），导致正式版对象选区禁用、人物部位不可用；`FaceParsing` 权重受训练数据非商业协议限制，LiteRT 完整依赖清单与正式模型分发机制尚未落地。
- **实现细节与历史命名**：部分缓存与支持目录仍沿用历史名 `OhMyLRC`，英文界面存在少量截断与措辞待打磨（蒙版检查器已补齐 `Intersect` 入口，`SpotRepair` 已明确说明 `Remove` 与 `Heal` 共用自动选源色调修复算法，README 已同步内置软打样状态）。
- **核心文件耦合偏重**：[AppModel.swift](../Sources/App/AppModel.swift)、[WorkspaceView.swift](../Sources/UI/WorkspaceView.swift)、[ImagePipeline.swift](../Sources/Imaging/ImagePipeline.swift) 与 [MetalPhotoView.swift](../Sources/UI/MetalPhotoView.swift) 体积过大，工具状态互斥与跨区交互高度集中，后续演进容易引入回归。

---

## 二、对标 Lightroom 的功能缺口

以下排除 [已定决策](decisions.md#不做) 中明确不做的项目（水印、完整 XMP sidecar 双向同步、自有预设包导出、持久恢复区）。

### 1. 显影、光学与蒙版

- **镜头光学与几何变换**：JPEG／TIFF 缺少镜头校正；全格式缺少手动畸变、裁剪前手动镜头暗角、手动缩放与 X/Y 位移，以及独立镜头配置库（如 Lensfun）。
- **相机原色校准与正式机内风格**：缺少红／绿／蓝三原色色相与饱和度校准（影响调色及 Lightroom／XMP 预设迁移还原度），以及正式校准的各品牌机内风格资源。
- **高频智能选区**：缺少一键**选择天空**、**选择主体**、**选择背景**。
- **局部调整参数范围**：[Masking.swift](../Sources/Imaging/Masking.swift) 的 `LocalDevelopSettings` 仍缺局部去边与局部点颜色。
- **内容感知消除与 AI 降噪**：缺少真正的内容感知填补与现代 RAW AI 降噪（后者适合依托插件派生照片接入口承接）。

### 2. 图库管理、检索与画布交互

- **关键词组织**：关键词支持扁平列表，缺层级关键词与常用关键词组。
- **元数据编辑与图库快速调整**：图库右侧栏（[WorkspaceView.swift](../Sources/UI/WorkspaceView.swift)）元数据为只读，缺批量偏移／修正拍摄时间（多机位对表）和图库快速显影（Quick Develop）。
- **物理文件管理与副屏支持**：暂不支持在 App 内建子文件夹、移动或批量重命名原片；暂为单窗口，缺少独立副屏检片视图。

### 3. 导入与导出工作流

- **导入时批处理**：[ImportSheet.swift](../Sources/UI/ImportSheet.swift) 的导入时应用仅支持加入集合，缺自动套用显影预设／相机风格、批量添加关键词、复制导入时按模板重命名，以及监视文件夹自动导入。
- **导出规格与后处理**：[ExportOptions.swift](../Sources/Export/ExportOptions.swift) 仅支持长边像素上限与 sRGB／Display P3 JPEG、PNG、TIFF16，缺短边／宽高框／百分比缩放、输出文件体积上限、PPI／DPI 分辨率、现代格式（HEIF／AVIF／WebP／JXL）以及导出后动作。

### 4. 已暂缓但影响主力替代度的大项

以下已在 [已定决策](decisions.md#暂缓) 暂缓，待用户恢复优先级时再立项：

- 外部编辑往返（Edit In Photoshop／Affinity 等）；
- 离线可编辑代理（Smart Previews）；
- 集合组（Collection Sets）；
- 输出锐化。

---

## 三、分阶段优化优先级

### P0：扫清主力可用与正式分发阻塞

1. **实机验证**：测量冷库长滚、复杂 RAW 切换、合成精修与物理显示耗时，收集可复现样本。
2. **正式发布阻塞项**
   - 确认索尼其余机内风格的再分发依据，继续使用同帧 RAW／JPEG 对照校准跨品牌色表。
   - 先确立 Apache-2.0 模型（SAM 2.1 Tiny + SelfieMulticlass）的正式分发与按需安装机制，替换或隔离有非商业争议的 `FaceParsing` 权重，补全 LiteRT 依赖声明。
   - 明确 [RasterExposure.swift](../Sources/Imaging/RasterExposure.swift) 的合规决策或切换为独立开放曝光模型。

### P1：补齐高频摄影工作流

1. **机型覆盖与镜头校正**：扩展已验证的 RAW 机型与模式；补齐手动畸变、裁剪前暗角与位移缩放，评估 Lensfun 镜头库。
2. **高频闭环补齐**：
   - 补齐局部去边与点颜色，以及选天空／主体／背景；
   - 导入补齐预设、关键词与重命名，导出补齐文件大小限制、短边／宽高约束与 PPI。
3. **HDR 工作流**：在 XDR 与外接 SDR 屏核对同一配方，扩充 HDR 的相机与输出模式。

### P2：架构治理与放大差异化优势

1. **渐进拆分超大核心文件**：按领域拆分 `AppModel`（图库查询、预览调度、局部工具、任务编排）与 `WorkspaceView`，降低回归面；清理遗留 `OhMyLRC` 目录名并同步过时文档表述。
2. **放大插件与 Agent 护城河**：
   - 完成第三方跨团队公证插件验证后，开放“派生照片”接入口（承接 AI 降噪、人像精修等重算插件），并按实测决定是否引入 `IOSurface` 减少大图跨进程拷贝开销；
   - 深化 Agent 摄影工作流能力（如连拍闭眼／合焦筛选、批量风格统一建议与语义检索），同时按主线逐步收敛 [STATUS.md](STATUS.md#待用户验收) 中积压的验收条目。

# 架构地图与代码导航

面向开发与 AI Agent 的仓库结构、分层边界、核心不变量和定向测试映射。只记录现行架构事实；开发红线见 [AGENTS.md](../AGENTS.md)，性能与构建运维见 [工程手册](engineering.md)。

## 目录与模块全景

| 位置 | 职责 | 边界约束 |
|---|---|---|
| `Sources/Files/` | 安全文件发布（`SafeFileWriter`）、沙箱书签、根目录重定位、存储统计 | 禁止 `SwiftUI`／`AppKit`／`MCP`／`NIO*` |
| `Sources/Imaging/` | 配方（`EditRecipe`）、`ImagePipeline`、`ThumbnailService`、`RAWDecoder`、色表、蒙版、污点、多帧合成、智能蒙版与相机诊断 | 唯一允许依赖 `LibRawRuntime`、`CLiteRT`、`CoreML`、`Vision`；禁止 `SwiftUI`／`AppKit` |
| `Sources/Catalog/` | GRDB/SQLite 图库（`.phoscat`）、旧后缀改名、分页／物化索引查询、关键词、智能集合、堆叠、RAW/JPEG 配对、局部预设与整库归档 | 禁止 `SwiftUI`／`AppKit`／`MCP`／`NIO*`；当前 `CatalogStore.schemaVersion = 13`，不做旧 schema 迁移 |
| `Sources/Import/` | 引用与复制导入、导入规划、冲突处理、中断恢复、文件夹差异与 Lightroom Classic 只读导入 | 禁止 `SwiftUI`／`AppKit`／`MCP`／`NIO*` |
| `Sources/Export/` | JPEG／PNG／TIFF16 导出、命名模板、元数据写入、批次计划与中断恢复 | 禁止 `SwiftUI`／`AppKit`／`MCP`／`NIO*` |
| `Sources/Plugins/` | 随包 ExtensionKit 内置插件（`SoftProof`、`Highlights`、`WarmPrint`） | 仅依赖 `PhosdeckPluginKit` 与系统图像框架；禁止 `SwiftUI`／`AppKit` |
| `Sources/App/` | 应用入口、`AppModel`、键盘与工作区编排、撤销／重做、插件宿主与本地 MCP 服务（`AppMCP*.swift`、`MCPHTTPListener.swift`） | 唯一允许依赖 `MCP` 与 `NIO*` |
| `Sources/UI/` | SwiftUI 暗房仪表界面、SDR Display P3／HDR 浮点 Metal 画布（`MetalPhotoView`）、面板与自定义控件 | 仅负责展示与交互，禁止引入 `MCP`、`NIO*`、`LibRawRuntime`、`CLiteRT` |
| `Packages/PhosdeckPluginKit/` | 宿主与插件共享协议、数据结构与 IPC 编解码 | 宿主与插件共同依赖 |
| `Packages/SmartMaskRuntime/` | LiteRT 桥接与本地智能蒙版推理运行时 | 仅由 `Sources/Imaging/` 调用；Release 不打入研究权重 |
| `Packages/LibRawRuntime/` | 纯净 LGPL-2.1 `LibRaw 0.22.3` 封装（不含 GPL 扩展包），提供比特流校验、传感器标签、兜底解码与已验证 Bayer 模式的 Metal 插值 | 仅由 `Sources/Imaging/` 调用 |
| `.agents/skills/phosdeck/` | 随包分发的 MCP 操作 Skill 及各领域参考文档 | 改动 MCP 工具或行为时同步更新 |
| `Config/`、`scripts/`、`site/` | Xcode 构建配置、检查／打包／校准脚本、Astro 中英官网 | 原生构建不依赖 Node.js 或 Rust |

上述 import 边界及 `project.pbxproj` 文件登记由 `python3 scripts/check-harness.py` 自动守护。

## 核心工程不变量

- **显影与色彩语义**：草稿、质量预览、缩略图和导出共用管线约定；保持既有显影顺序、线性／感知 sRGB 与透明度语义。TIFF16 直接从浮点渲染管线量化为 16 位整数，不经过 8 位预览。
- **中性观片底**：UI 复用 [设计 Token v3](../design/darkroom_instrument_tokens_v3.json)，主题只改变界面外观，不得改变图像像素或观片底中性。
- **文件安全发布**：所有落盘发布沿用 `SafeFileWriter`（同卷暂存 → `fsync` → `renamex_np(..., RENAME_EXCL)` 无覆盖发布 → 回读核验），禁止用普通 `rename` 替代；只清理已确认归属本任务的暂存文件。
- **数据与无迁移约定**：开发阶段拒绝旧 schema、旧配方与不兼容任务，不写兼容层或迁移脚本；同时保护当前图库、原片和备份，不能以“不兼容”为由清空或覆盖。`.omlcat`／`.omlrcat` 仅允许打开时确认同目录无覆盖改后缀，不改数据库内容。
- **原生与 MCP 共享真源**：MCP 工具通过 `Sources/App/AppMCP*.swift` 复用原生工作区、事务与撤销栈；不另起独立持久化逻辑。

## 超大核心文件速查

修改以下高频文件前先定位具体分区，避免全文件盲读或无意扩大观察范围：

- `Sources/App/AppModel.swift`：顶部定义工作区状态类型（`WorkspaceMode`、`DevelopTool`、`BrowseLocation`、`TaskProgress` 等），主体 `AppModel` 负责图库会话、查询刷新、预览调度与撤销编排，各领域编辑逻辑拆在同目录 `*Editing.swift` 与 `AppMCP*.swift` 扩展中。
- `Sources/UI/WorkspaceView.swift`：按 `MARK` 分为 `Top bar`、`Left panel`、`Center`、`Inspector`、`Filmstrip and status`，底部包含 `PhotoViewingInfo`、`WorkspaceDimensions`、`WorkspaceResizeHandle` 等局部子视图。
- `Sources/Imaging/ImagePipeline.swift`：包含 `ImageRequest`／`RenderedImage`、核心 `actor ImagePipeline`（解码缓存、显影、预览、直方图）与底部的 `actor ThumbnailService`（有界渲染池与磁盘缓存）。
- `Sources/UI/MetalPhotoView.swift`：包含 `MetalPhotoView`、`CanvasFrameRenderer`、`PhotoMetalCanvas`（SDR 10 位 Display P3、HDR 半浮点 EDR 呈现与触控板手势）、`DisplayOverlay`、`PhotoViewport` 与蒙版／污点覆盖状态。
- `Sources/Catalog/CatalogStore.swift`：定义 `schemaVersion`、`CatalogStore` 读写事务与版本修订；复杂筛选与物化索引查询在 `CatalogQueries.swift`，堆叠／关键词／配对／智能集合／归档拆在各自文件。
- `Sources/App/AppMCPTools.swift`：注册全部 `AppMCPTool` 枚举与统一分发入口，具体动作实现按域拆在 `AppMCP*.swift`。

## 改动域与定向测试映射

定向运行单类测试：

```sh
xcodebuild -project Phosdeck.xcodeproj -scheme Phosdeck -derivedDataPath build -destination 'platform=macOS' -only-testing:PhosdeckTests/<TestClass> test
```

| 改动域 | 优先运行的定向测试类 |
|---|---|
| 基础与文件安全 | `FoundationTests`、`RecoveryTests`、`CatalogFileTests`、`CatalogArchiveTests` |
| 图库查询、筛选与大图库性能 | `CatalogQueryTests`、`LargeCatalogPerformanceTests`、`BrowseHistoryTests`、`SmartCollectionTests` |
| 组织（关键词、色标、集合、堆叠、虚拟副本、配对） | `KeywordTests`、`ColorLabelTests`、`CollectionOrderingTests`、`StackTests`、`VirtualCopyTests`、`RawJpegPairTests`、`ComparisonTests` |
| 导入、文件夹差异与 Lightroom 迁移 | `ImportTests`、`FolderReviewTests`、`LightroomImportTests`、`XMPPresetImportTests` |
| 输入格式、RAW 解码与 LibRaw | `InputFormatTests`、`LibRawRuntimeTests`、`MoreRAWTests`、`RAWAdaptationTests`、`CameraDiagnosticsTests`、`PNGTests` |
| 全局显影、曝光、色彩、曲线与相机风格 | `DevelopTests`、`DevelopV2Tests`、`TonalTests`、`FreeCurveTests`、`BlackWhiteMixerTests`、`PointColorTests`、`RasterEditingTests`、`RasterIdentityTests`、`AlphaTests`、`CameraLookTests`、`GeneralDetailTests`、`NoiseReductionTests`、`ManualDefringeTests`、`CreativeVignetteTests`、`FilmGrainTests` |
| 自动调整、目标调整与直方图交互 | `AutomaticAdjustmentTests`、`TargetedAdjustmentTests`、`DirectAdjustmentTests`、`AdjustmentPreviewTests` |
| 几何、裁剪、翻转与参考线 | `PerspectiveTests`、`UprightTests`、`FlipTests` |
| 蒙版、智能蒙版、污点与局部预设 | `MaskingTests`、`SmartMaskTests`、`SpotRepairTests`、`LocalParameterPresetTests`、`PatchMatchPrototypeTests` |
| 多帧合成、精修与星轨 | `PhotoMergeTests`、`PhotoMergeFinishTests`、`FocusStackRegressionTests` |
| 预设与工作流 | `PresetManagementTests`、`PresetIntensityTests`、`WorkflowTests`、`WorkflowEfficiencyTests`、`WorkflowReuseTests`、`InspectionWorkflowTests` |
| 导出与元数据 | `ExportTests`、`ExportNamingTests`、`ExportMetadataTests`、`MultiExportTests` |
| 插件系统 | `PluginSystemTests` |
| Agent／MCP 接入 | `AgentMCPTests`、`AgentLibraryTests`、`AgentOrganizationTests`、`AgentDevelopTests`、`AgentOutputTests`、`AgentMaintenanceTests` |
| 界面、画布与国际化 | `ImagingTests`、`LocalizationTests` |
| 可选授权／公开样片（缺样片自动跳过） | `AuthorizedRAWTests`、`AuthorizedScaleTests`、`AuthorizedVolumeTests` |

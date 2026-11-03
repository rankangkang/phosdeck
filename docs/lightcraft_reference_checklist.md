# lightcraft 借鉴清单

本清单对照 lightcraft 固定版本，登记原生 macOS 版各功能的状态、仍有效的限制与取舍、代码入口和上游参考，供排期和实施时查阅。

## 上游基准与实施规则

仓库：<https://github.com/storytold/lightcraft>。下文 `lc:` 路径默认相对 `f34c7a8`，另注版本的除外。

| 提交 | 用途 |
|---|---|
| `5436951`（543695129932，2026-10-10） | 早期落地项的原参考：预设强度 apply_partial、自动蒙版画笔、创作暗角 Vig |
| `f34c7a8`（f34c7a8a89e0，2026-10-16 主线） | 整体对照基准；JPEG/TIFF 编辑、PatchMatch 候选参考此版本 |
| `4f0b110`（4f0b110bcbd2，2026-10-18 主线） | 后续批次来源补查与适配（黑白、透视、曲线、保持结果、输入边界），以及堆叠、RAW/JPEG、虚拟副本、智能集合、点颜色、预设管理、题注、快照删除、原片定位、关键词改名 |
| `56b5c8b` | Lightroom Classic XMP 预设子集导入 |
| `59a5d00` | 智能蒙版确认前检查 |

- 更新基准不等于已移植上游后续变化；对照只读源码，未编译或运行 lightcraft。实施前先固定上游提交，读对应源码、调用方和测试，分别记录直接移植／借鉴／原生自有／未采用及原因（详见 [AGENTS.md](../AGENTS.md)）。
- 早期 12 批中只有 JPEG/TIFF 编辑当时记录了具体上游路径；补查结论不能倒填为当时已参考，也不能把原生实现统称为上游移植；预设管理、题注、快照删除、原片定位、关键词改名、智能蒙版检查均无直接源码移植。
- 上游仍标 Alpha，其覆盖率、机型数和耗时不能当作我们的结论；ROADMAP、gaps.md、ui-parity.md 与源码有不同步之处，以源码为准。

## 状态与优先级

| 状态 | 含义 |
|---|---|
| 已实现 | 已有实现，且用户对本项检查用副本有观感确认；确认范围限于当时检查的内容 |
| 待验收 | 已有实现或测量，仍缺照片观感、实际工作流复核或用户取舍；不重复列为待开发 |
| 未实现 | 差异尚未补齐；备注区分已有基础与新增部分 |

- P0：已有实现，先补人工验收与已有取舍（所有待验收项集中于此）。P1：日常流程。P2：工作流增强与候选。P3：高级扩展与后置决定。
- “候选”需结合实际需要由用户决定，不因上游有入口而成为已批准任务；需选型、改变局部工具能力或扩大范围的项目先由用户决定。自动化结果不等于人工验收；人工检查只用仓库约定允许的样本和检查用副本。

## 处理标识约定

- 黑白混色器必需 `oklch-bw-v2`；手动透视必需 `camera-rotation-v2`；普通图像配方为 `imageio-raster-response-v4`（配套 `raster-exposure-colour-v4.bin`）。
- 旧标识、旧普通配方 v1–v3、缺翻转字段的旧配方、旧曲线输出数组一律明确拒绝并保留原数据，不做迁移或兼容层。已有版本字段不等于采用上游长期冻结处理版本策略；该策略发布后再议。

## 已实现：有用户观感确认（2026-10-12，不覆盖后续公式改动或整个应用）

| 项目 | 说明 | 入口 |
|---|---|---|
| 打标后前进与星级增减 | Shift 配合评级／旗标后前进；方括号按原星级增减，整批一次撤销 | [WorkspaceKeyboard](../Sources/App/WorkspaceKeyboard.swift) |
| 原图对照三种方式 | 反斜杠切换原图（沿用用户确定的切换语义，非上游按住查看），Y 并排，Shift+Y 分屏 | [WorkspaceView](../Sources/UI/WorkspaceView.swift) |
| 剪切显示 | J 切换过曝／欠曝，只作用于显示层；色域警告另列 P3 | [MetalPhotoView](../Sources/UI/MetalPhotoView.swift) |
| 蒙版五种查看方式 | 彩色叠加、黑白叠色、黑底、白底、黑白蒙版；不进入导出 | [MaskPanel](../Sources/UI/MaskPanel.swift) |

## P0：待验收（依次为图库、预设、显影、输入输出、蒙版修复与性能）

| 项目 | 仍有效的限制／未做部分 | 入口 |
|---|---|---|
| 图库排序与组合筛选 | 文件名逐 Unicode scalar 小写词典序，未实现自然数排序；导入／编辑时间排序未做 | [CatalogQueries](../Sources/Catalog/CatalogQueries.swift)；lc:crates/catalog/src/query.rs、rules.rs |
| 保持筛选结果到手动刷新 | 固定全结果成员与顺序，新增匹配者不进入（与上游动态纳入不同）；改条件／排序／来源或手动刷新时重建 | 同上；lc:crates/engine/src/cmd/library.rs、tests_hold_view.rs |
| 智能集合 | 全部／任一规则、绑定 SQL、来源限制；不含复杂嵌套或递归 | [SmartCollections](../Sources/Catalog/SmartCollections.swift)；lc:crates/catalog/src/rules.rs |
| 虚拟副本 | 独立来源身份与版本，历史／快照／组织隔离，删除保护 | [AppModel](../Sources/App/AppModel.swift) |
| 完整堆叠 | 合并／拆分／封面／间隔预览，全查询排列后分页 | [PhotoStacks](../Sources/Catalog/PhotoStacks.swift)、[StackEditing](../Sources/App/StackEditing.swift)；lc:crates/catalog/src/stacks.rs |
| RAW/JPEG 来源关联 | 稳定来源一对一；同名文件组／附件与稳定来源关系分开 | [RawJpegPairs](../Sources/Catalog/RawJpegPairs.swift)、[PairEditing](../Sources/App/PairEditing.swift)；lc:crates/engine/src/cmd/organize.rs |
| 快照删除与一次撤销／重做 | 原字节恢复、切库保护；不含快照内容更新及创建／改名撤销 | [AppModel](../Sources/App/AppModel.swift)、[CatalogStore](../Sources/Catalog/CatalogStore.swift) |
| 单张原片安全定位 | 核验后更新同源全部版本，保留旧冻结输出；不做自动搜索 | [AppModel](../Sources/App/AppModel.swift) |
| 平面关键词全库改名 | 重名拒绝、一次事务整次撤销；不含层级或自动合并 | [CatalogKeywords](../Sources/Catalog/CatalogKeywords.swift)、[KeywordEditor](../Sources/UI/KeywordEditor.swift) |
| 版本颜色标签 | 已接通 | [ColorLabelKeys](../Sources/UI/ColorLabelKeys.swift) |
| 题注编辑与关键词／题注嵌入成片 | JPEG／PNG／TIFF；不含水印、标题／作者／版权、完整 XMP 双向同步 | [CatalogKeywords](../Sources/Catalog/CatalogKeywords.swift)、[ExportMetadata](../Sources/Export/ExportMetadata.swift) |
| 预设强度 0–200% | 整数与开关以 50% 切换；粘贴／同步不带强度；保存预设不写蒙版 | [PresetManagement](../Sources/App/PresetManagement.swift) |
| 自有预设管理 | 搜索／分组／收藏／更新／改名删除撤销；不保存蒙版／修复位置，不覆盖来源基线；预设包交换见 P1 | 同上、[PresetBrowser](../Sources/UI/PresetBrowser.swift)；lc:crates/ui-egui/src/panels/presets.rs（4f0b110） |
| 局部命名参数预设 | 复制／粘贴与一次撤销；不传递选区、组件和强度；完整局部 Effect 管理见 P2 | [CatalogLocalPresets](../Sources/Catalog/CatalogLocalPresets.swift)、[LocalParameterPreset](../Sources/Imaging/LocalParameterPreset.swift) |
| Lightroom XMP 预设子集导入 | 只承诺全局字段近似转换；蒙版／修复／几何／Profile 不转换并报告；稀疏应用保留未声明参数，见 C 节 | [XMPPresetReader](../Sources/Import/XMPPresetReader.swift)、[XMPPresetSettings](../Sources/Imaging/XMPPresetSettings.swift)；lc:crates/engine/src/crs.rs（56b5c8b） |
| JPEG/TIFF 非破坏性编辑 | 不经 RAW 基础外观；RAW 专属细节隐藏；跨 RAW／成片同步白平衡保留目标值并说明 | [ImagePipeline](../Sources/Imaging/ImagePipeline.swift) |
| 普通图像零参数基线 | PNG/TIFF 逐像素恒等；高频彩色 JPEG 相对 ImageIO 本机最多 4 LSB 差，预览解码器未改 | 同上 |
| 自由点曲线 | 每通道 2–16 点、端点输入固定、间距 ≥0.1%，不等距保形 Hermite；参数曲线见 P3 | [TonalPipeline](../Sources/Imaging/TonalPipeline.swift)、[ToneCurvePanel](../Sources/UI/ToneCurvePanel.swift) |
| 黑白混色器 | 4f0b110 OkLCh raised-cosine 选段；曲线与 HSL 后、分级前；全零保留原黑白路径 | [DevelopAdjustments](../Sources/Imaging/DevelopAdjustments.swift) |
| 点颜色 | PointK 公式、8 个样本、浮点阶段取色；实际指针待验收 | [PointColor](../Sources/Imaging/PointColor.swift)、[PointColorPanel](../Sources/UI/PointColorPanel.swift) |
| 手动透视校正 | 4f0b110 虚拟相机旋转＋面积归一化；顺序 EXIF→90°→拉直→透视／纵横→约束／裁剪→翻转 | [PhotoGeometry](../Sources/Imaging/PhotoGeometry.swift)；lc:crates/pipeline/src/geometry.rs |
| 水平／垂直翻转 | 按最终裁剪画幅翻转，取样与蒙版／修复共用几何 | [EditRecipe](../Sources/Imaging/EditRecipe.swift)、[PhotoGeometry](../Sources/Imaging/PhotoGeometry.swift) |
| 创作暗角 | 按裁剪后画面计算；与镜头暗角校正独立 | [CreativeVignette](../Sources/Imaging/CreativeVignette.swift) |
| 颗粒 | 种子进入配方，按最终画面计算 | [FilmGrain](../Sources/Imaging/FilmGrain.swift) |
| 通用编辑锐化 | 默认 0，跨 RAW/JPEG/TIFF/PNG；输出锐化另列 P2；指针拖动未补查 | [GeneralDetail](../Sources/Imaging/GeneralDetail.swift)；lc:crates/pipeline/src/local.rs、finish.rs |
| 基础亮度／彩色降噪 | 默认 0；先降噪后锐化、在颗粒前；弱纹理保守取舍待验收；不含 AI 降噪 | 同上；lc:crates/pipeline/src/local.rs::nr_params/apply_nr、tests_nr_scale.rs |
| 更多 RAW 输入 | 仅已测 8 张公开样片的机型／压缩方式；Apple DNG/ProRAW 因重复显影偏色明确拒绝；不宣称全格式 | [PhotoFileType](../Sources/Imaging/PhotoFileType.swift) |
| 多格式 RAW 细节与光学 | 复用 Apple 降噪／锐化／镜头校正，按每张能力开放，同步时逐字段略过；镜头切换后蒙版／修复对齐待验收 | [EditRecipe](../Sources/Imaging/EditRecipe.swift) |
| PNG 正式导入、透明度与 JPEG 铺底 | 静态 8/16 位及 8 位调色板；APNG／低位深／损坏拒绝；尺寸预算在 IHDR 后、inflate 前；JPEG 须明确选黑／白铺底 | [PNGValidation](../Sources/Imaging/PNGValidation.swift) |
| 导出命名模板 | 240 字节上限，同批及已有冲突阻止入队，晚到冲突失败不覆盖 | [ExportNaming](../Sources/Export/ExportNaming.swift) |
| 导出元数据选项 | 默认不附带；GPS／序列号／源路径／MakerNotes／XMP／缩略图／配方不开放 | [ExportMetadata](../Sources/Export/ExportMetadata.swift) |
| 多规格交付 | 已接通 | [MultiExport](../Sources/App/MultiExport.swift) |
| 颜色范围亮度降权与容差 | 10-12 查看方式确认不覆盖改公式后的选区与边缘 | [Masking](../Sources/Imaging/Masking.swift) |
| 自动蒙版画笔 | 复杂边缘、连续绘制、擦除及预览／导出观感待查 | 同上 |
| 仿制、修复与自动选源消除 | 待重开、裁剪／旋转与不同输出尺寸复核；不能当作 Fill 完成 | [SpotRepair](../Sources/Imaging/SpotRepair.swift)、[SpotEditing](../Sources/App/SpotEditing.swift) |
| AI 选区及结果持久化 | 本地研究实现；原生精细脸肤／眉毛／整只眼睛／嘴唇，自动定位、手动框与恢复自动定位；精分失败保留粗部位且不缓存失败。SAM 先放大浮点场再取 0 阈值，粗皮肤支持度约束精细脸肤；固定基准没有对应五官解析，无代码移植。头盔、贴脸遮挡、发丝、轮圈、水线与水花仍有漏选／误选，非抠图 alpha；总体精度和端到端延迟未测。人脸权重分发、天空／背景入口及文字描述选择未完成 | [SmartMaskEngine](../Sources/Imaging/SmartMaskEngine.swift)、[SmartMaskEditing](../Sources/App/SmartMaskEditing.swift)；lc:docs/ai-masks.md、crates/engine/src/segment.rs（59a5d00）；SAM 2 放大顺序见[上游后处理](https://github.com/facebookresearch/sam2/blob/2b90b9f5ceec907a1c18123530e92e794ad901a4/sam2/utils/transforms.py#L117) |
| 智能蒙版确认前检查、多人与部位缓存 | 44 pt 圆形头像、多人同部位先合并、短窗口固定创建键待用户体验；纯 hover 与减少动态效果未测。保留覆盖率／alpha 语义；当前来源内部位缓存 16 条／32 MiB，命中仍核验摘要（借鉴上游内容／参数缓存键，无代码移植）；保存结果按整体种子再编辑。对象队列、跨照片缓存与逐人索引持久化留后续 | [SmartMaskPanel](../Sources/UI/SmartMaskPanel.swift)；参考 59a5d00 |
| 多蒙版选区栅格复用 | 仅交互预览；RGBA32F 每通道上限 128 MiB；局部显影仍逐个按序执行；质量图与导出走原管线 | [Masking](../Sources/Imaging/Masking.swift) |
| 100% RAW 解码复用 | 仅已核验颜色子集、解码器 8；排除裁剪，空间／曲线／蒙版／非中性对比度走原路径；单张上限 512 MiB；摘要失败清缓存 | [ImagePipeline](../Sources/Imaging/ImagePipeline.swift) |
| 图库按变化范围刷新 | 评级不重查无关侧栏和历史，关键词修改仍更新统计 | [AppModel](../Sources/App/AppModel.swift) |

## P1：日常流程

| 项目 | 状态与边界 | 上游参考 |
|---|---|---|
| 自有预设包导入／导出 | 未实现；用户决定当前不做 | lc:crates/ui-egui/src/panels/presets.rs（4f0b110） |
| 小区域内容感知填补 Fill | 未实现。测试专用多尺度 PatchMatch 候选有透视接缝错位／斜边残留，效果不足，不接正式入口；不选 AI 模型 | lc:crates/inpaint/src/lib.rs、spots.rs、ui-egui/src/panels/right.rs |

## P2：工作流增强与候选（未实现部分）

| 项目 | 状态与边界 | 上游参考 |
|---|---|---|
| 元数据编辑与 XMP 交换 | 标题／作者／版权、评级交换、XMP 附件读取／合并／写回未实现；完整 XMP 元数据交换用户决定不做 | lc:docs/xmp-interop.md、crates/meta/src/xmp_merge.rs |
| 层级关键词、关键词合并 | 未实现；目录结构只服务当前版本，不迁移旧目录 | lc:crates/catalog/src/keywords.rs |
| 集合组 | 待真实项目需求再定 | — |
| 其他 RAW 模式；HEIC 候选 | 其他机型／压缩、BigTIFF DNG、HEIC 未验证或未开放，不能由已测样片推断 | lc:docs/raw-parity.md、file-format-parity.md |
| 其余光学缺口 | 独立色差／去紫边、手动畸变、镜头数据库未实现 | lc:crates/pipeline/src/optics.rs、docs/lens-profiles.md |
| 局部工具预设与画布效率 | 完整局部 Effect 分组／收藏／查找／悬停、Shift 直线笔触、笔压、图钉策略、画布键盘未做；保留 Shift 追加取样与渐变角度吸附 | lc:crates/engine/src/cmd/mask_effects.rs、mask_effect_files.rs、ui-egui/src/canvas_keys.rs |
| 灰尘检测与选片辅助 | 灰尘候选可接现有修复；对焦点需按机型确认（上游仅验证 Sony α1／A7S III）；清晰度／连拍评分为范围外候选，需用户决定 | lc:crates/pipeline/src/dust.rs、cull.rs、docs/focus-points.md |
| AI 降噪及更复杂消除 | 未选模型；上游可选 RawNIND 权重为 GPL-3.0，不可采用；先核实许可、输入、硬件、耗时与画质 | lc:docs/denoise.md |
| 输出锐化与目的地选项 | 未实现，缺摄影证据暂缓；水印用户决定不做；继续按照片报告失败和冲突，不覆盖原片 | lc:crates/engine/src/export.rs |

## P3：高级调整与后置决定（未实现）

| 项目 | 边界 | 上游参考 |
|---|---|---|
| 参数曲线、曲线饱和度修正 | 后者不是解决过冲，需单独对照外观 | lc:crates/develop/src/controls.rs、pipeline/src/tone.rs |
| 自动基础调整、原色校准 | 按需分别验证，不整套更换颜色管线 | lc:crates/pipeline/src/auto.rs |
| 自动几何校正 | Upright、引导线、自动拉直未实现 | lc:crates/pipeline/src/geometry.rs |
| 3D LUT 创意配置 | 有需求再定色彩空间、强度、资产保存与预览／导出一致性；不等同 DCP／相机配置兼容 | lc:crates/pipeline/src/lut.rs |
| 外部编辑往返 | 需保留原片和原编辑，标明输出颜色／位深，处理外部文件变化与重开 | lc:crates/engine/src/files.rs |
| 广色域、软打样与色域警告 | 当前固定 sRGB；色域警告按用户决定随广色域／软打样一起做；原生 CAMetalLayer 已显式标 sRGB | lc:crates/pipeline/src/output.rs、proof.rs |

## Lightroom 实机对照

- 已实现、已对照、已修正复测、待用户验收分别登记；历史本地回归不能升级为 Lightroom 匹配。对照版本 Lightroom 15.2.1。
- LR-EXPORT-001：TIFF16 批量输出、冲突保护与重开后缺失重交付与 Lightroom 相符；仅三张合成 JPEG，不代表 RAW 或其他格式。
- LR-RASTER-001：未调整 TIFF8/16 与输入整数像素完全相同，ICC 意图 0/1 两应用一致；JPEG 残差主要在解码路径，未完全解释。
- LR-EXPOSURE-001（普通图像曝光）：使用根据 Lightroom 对合成 TIFF16 的输出建立的响应表（灰阶 101×65／0.1 EV，颜色 41×65³／0.25 EV signed 残差，Swift/Metal，0 恒等）。高光、饱和颜色和中间档位的效果待用户验收；公开使用依据见 [开源准备](../TODO.md)。
- 对照工具的命令行路径相对于运行目录，JSON 清单中的路径相对于各自清单所在目录；校准工具只读取显式指定的素材。可在 macOS 终端运行 `python3 Tests/test_calibration_paths.py` 验证路径及防覆盖。
- 保留的数值对照：[现行 v4 TIFF 成片比较](references/lightroom-exposure-v4-comparisons.json)与[分区表](references/lightroom-exposure-v4-regions.csv)，以及[v4 JPEG 分区表](references/lightroom-exposure-v4-jpeg-regions.csv)和[早期 v3 对照表](references/lightroom-exposure-v3-comparisons.csv)。TIFF 的 C／J／M 是合成图，K 是 CC0 样片生成的普通 TIFF；H／I 仅用于校准，M 已用于验证，不能作为新的盲测。JPEG 的 L 来自 CC0 样片，V 为合成图，其他标识为它们的冻结解码或输出派生输入。单位为整数 RGB16 的 code16/257；记录不包含照片或图库，也不能代表 RAW 管线或用户验收。
- 仍开放：JPEG 输入／暗部大尾差（L/+5 max≈74），截负值、标准 IDCT 取整都不能消除；v4 在 +2.75 有局部回退；近零 EV 尾差未拟合。JPEG 调查已按用户要求暂停：没有更优方案时不循环死磕。已知具名 Apple JPEG 调用来自 UI 显示栈，不能当最终显影 decoder；导出 CameraRaw 匿名数值阶段未知。
- 恢复后的保留队列（用户明确恢复才接续）：
  1. JPEG：先补最终显影中间数值与调用关系，不重复 libjpeg／简单取整盲试。
  2. NATIVE-PIXEL-001：RAW 缓存／非缓存质量差异在 M4 Pro/macOS 26.6.2 失败，当前 M4/macOS 27 严格相同，根因未解、不认定 UI 回归；原环境先区分像素与 padding，严格断言和缓存边界不改。
  3. PNG／透明／广色域／白平衡组合：尚未与 Lightroom 对照，保留中性和透明约定；性能不能以画质下降替代。
  4. RAW 独立基线：不能由普通 TIFF 推断；选单一公开机型／压缩，固定处理版本、配置、白平衡、光学与锐化，先对照未调整导出。

## A. 选片与对比交互

- Shift+数字按物理键回退识别；方括号在蒙版／污点工具中调大小，在选片上下文用于评级。
- 显示层警告不进入导出，颜色取设计 Token，不随主题改变照片像素；纯黑白点超出与色域超出分开定义。
- 辅助选片评分只作候选：lc:crates/pipeline/src/cull.rs 用分块拉普拉斯能量高百分位估计清晰度并统计剪切、相似签名，未经我们样本验证。

## B. 图像处理

- 修复与填补分开：仿制为羽化复制；修复为“来源 + 模糊(目标 − 来源)”；Remove 为自动环形匹配选源后修复；上游 Fill 用 PatchMatch（gaps.md 的“patch synthesis missing”已过时）。
- 原生修复在 RAW／ICC 解码及曝光／白平衡后、明暗／曲线／颜色／蒙版及用户几何前，参数用未裁剪照片坐标；新笔触保存自动来源偏移，不需重复开发固定选源。
- 创作暗角原参考 5436951 Vig；原生线性 sRGB 用 Rec.709 亮度，上游 Rec.2020 系数不能直接套用。颗粒为整数哈希加平滑插值；在裁剪与输出缩放后按最终画面、于 sRGB 编码域加颗粒再返回线性；不能以改种子模拟强度。
- 上游 ToneMap::display 在 0.95 以上有短肩部，非全范围恒等；保留 PNG／TIFF 无损恒等，JPEG 解码差异与显影公式分开处理。
- 上游色域映射朝保持亮度方向降饱和（lc:crates/pipeline/src/output.rs）；采用即外观变化，先测量再决定。已确认的 RAW 基础外观、分区调光和 Oklab 混色不随本清单重做。
- 通用锐化／降噪采用上游非 AI 实现的 logY 与尺度／检验思路，补独立半径、透明覆盖与彩边约束，非逐像素复刻；降噪为 logY 引导滤波加保留亮度的色度双边处理，原图尺度、alpha 加权。不能把 Apple RAW 控件当作通用算法。
- 透明来源和空间／局部处理在几何前建立预乘线性 RGBA32F 边界，颜色计算安全反预乘，修复保留目标 alpha；PNG8／TIFF16 末端 straight 量化保留透明。

## C. 预设与 XMP 交换

- 强度在当前值与预设值间插值并按控件范围截断；100% 无蒙版时与原粘贴一致。缺少同名同选区的蒙版才加入并缩放效果，原生蒙版强度上限 100%。全局预设管理与局部工具预设分开（上游局部 Effect 见 lc:crates/engine/src/cmd/mask_effects.rs）。
- XMP 元数据交换与 Lightroom 预设转换分别验收。写 sidecar 要保留其他命名空间和未知内容；上游读取时不自动回写并有离线写回重试；未知人脸区域不因交换自动改写。
- Adobe 参数仅作受支持子集的近似映射，须逐项对照范围与响应；导入列出 unmapped，未支持参数不静默假装生效。易错点：
  - AlreadyApplied=True 表示编辑可能已在像素中，不能再次应用。
  - 新旧字段并存时优先当前处理字段；不承诺旧 lrtemplate 或全部历史处理版本。
  - 上游在主曲线与三条 RGB 曲线齐全时启用通道曲线；我们的亮度主通道语义不同，不能照搬。
  - 非 DNG RAW 相对白平衡需 AsShotTemperature／AsShotTint；缺少时保留拍摄白平衡并报告。
  - crs:ProcessVersion 是对方处理版本，不映射为我们的管线版本。
  - 上游局部曝光按分数乘 4 EV，其他不少局部参数由 −1…1 乘 100；须按具体字段重新核验。
  - 径向蒙版内外及反选语义以最新 crs_masks.rs 和测试为准。
- 参考：lc:docs/xmp-interop.md、crates/engine/src/crs.rs、crs_masks.rs、preset_import.rs。

## D. 工程做法

- lightcraft 源码为 MIT 或 Apache-2.0；移植代码或常量时保留许可和来源，见 [lightcraft-LICENSE.txt](references/lightcraft-LICENSE.txt)。模型及权重单独核查许可。
- 原生版按 Core Image／Metal 实际调用链验证，按相同尺寸比较预览／导出；结构重构不能替代对照检查。
- 工程候选·演示场景：优先为验收缺口补可复现合成场景，不重复建设测试框架（lc:crates/scenes）。
- 工程候选·应用内截图／控件控制入口：需用户决定；不能带入发行版，系统级合成输入不作验收手段（lc:docs/control-protocol.md）。
- 工程候选·按功能登记入口与状态：本清单已采用；全产品入口清单及自动检查未做，不要求引入上游 CI。
- UI 验收保留键盘焦点、数值输入、中文输入、无障碍及减少动态效果。

## E. 蒙版

- 基础模型与上游相近：多组件加／减／交／反选、命名／显隐、强度、与分辨率无关的坐标；边缘精修已有扩张收缩、柔化和硬度，不重做。
- 颜色范围：Oklab 距离中亮度差平方乘 0.25；默认精细值 50 对应 0.0225 内全选、0.045 外不选；只留“相近颜色”滑杆，未照搬上游取样前屏幕曲线。
- 自动蒙版画笔（参考 5436951）：笔触点参照中心像素，log2 亮度差除以 0.5 EV、rgb/Y 色度差除以 0.25，合成距离后平滑过渡；整笔用半径为笔刷 0.25 倍（至少 1 像素）、epsilon 0.02 的引导滤波精修，与原覆盖取较大值；原生用 Rec.709。
- 多蒙版：上游按透明度汇总局部参数后一次施加并共用空间分析，会改变现有能力或叠加外观，未采用；原生只缓存未变化的选区栅格。
- AI 结果：上游 Object／Describe 用可选 SAM 3，保存 288×288 量化 logits 及最多 4 块细节补丁。原生用 SAM 2.1 Tiny、Selfie 与 CPU 面部解析，保存固定 UInt16 覆盖率及一块面部补丁，已有结果渲染不重跑模型；权重仅在本地 Debug 研究包按需准备。AI 选区与 AI 填补的有效结果属于编辑成果，备份／迁出时携带，不作普通缓存清除；失败、取消、缺模型或基线变化保留已有编辑。

## 保留现有方案与范围

- RAW 解码继续用既定的 Apple RAW／LibRaw 路线，不照搬上游纯 Rust 解码器及其净室限制。
- 界面遵循[暗房仪表设计规范 v3](../design/darkroom_instrument_design_system_v3.md)及[Token v3](../design/darkroom_instrument_tokens_v3.json)，不改为 egui 视觉。
- 目录继续用 SQLite，不换上游追加日志目录；不建旧格式兼容层，也不以结构变化清空有效数据、备份或原片。
- HDR／全景／焦点堆栈、HDR 显示输出、人脸管理、地图、打印、幻灯片／视频、云同步、联机拍摄、移动端和插件市场为范围外候选，不因上游新增入口进入近期队列。

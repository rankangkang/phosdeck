# 当前状态

开发约定见 [AGENTS.md](../AGENTS.md)，长期决定见 [decisions](decisions.md)。

## 现状

- 主线 `master`，仅维护原生 macOS（SwiftUI + Metal + GRDB）。
- 目录 schema 13（`CatalogStore.schemaVersion`），旧版本目录直接拒绝。
- 开发机有两台（M4 Pro／macOS 26.6.2，M4／macOS 27.0.1），固定体验基线不能混用。macOS 27 这台已按用户授权重建同路径、同 bundle ID 的体验 App，使用新建 `UnratedReview.phoscat` 和五张合成图；未恢复原图库、公开样片与研究模型。M4 Pro 的既有体验环境未动。
- 仓库 Debug 默认免证书临时签名；macOS 27 这台已按用户要求通过忽略的 `Config/LocalSigning.xcconfig` 固定开发证书与团队，测试宿主及内部库、内置盘暂存副本均统一签名并保留沙箱与 hardened runtime。固定体验 App 继续保持原路径、身份与开发签名。

## 待用户验收

以下内容已实现，检查限制按条目说明，用户尚未体验确认：

- **几何校正**：已恢复 Lightroom 对照，依据 Classic 安装包动作资源及 Adobe 公开交互补齐参考线选中、端点调整、单线删除和取消拖动；保留现有求解器、裁剪与坐标模型。实窗可显示参考线画布，CUA 跨屏坐标拖动受阻；Lightroom 合成目录的导入窗口自动化也受阻，尚未完成同图运行对照。实际鼠标操作及自动校正效果待核对。
- **编辑区域外观**：保留已确认的分组、数值与单位对齐、照片信息条及图外剪切控制；补齐清除评级、内联数值错误与辅助功能播报，无效草稿随换图清除。窄栏英文琴键、白平衡模式、曲线通道、底栏操作和局部标题完整显示；“调整”标题保持完整单行，换图状态位不随载入改变布局。画笔自动蒙版补齐可见标题及开／关措辞，蒙版与曲线的添加操作文案独立于状态，“控制线”、白平衡取样与污点图钉复用基础灯键。禁用推子保留实体材质，沿轨道短行程限位并松手归位。原生交互、双主题外观与推子手感待用户体验确认。直方图剪切控制合为两颗文字灯键，移除重复入口，灯随按键状态显示，单击开关与 ⌥ 临时查看待体验确认。
- **亮度范围**：上下限复用参数数值输入、内联错误与取消语义，草稿不跨蒙版组件；同轨双端推子复用实体帽面、精调、互相止挡与禁用限位。跨屏工具无法完成坐标拖动，实际鼠标手感仍待用户体验确认。
- **预设侧栏**：零搜索结果时工具栏保持顶部位置；空预设库提示只保留一处，按内容高度展开。中文石墨与英文米白实窗已核对，待用户体验确认；固定图库保留现有预设，空库用合成窗口核对。
- **模块命名**：中文“编辑”、英文 Develop，保留 D 快捷键。
- **品牌外观**：p 左竖边修补后的字标已同步官网、README、品牌总览与固定体验 App，石墨和米白实窗已核对，待用户确认。
- **产品官网**：`site/` 中的 Astro 中英双语站点仅在 `master` 推送包含 `site/` 变更时通过 GitHub Actions 发布到 [GitHub Pages](https://rankangkang.github.io/phosdeck/)；默认石墨并支持米白，保留合成截图。首屏说明、工作流排版和下载区域已完成设计调整，线上效果待用户验收；开发命令见[贡献指南](../CONTRIBUTING.zh.md#官网开发)。
- **预览性能**：中央布局定尺寸、Observation 细粒度观察、质量预览调度与局部刷新、画布显示等待移出主线程。遗留见下节。
- **中英界面与社区语言包**：导入方式和关键词入口使用 `Add`／“添加”操作文案，与已添加状态分开；其他措辞及社区语言包待体验确认。
- **直方图拖动**：已接入五个非等宽分区、悬停读数、Shift 精调、键盘与辅助功能增减；拖动只提交一次，取消、失焦和换图丢弃草稿。模型与原生事件回归已覆盖，固定 App 的双主题／中英核对留待本批集成；Lightroom 拖动步长与取消时点未运行对照。
- **匹配总曝光**：已接入“调整”菜单，按活动照片的拍摄曝光、原生 RAW 基准与当前曝光计算目标值；复用整批事务及撤销重做，无效目标跳过、限幅单独报告。计算与批量回归已核对，固定 App 交互待本批集成核对；Adobe 精确算法与同图运行对照未验证。
- **工作流**：最近一次导入跨重启（导航状态存本机偏好，不随备份或换机携带）、普通集合删除撤销（仅当前会话）。新增“调整 → 应用相对曝光…”，按每张照片原值累加，支持 ±⅓／±1 EV、数值输入与整批撤销重做；中文双主题及合成批次保存值已实窗核对。
- **图库后缀**：新建／恢复统一 `.phoscat`，旧 `.omlcat`／`.omlrcat` 打开时可确认仅改后缀、保持原名或取消。
- **免证书构建与使用说明**：[源码构建](../README.zh.md#快速上手)尚待其他机器验证；[上手指南](getting-started.md)和中英文[贡献指南](../CONTRIBUTING.zh.md)待用户审核。

## 已知问题

- **预览**：原一秒卡顿根因未证实（drawable 默认一秒超时只是候选，相关等待已移出主线程）；质量图计算完到发布仍有约 0.1 秒主线程等待。严格同条件前后对照、物理屏幕呈现、长时间拖动帧率、大 RAW 与 Release 实窗都未测。继续时先在无 AX 遍历干扰的交互区间做 CPU 与主线程等待采样。
- **局部参数画布布局**：`ImagingTests.testMaskWorkspaceKeepsCanvasBoundsDuringSliderPreviewAndResize` 的离屏回归在拖动后出现画布高度 600→569 pt，石墨与米白均复现；当前已提交版本也有相同失败。根因待查，尚未在实际屏幕确认。
- **偶发测试失败**：`ComparisonTests.testAdjustmentReturnEndsEditingAndDoesNotReapplyAnUndoneValue` 多次在首次全量中失败、单跑通过，根因未定位；测试期间切换窗口可能影响焦点。
- **预设测试的语言假设**：`PresetManagementTests.testUnicodeSearchFavoriteAndMultipleGroupsFilter` 将中文分组顺序写成固定期望，英文环境的收藏排序断言失败、中文通过；筛选和排序实现未改，测试的语言假设待处理。
- **模型资源复制测试**：`SmartMaskTests.testOptionalModelCapabilitiesAndPartialBundleCopies` 在全量和单跑中均因测试宿主沙箱拒绝 `ditto` 的 `.BC.T_*` 临时文件而失败，具体触发机制未定位；对应脚本与测试未改动，不能以跳过断言替代修复。
- **测试环境**：免证书临时签名仍有权限身份随构建变化及 hardened runtime 关闭的限制；本机已统一稳定开发签名，后续实际测试是否仍有授权弹窗待观察。外置卷上的测试宿主及失败符号化曾停在 `__open`；内置盘暂存继续沿用同一路径，需直接读取外置源码／fixture 的两项检查尚未重跑。
- **应用分发**：本机已配置 Developer ID Application 证书；[`0.1.0-alpha.1`](https://github.com/rankangkang/phosdeck/releases/tag/v0.1.0-alpha.1) 已作为预发布公开，签名、公证、票据、`spctl` 评估及下载 ZIP 已核验。独立环境中的安装、启动与使用体验尚未验证。
- **智能蒙版模型**：FaceParsing 权重标注 MIT，训练数据条款对权重分发的适用性尚不明确；LiteRT 预编译包的完整依赖清单与正式模型安装／分发方案仍待核对，见 [模型说明](smart-mask-models.md)。
- **普通图像曝光响应表**：按用户决定保留现有表、显影行为与对照资料。[Adobe 通用条款第 17 节](https://www.adobe.com/legal/terms.html)限制为重建软件而跟踪输入与输出；当前表由 Lightroom 输出拟合，具体合同与法律适用尚未判定。数值对照见[现行 TIFF 比较](references/lightroom-exposure-v4-comparisons.json)与[JPEG 分区表](references/lightroom-exposure-v4-jpeg-regions.csv)，来源资料和公开使用依据仍须核对。
- **JPEG 对照**：JPEG 导入、编辑及导出已有支持，大曝光下与 Lightroom 的差异仍未解决。静态调查只确认 CameraRaw 内部的 JPEG→CGImage 桥接，未连到最终显影／导出与曝光 stage；完整 Ghidra 分析超时，不能据此改响应表或推断最终管线。
- **日志**：构建与测试日志反复出现 `MDB_MAP_FULL`，来源未定位。
- **验证工具**：CUA 不支持普通指针移动，hover 需人工检查；关闭设置后曾出现持续读取超时，App 主线程采样空闲，从 Dock 重新显示主窗口后恢复。相机诊断的离屏截图偶发漏绘保存按钮文字，双主题实窗显示正常。退出参考模式后照片信息条曾在米白窗口截图中漏绘，用户确认同一窗口实际屏幕上的相机名与拍摄参数完整可见，本次确认是捕捉遗漏；不能仅凭截图缺字修改 App。

## 下一步与候选

Lightroom 功能补齐的第一批范围为以下前三项，其余仍为候选。依据为本机 Classic 15.2.1 安装资源、Adobe 公开说明与当前源码的静态核对；尚未逐项实窗对照、同图比较或实现原型，成本与效果待验证。沿用 [已定决策](decisions.md) 中的不做与暂缓范围。

- **第一批 · 匹配总曝光**：参考 [Match Total Exposures](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/develop-module-options.html)，按活动照片及光圈／快门／ISO 计算各目标的曝光修正；已有相对曝光只统一累加同一增量。已实现原生参数匹配，见待用户验收；Adobe 未公开 RAW 基准细节，未宣称恢复其算法。
- **第一批 · 直方图拖动**：参考 [色调控制](https://helpx.adobe.com/lightroom-classic/desktop/help/tone-control-adjustment.html)，在现有显示／剪切检查上增加分区拖动，联动黑色、阴影、曝光、高光、白色参数；已实现并保留剪切灯与数值输入，见待用户验收。
- **第一批 · 图上目标调整**：参考 [Targeted Adjustment](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/develop-module-tools.html) 和 [Color Mixer](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/color-mixer.html)，补图上取样、拖动调整 HSL／黑白混色／曲线；现有点颜色与亮度分区取样不等于该工具。取样阶段、色带权重和现有自由点曲线的映射规则须先核实。
- **文件夹差异预览**：参考 [Synchronize folders](https://helpx.adobe.com/lightroom-classic/desktop/manage-catalogs-and-files/create-folders.html)。已有重新扫描可导入新增照片，单张与整根目录定位也已有；候选为新增／缺失／变更／疑似移动的差异预览及批量确认，保留缺失记录、编辑和虚拟副本，先做手动操作。
- **自动白平衡／自动色调**：参考 [白平衡与色调](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/image-tone-color.html)。已有拍摄时／自定义白平衡与中性区域取样；图像分析算法和摄影样片验证尚缺，不能只补自动按钮或承诺 Adobe 效果。
- **手动去紫边／绿边**：参考 [Defringe](https://helpx.adobe.com/ca/lightroom-classic/desktop/process-and-develop-photos/retouch-photos.html)。已有系统 RAW 镜头校正开关，候选为额外的可控去边和取样；先分清解码器已应用的校正，并准备有授权的色边样片。
- **外部编辑往返**：参考 [外部编辑](https://helpx.adobe.com/lightroom-classic/desktop/work-with-external-editors/open-lightroom-photos-external-applications.html)。复用 TIFF16 导出生成派生文件、交给外部 App，再核验并作为独立来源入库关联；文件生命周期、身份与中断恢复须单独设计。
- **离线可编辑代理**：参考 [Smart Previews](https://helpx.adobe.com/uk/lightroom-classic/desktop/viewing-photos/lightroom-smart-previews.html)。已有缩略图／预览缓存，原片不可用时仍缺编辑代理；须定义代理格式、来源身份、RAW 基准、重连核验和最终输出规则。

- 智能蒙版：用户体验现有功能后，再决定对象请求队列、跨照片部位缓存和逐人索引持久化。
- 模型分发：确认训练数据条款对现有 FaceParsing 权重的适用性，或更换授权依据清晰的权重；补齐运行时依赖声明并确定安装方式。
- 继续编辑工作区细节打磨：尚未覆盖的工具和局部面板长文案。
- 工作流：快照创建撤销、集合组；内容感知填补、物理文件管理为后续大项。
- 应用分发：验证下载安装与使用体验，核对发行说明和随包许可。

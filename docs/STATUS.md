# 当前状态

开发约定见 [AGENTS.md](../AGENTS.md)，长期决定见 [decisions](decisions.md)。

## 现状

- 主线 `master`，仅维护原生 macOS（SwiftUI + Metal + GRDB）。
- 目录 schema 13（`CatalogStore.schemaVersion`），旧版本目录直接拒绝。
- 开发机有两台（M4 Pro／macOS 26.6.2，M4／macOS 27.0.1），各有一份固定体验 App 与 `UnratedReview.omlrcat`，内容不同，基线不能混用。macOS 27 这台的图库记录为 6 张合成图加 7 张固定公开样片，程序包含 SAM、Selfie 与仅限本地非商业研究的 FaceParsing。
- 默认 Debug 用本机临时签名（用户选择“免证书直接构建，注明限制”）；固定体验 App 通过 `Config/LocalSigning.xcconfig` 使用开发证书和 hardened runtime。

## 待用户验收

以下内容已实现并完成工程检查，用户尚未体验确认：

- **模块命名**：中文“编辑”、英文 Develop，保留 D 快捷键。
- **品牌外观**：圆角字标已接入石墨和米白主题，待固定体验 App 实窗确认。
- **产品官网**：`site/` 中的 Astro 中英双语站点通过 `master` 的 GitHub Actions 工作流发布到 [GitHub Pages](https://rankangkang.github.io/phosdeck/)；默认石墨，支持米白，复用设计 Token 与合成图实机截图，线上效果待用户验收；开发命令见[贡献指南](../CONTRIBUTING.zh.md#官网开发)。
- **预览性能**：中央布局定尺寸、Observation 细粒度观察、质量预览调度与局部刷新、画布显示等待移出主线程。遗留见下节。
- **中英界面与社区语言包**：英文问题见下节。
- **工作流**：最近一次导入跨重启（导航状态存本机偏好，不随备份或换机携带）、普通集合删除撤销（仅当前会话）。
- **图库后缀**：新建／恢复统一 `.phoscat`，旧 `.omlcat`／`.omlrcat` 打开时可确认仅改后缀、保持原名或取消；现有固定合成图库保留原名。
- **免证书构建与使用说明**：[源码构建](../README.zh.md#快速上手)尚待其他机器验证；[上手指南](getting-started.md)和中英文[贡献指南](../CONTRIBUTING.zh.md)待用户审核。

## 已知问题

- **预览**：原一秒卡顿根因未证实（drawable 默认一秒超时只是候选，相关等待已移出主线程）；质量图计算完到发布仍有约 0.1 秒主线程等待。严格同条件前后对照、物理屏幕呈现、长时间拖动帧率、大 RAW 与 Release 实窗都未测。继续时先在无 AX 遍历干扰的交互区间做 CPU 与主线程等待采样。
- **英文界面**：窄侧栏下 `Adjustments`、`White Balance`、色轮选项、复制／粘贴调整等被截断；色调分组显示 `TINT`、纹理分组显示 `PREFERENCES`，语义待复核；辅助功能文案有 `CollapseLeft Panel`、`1 stars` 一类拼接与单复数问题。
- **偶发测试失败**：`ComparisonTests.testAdjustmentReturnEndsEditingAndDoesNotReapplyAnUndoneValue` 多次在首次全量中失败、单跑通过，根因未定位；测试期间切换窗口可能影响焦点。
- **模型资源复制测试**：`SmartMaskTests.testOptionalModelCapabilitiesAndPartialBundleCopies` 在全量和单跑中均因测试宿主沙箱拒绝 `ditto` 的 `.BC.T_*` 临时文件而失败，具体触发机制未定位；对应脚本与测试未改动，不能以跳过断言替代修复。
- **临时签名**：hardened runtime 关闭；强制开启会因动态库 Team ID 不一致导致 XCTest 宿主无法启动。外置卷检出时测试宿主曾长时间停在 dyld `open`，原因未明。
- **应用分发**：本机已配置 Developer ID Application 证书；`0.1.0-alpha.1` 已通过 Apple 公证并附票，本地 ZIP 的签名、票据和 `spctl` 评估已核验。独立环境中的下载、安装、启动与使用体验尚未验证。
- **智能蒙版模型**：FaceParsing 权重标注 MIT，训练数据条款对权重分发的适用性尚不明确；LiteRT 预编译包的完整依赖清单与正式模型安装／分发方案仍待核对，见 [模型说明](smart-mask-models.md)。
- **普通图像曝光响应表**：按用户决定保留现有表、显影行为与对照资料。[Adobe 通用条款第 17 节](https://www.adobe.com/legal/terms.html)限制为重建软件而跟踪输入与输出；当前表由 Lightroom 输出拟合，具体合同与法律适用尚未判定。数值对照见[现行 TIFF 比较](references/lightroom-exposure-v4-comparisons.json)与[JPEG 分区表](references/lightroom-exposure-v4-jpeg-regions.csv)，来源资料和公开使用依据仍须核对。
- **固定合成图库**：macOS 27 这台的合成图仅剩 `Workflow-3.jpg` 源文件，另 5 个源文件缺失，原因未确认；图库记录、配方及历史保留。恢复前不以其他图像替代或改写来源身份；7 张固定公开样片仍可体验智能蒙版。
- **日志**：构建与测试日志反复出现 `MDB_MAP_FULL`，来源未定位。
- **验证工具**：CUA 不支持普通指针移动，hover 需人工检查；关闭设置后曾出现持续读取超时，App 主线程采样空闲，从 Dock 重新显示主窗口后恢复。

## 候选下一步（均需用户决定）

- 智能蒙版：用户体验现有功能后，再决定对象请求队列、跨照片部位缓存和逐人索引持久化。
- 模型分发：确认训练数据条款对现有 FaceParsing 权重的适用性，或更换授权依据清晰的权重；补齐运行时依赖声明并确定安装方式。
- 修正英文界面截断与文案。
- 工作流：相对批量曝光补测、快照创建撤销、集合组；内容感知填补、外部编辑往返、物理文件管理为后续大项。
- 应用分发：验证下载安装与使用体验，核对发行说明和随包许可。

# Phosdeck 插件系统方案

Phosdeck 在 macOS 26+ 上基于 ExtensionKit（`PhotoTool` 扩展点）提供独立进程插件机制。当前产品内置三个随包插件，各覆盖一种接入口；开放第三方插件前须先通过跨团队签名并公证的独立容器验证。验收状态见 [STATUS](STATUS.md)，决策边界见 [已定决策](decisions.md)。

## 接入口与三个内置插件

| 接入口 | 内置插件 | 现行范围与宿主分工 |
|---|---|---|
| 图像处理（观片预览） | **软打样**（`PhosdeckSoftProof`） | 宿主提供已核验的输出 ICC 配置与送印源（显影＋暖调＋局部＋颗粒后线性合成到白底的 sRGB 成片），插件经 ColorSync 返回带目标色彩空间的预览与可选色域警告覆盖图；仅影响当前窗口画布，不改配方、历史、吸管读数或普通导出。[Apple ColorSync](https://developer.apple.com/documentation/colorsync/color-transforms) |
| 提出原生编辑 | **选取高光**（`PhosdeckHighlights`） | 宿主提供按当前旋转／透视／裁剪生成的 Oklab 明度参考图，插件仅统计裁区内有效像素并返回亮度范围上下限与软边；用户确认后由宿主创建原生亮度范围蒙版并登记一次撤销，停用插件后仍可继续修边与导出。[Masking.swift](../Sources/Imaging/Masking.swift) |
| 实时显影效果 | **暖调印相**（`PhosdeckWarmPrint`） | 接入固定显影阶段（局部调整、几何与暗角之后，输出缩放、颗粒与编码之前），保留尺寸与透明度，0% 精确旁路；单滑块强度可在预览与导出间复算，确认时按全尺寸生成持久化阶段文件（当前上限 6000 万像素）。[ImagePipeline.swift](../Sources/Imaging/ImagePipeline.swift) |

## 平台架构与开发接口

三个插件均作为独立 `.appex` 绑定无界面扩展点 `dev.cmkk.oh-my-lrc.PhotoTool`，通过共享模块 [PhosdeckPluginKit](../Packages/PhosdeckPluginKit)（不依赖 App、GRDB 或 SwiftUI）与宿主通信。

```swift
protocol PhotoTool: Sendable {
    var descriptor: ToolDescriptor { get }
    func evaluate(_ request: ToolRequest, input: PluginImage, profile: Data?) async throws -> ToolResult
}
```

- **发现与双向签名校验**：宿主经 `AppExtensionPoint.Monitor` 发现扩展并通过系统 XPC 连接仅交换匿名 `NSXPCListener` 端点（避开 macOS 26 对系统交入连接直接设签名要求崩溃的问题）。工作连接激活前，宿主与扩展各自设置代码签名要求（Team ID、bundle ID 与 Apple 签名链），握手先执行 `describe` 核对发布者、工具键、接口主版本与算法版本，再交付像素。
- **持久化身份**：工具身份绑定 `(Team ID, bundle ID, toolKey)`，重开另核对算法版本；不同发布者的同名工具按独立工具处理。
- **生命周期与空闲回收**：正常结束的工作连接在空闲 1 秒后释放；取消、关闭工具或切图立即作废在途请求并触发 Swift 任务取消。

### XPC 调用协议

所有请求由宿主发起并限制为白名单控制字段与文件句柄；连接中断、超时和迟到回复经统一收口，每次请求只结算一次结果。

| 消息 | 用途与约束 |
|---|---|
| `describe` | 握手交换工具描述、接口版本与算法版本，未完成前拒绝工作消息 |
| `open(session, tool)` | 建立一次试调或后台渲染会话；同 ID 描述不符直接报错 |
| `evaluate(session, request, revision, purpose, parameters, input)` | 执行草稿、质量或最终计算；不直接写图库，未知工具或非法输入拒绝 |
| `cancel(session, request)` | 宿主即刻作废结果并通知扩展取消，支持幂等重发 |
| `close(session)` | 关闭会话并释放句柄；失联时双方各自清理并按回收状态结算额度 |

## 像素交付与跨会话限额

- **像素格式**：工作像素统一为扩展线性 sRGB、RGBA32F、小端、直通 alpha、自上而下行序（宿主从 Core Image 预乘浮点读回后转换并归零完全透明像素）。软打样输入附带描述实际字节的扩展线性 sRGB 配置及独立目标 ICC。
- **只读文件句柄交接**：图像、色域覆盖图与自定义 ICC 经任务私有普通文件的只读 `FileHandle` 传递，插件无需原片路径、书签或数据库访问。宿主读取前校验尺寸、行跨度溢出、文件类型与字节上限，有界复制到独占暂存区后核验有限像素、透明度与摘要。
- **跨会话限额**：宿主按插件身份在预览、导出与重试间共享在途任务数与字节预算；超时或中断后保留在途额度，直至确认旧任务句柄释放或进程退出清理完成才归还一次，防止失控扩展耗尽宿主资源。

## 实时效果的保存、恢复与归档

1. **异步固化与复用键**：需要新阶段固化件时，切图、导出、切库与“应用”共用后台异步准备流程，计算与写盘均在主线程和图库事务外执行。预览与固化件复用键包含 `(Team ID, bundle ID, toolKey, algorithmVersion, sourceHash, upstreamRecipe, stageGeometry, parameters, size, pixelContract)`；只改下游颗粒时沿用原阶段文件。
2. **预写收据与崩溃恢复**（[PluginStageCommit.swift](../Sources/Catalog/PluginStageCommit.swift)）：阶段文件暂存核验后先持久化收据（含操作 ID、预期修订、暂存身份、目标位置与摘要），再经 `SafeFileWriter` 无覆盖发布并在同一图库事务中提交配方、阶段引用与带操作 ID 的历史；事务成功后删除收据并登记撤销。重启后凭操作 ID 与收据核验已发布文件并续接登记，绝不覆盖上一已存版本。
3. **无插件回读与归档**：撤销／重做仅切换阶段文件引用；整库归档（[CatalogArchive.swift](../Sources/Catalog/CatalogArchive.swift)）自动收集配方、历史、快照与冻结导出引用的阶段文件并随库复制。停用或缺少插件时，已有匹配固化件的版本仍可查看和导出；仅当上游参数改变需要重算时才要求启用插件。
4. **批量一致**：原生与 MCP 批量修改（见 [批量提交契约](agent-integration.md#逐张调整并批量提交)）先逐张就绪固化件再一次事务提交，任一失败整批不落盘。

## 实施顺序与验证

- **独立探针与回归**：[scripts/plugin-probe/](../scripts/plugin-probe/project.yml) 提供独立于主 App 的随包／跨团队容器探针（支持 `--snapshot`、`--vendor`、`--inline`、`--measure`、`--final` 核验签名、非法载荷、拖动与 6000 万像素写盘）；固定体验 App 通过 [update-preview.sh](../scripts/update-preview.sh) 与 [bind-preview-photo-tools.py](../scripts/bind-preview-photo-tools.py) 同步扩展绑定并重签；`PluginSystemTests` 覆盖正式构建绑定、签名工作连接、像素行序、高光选区与收据恢复。
- **开放第三方前置条件**：完成跨团队 Developer ID 签名与公证独立包的安装、系统批准、握手与故障恢复实测，再扩展通用工具描述（参数 schema 与动态控件生成）并视实测性能决定是否引入 `IOSurface` 共享或分块处理。

## 后续扩展指引

| 后续场景 | 建议接入口 | 扩展触发条件 |
|---|---|---|
| 胶片风格／创意调色 | 实时显影（或按需派生照片） | 确需线性早期阶段或全图统计时再新增挂载点 |
| 人像精修／语义选区 | 选区走原生编辑建议，修肤走派生照片 | 需要画布点选或已有选区输入时扩展输入描述 |
| RAW AI 降噪／复杂多帧合成 | 图像处理接入口新增“派生照片”结果 | 复用安全发布与 [MergedPhotos.swift](../Sources/Catalog/MergedPhotos.swift) 来源登记 |
| 大图邻域效果／精细颗粒 | 复用实时显影 | 整帧内存或时延实测不足时再开放分块与边界核对 |

# Phosdeck Agent 接入方案

Phosdeck 通过本地 MCP 服务和随包 Skill 开放几乎全部用户工作流，涵盖状态读取、图像预览、编辑执行、结果核验及任务恢复。工具详细入参以服务端 `tools/list` 和随包 [Phosdeck Skill](../.agents/skills/phosdeck/SKILL.md) 为准；验收状态见 [STATUS](STATUS.md)，产品范围见 [已定决策](decisions.md)。

## 架构与系统边界

- **共享原生真源**：调用链为 `Agent 客户端 → MCP 适配（Sources/App/AppMCP*.swift）→ 原生操作入口 → 图库／显影／文件服务`。UI 与 MCP 复用同一套校验、事务与撤销逻辑。
- **原生保留边界**：MCP 开关、图像共享开关、连接凭据、原生系统文件授权面板（`NSOpenPanel`）、窗口管理、文本编辑器撤销、系统剪贴板与连续堆叠比较流程保留在原生 App 内。[已定决策](decisions.md#界面与交互)
- **撤销边界**：`undo_operation`／`redo_operation` 仅匹配本服务返回且仍在原生撤销栈顶的 `operation_id`；手动编辑由原生菜单撤销。

## 协议与状态契约

### 工具结果与错误码

`structuredContent` 始终包含 `status`（`success`／`warning`／`error`）、`summary`、`next_actions` 与 `artifacts`，文本块携带同一 JSON，预览另附 `image/png`。业务失败设置 `isError: true` 并返回 `error.code`：[MCP 工具规范](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)

| 错误代码 | 调用方处理 |
|---|---|
| `invalid_arguments`、`unsupported_operation` | 按 `tools/list` 核对参数与可用条件后重试 |
| `no_catalog`、`catalog_changed`、`stale_cursor` | 重读 `get_workspace` 获取新图库会话与查询 |
| `photo_unavailable`、`stale_photo`、`stale_preview` | 回读照片与修订号，必要时重新取图 |
| `workspace_busy`、`native_interaction_active` | 等待在途任务或原生编辑结束，再核对状态 |
| `image_access_disabled`、`file_access_required` | 提示用户开启预览共享或完成原生文件授权 |
| `rating_conflict`、`marks_conflict`、`caption_conflict`、`undo_conflict` | 回读实际值与撤销栈，确认意图后再提交 |
| `collection_unavailable`、`stale_collection`、`stale_stack`、`pair_unavailable` | 回读对应集合、堆叠或配对的当前 ID 与顺序 |
| `mask_unavailable`、`spot_unavailable`、`stale_smart_selection` | 回读当前版本的蒙版、污点或智能选区修订 |
| `smart_model_unavailable`、`smart_mask_analysis_failed` | 从 `get_capabilities` 查看可用模型或切换方式 |
| `request_id_conflict`、`request_expired`、`stale_plan`、`stale_conflict` | 回读上次结果或重新生成计划后再提交 |
| `job_unavailable`、`import_record_unavailable`、`service_stopped` | 核对任务／复制记录，或重启后重新获取连接配置 |
| `operation_failed` | 按 `commit_state`（`not_committed`／`committed`／`unknown`）先回读再决定恢复 |

### 会话、修订、坐标与去重

- **会话与修订**：切库或重开会生成新的 `catalog_session_id`。`photo_id` 对应版本 `Photo.id`，`source_revision`／`recipe_revision` 分别绑定原片与配方修订；多页 TIFF 的 `editable_canvas` 为 `false`。
- **坐标约定**：对外坐标采用返回图像左上原点归一化 `[0,1]`；`preview_id` 绑定渲染几何用于逆映射回原生坐标，蒙版／污点回读标注 `oriented_source_normalized_top_left`。
- **写入幂等与并发**：多客户端写入串行化并在事务中复核期望版本；同一 `request_epoch` 内复用 `(request_id, arguments)` 返回既有结果或任务 ID，同 ID 不同参数报冲突。
- **多步任务**：导入、智能蒙版、合成与导出返回 `job_id`，通过 `get_job` 轮询状态（`queued`／`running`／`waiting_for_user`／`succeeded`／`partially_succeeded`／`failed`／`cancelled`），通过 `cancel_job` 取消。复制导入与导出记录随图库持久化，重启后可继续查询与恢复。

## 本地连接

在“设置 → Agent”开启本地 MCP 服务（默认关闭，预览共享独立开关且默认关闭）。监听绑定 `127.0.0.1:0`（系统分配端口，正式版与 Preview 可并行，`get_capabilities` 返回 bundle ID 与 `instance_id`），每次启动生成新 Bearer 令牌。

- **传输基线**：MCP `2025-11-25` Streamable HTTP（POST 返回响应流，独立 GET 返回 `405`），基于官方 Swift SDK `0.12.1` + SwiftNIO `2.105.0`。聚合请求体前校验回环 `Host`、`Origin` 与 `Authorization: Bearer`（无效返回 `401`／`403`）。[MCP 传输规范](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
- **限额与时限**：普通工具请求体上限 `64 KiB`，`plan_photo_merge`／`edit_merge_retouch` 上限 `1 MiB`（超限 `413`）。传输会话空闲 15 分钟需重新初始化；质量预览等待上限 150 秒（连接 180 秒），超时返回 `preview_timeout`。
- **客户端配置**：设置页提供“复制 JSON 配置”（适用于 `mcpServers` 客户端，如 Claude Code `--mcp-config`）与“复制 Codex 配置”（TOML 片段，令牌通过环境变量如 `PHOSDECK_MCP_TOKEN` 注入）。服务重启后须重新复制配置与令牌。

## 安装 Phosdeck Skill

Skill 源目录位于 [`.agents/skills/phosdeck/`](../.agents/skills/phosdeck/SKILL.md)，构建时复制到应用包 `Contents/Resources/phosdeck`。复制整个目录（含 `SKILL.md` 和 `references/`）到客户端目录后重启会话即可发现：

| 客户端 | 项目目录 | 用户目录 |
|---|---|---|
| Codex | `.agents/skills/`（仓库内自动发现） | `~/.agents/skills/` |
| Claude Code | `.claude/skills/` | `~/.claude/skills/` |

## 接口速览

各领域完整参数与操作剧本见随包 Skill 参考文档（[图库与导入](../.agents/skills/phosdeck/references/library-and-import.md) · [选片与元数据](../.agents/skills/phosdeck/references/culling-and-metadata.md) · [组织](../.agents/skills/phosdeck/references/organization.md) · [显影](../.agents/skills/phosdeck/references/development.md) · [画布与局部](../.agents/skills/phosdeck/references/canvas.md) · [合成与导出](../.agents/skills/phosdeck/references/output.md) · [维护](../.agents/skills/phosdeck/references/maintenance.md)）。

### 图库、组织与维护接口

- **图库与导入**：`list_library_sources`、`list_recent_catalogs`、`create_catalog`、`open_catalog`、`request_file_access`、`relocate_library_root`、`locate_photo_original`、`plan_photo_import`（支持 `relative_paths` 仅验选定文件）、`start_photo_import`、`resolve_import_conflict`、`show_recent_import`、`scan_library_folder`、`plan_folder_review`、`apply_folder_review` 及复制导入恢复／备份清理工具。
- **集合、版本、堆叠与配对**：集合 CRUD／手工排序／智能集合、虚拟副本（含历史／快照来源）、手动与按时间自动堆叠，以及 RAW/JPEG 检测、核验、配对与解绑。
- **合成与导出**：支持全景／HDR／HDR 全景／对焦／均值／稳健均值／中值／多重曝光／星轨（关闭对齐上限 2048 帧，暗场至多 128 张）规划、预览、精修（`edit_merge_retouch`／`get_merge_retouch`）、星轨累计 PNG 导出与 TIFF32／DNG 母版保存；支持单／多规格导出预设、计划预览、安全发布、中断核验与重授位置。
- **设置、诊断与维护**：界面偏好与面板展开、社区语言包、存储与缓存配额、图库 SQLite 备份／恢复／JSON 清单，以及本地 RAW 相机诊断。

### 浏览选片和标记接口

- `set_library_query`／`refresh_library_query` 控制系统查询与冻结结果；`list_photos` 支持当前视图、独立 `query`（不改动原生界面）或显式 `photo_ids` 分页，并可返回带编号与像素坐标的缩略图拼图（`contact_sheet=true`，默认 12 张／上限 24 张）。
- 支持跨页与折叠堆叠选片、比较／调查视图控制、批量评级／旗标／色标（单批上限 200 张，冲突整批拒绝）、关键词与题注编辑。

#### 辅助选片

- `analyze_photo_culling` 接收显式 `photo_ids` 或独立 `query`（单次上限 1,000 版本），基于 320 px 原片缩略图在后台生成报告：
  - **连拍候选**：按拍摄时间间隔（默认 10 s）与画面相似度（默认 0.93）分组，按清晰度 `sharpness` 排序并标记 `recommended=true`。
  - **相似图检索**：传入 `reference_photo_id` 按相似度降序返回匹配（默认阈值 0.8）。

### 全局显影、前后对照与编辑记录接口

- 覆盖全部原生全局参数、曲线、五区光线、HSL、黑白混色、色彩分级、通用／RAW 细节、手动去边、暗角／颗粒、自动调整、相对曝光、匹配总曝光、参数传递、预设管理、XMP 预设导入、前后对照与历史／快照管理。
- **整图草稿试修**：`edit_photo_draft(action=begin)` 开启单张内存草稿，可连续调整全局、几何、预设强度、局部与污点；`preview_quality=interactive` 用于快速目视试修，`quality` 用于定稿并复用同配方同尺寸缓存；`commit` 仅写一条编辑历史。

#### 逐张调整并批量提交

1. `plan_adjustment_batch` 提交最多 64 张不同版本及其逐张 `adjustments`（受 `64 KiB` 请求体上限约束），预览各组 `before`／`after` 变化。
2. `apply_adjustment_batch` 在提交前复核全部目标版本与原片，通过后一次事务保存并登记一条原生撤销；任一冲突或失败整批不写入。

### 画布、几何和局部编辑接口

- `get_photo_preview` 支持 `crop_canvas` 几何画布、蒙版叠加（`mask_overlay`／`without_mask_id`）及 `resolution=native` 1:1 局部 PNG（`region` 或 `region_pixels`，单块最长边 2048 px、面积上限 1,048,576 px，可用 `plan_only=true` 查询分块）。
- 覆盖裁剪、旋转、翻转、透视与参考线求解、像素与目标调整取样、点颜色、污点修复（支持跨块 `source_preview_id` 取样）、普通蒙版（画笔／渐变／颜色与亮度范围）、局部参数预设与智能蒙版会话。普通画笔与固定源污点在不透明源上走局部区域渲染，全图分析与透明源保持完整渲染。

## 技术依据

- **依赖版本**：MCP Swift SDK `0.12.1`（`a0ae212`，2026-04-29）、SwiftNIO `2.105.0`（`2f58d8e`，2026-11-02），随包分发声明见 [mcp-NOTICES.txt](references/mcp-NOTICES.txt)。[Swift SDK 许可](https://github.com/modelcontextprotocol/swift-sdk/blob/a0ae212ebf6eab5f754c3129608bc5557637e605/LICENSE) · [SwiftNIO 发布](https://github.com/apple/swift-nio/releases/tag/2.105.0)
- **平台规范**：[macOS App Sandbox](https://developer.apple.com/documentation/security/app-sandbox) · [Agent Skills 规范](https://agentskills.io/specification)

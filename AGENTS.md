# AGENTS.md

适用于整个仓库。始终用简体中文沟通；用户在当前任务中的明确要求优先于本文件。仅维护原生 macOS 版（SwiftUI + Metal + GRDB），原生构建与检查不依赖 Node.js 或 Rust。

## 开工先读

1. 运行 `git status --short`、查看当前分支与最近提交；保留已有改动，不自行重置、切换分支或清理工作区。
2. 读 [当前状态](docs/STATUS.md) 与 [已定决策](docs/decisions.md)。
3. 按任务按需读取专题文档（渐进式披露，不盲扫全库）：
   - 改源码、查分层边界或选定向测试 → [架构地图与测试映射](docs/architecture.md)
   - 高频交互、性能调优、更新体验 App 或签名 → [工程手册](docs/engineering.md)
   - UI 与交互 → [设计规范 v3](design/darkroom_instrument_design_system_v3.md)、[设计 Token v3](design/darkroom_instrument_tokens_v3.json)
   - 全量文档索引 → [docs/README.md](docs/README.md)；第三方许可 → [docs/references/](docs/references/)；历史做法 → `git log --grep=<scope>` / `git log -- <path>`

## 工作边界（红线）

- **主线与文件登记**：主线代码在 `Sources/`、`Tests/`、`Packages/`、`Phosdeck.xcodeproj/`。保留已有功能与交互；新增 Swift 文件须同步登记到 `Phosdeck.xcodeproj/project.pbxproj`（及 `project.yml`）。
- **数据与隐私保护**：禁止打开、读取或写入真实照片目录（`.phoscat`／`.omlcat`／`.omlrcat`）和私人原片。测试仅用合成数据、`Samples/public-cc0/` 或已授权只读的 `Samples/PublicRAW/`；样片不提交，不把整个 `Samples/` 视为授权素材。
- **不写向后兼容**：开发阶段不为旧配方、旧任务、旧目录或旧 schema 写迁移或兼容层，不兼容的旧文件直接拒绝；但须保护当前使用中的数据、备份与原片，禁止清空或覆盖。
- **图库后缀**：统一使用 `.phoscat`；打开旧 `.omlcat`／`.omlrcat` 时允许确认同目录无覆盖改后缀，不改数据库内容。
- **分支与依赖**：沿用 [STATUS.md](docs/STATUS.md) 的分支安排，不自行合并、删分支、强推或改写已推送历史。不引入 GPL 依赖，新增依赖核对许可及随包声明。安装重工具链前先问用户；同一方向修正两次仍失败时停止并请求决定。
- **验收与真实性**：验收阈值与完成状态由用户决定，不自行放宽或宣布通过；不用假数据冒充已实现功能。

## 实现原则

- 先读实际调用链与全部调用方再改共享根因；优先复用已有实现、标准库与已安装依赖，做当前任务所需的最小改动，不预建框架或顺带重构。
- 严格遵守 [架构地图](docs/architecture.md) 中的分层 import 边界、显影／色彩／TIFF16 语义与 `SafeFileWriter` 无覆盖发布约定。
- 参考上游实现时先读对应源码、调用方与测试，记录提交号、日期与路径；在提交说明中区分直接移植、算法／交互借鉴、原生实现与未采用原因，长期取舍记入 [decisions.md](docs/decisions.md)，复用代码保留许可与归属。
- UI 改动先核对 [设计规范 v3](design/darkroom_instrument_design_system_v3.md) 的硬红线与组件选型表，复用 `Theme`／`Metrics`／现有暗房控件；保持中性观片底（主题不得改变图像像素），保留键盘操作、焦点、数值输入与减少动态效果支持。调整共享色值、尺寸或控件模式时，同步更新 [设计 Token v3](design/darkroom_instrument_tokens_v3.json) 与规范，并用 `python3 scripts/check-harness.py` 校验同步与 UI 守护。
- 改动 MCP 工具或行为时，同步更新随包 Skill（`.agents/skills/phosdeck/`）。

## 常用命令

本机环境：Apple Silicon（arm64）、macOS 26+、Xcode 26+（部署目标 macOS 26.0），均在仓库根目录执行：

| 用途 | 命令 |
|---|---|
| 全量检查（文档 + 架构基建 + XCTest） | `./scripts/check.sh` |
| 仅文档与 AI 基建／架构检查 | `python3 scripts/check-docs.py && python3 scripts/check-harness.py` |
| 增量 Debug 构建 | `xcodebuild -project Phosdeck.xcodeproj -scheme Phosdeck -configuration Debug -derivedDataPath build -destination 'platform=macOS' build` |
| 定向运行单个测试类 | `xcodebuild -project Phosdeck.xcodeproj -scheme Phosdeck -derivedDataPath build -destination 'platform=macOS' -only-testing:PhosdeckTests/<TestClass> test` |
| 更新固定体验 App | `./scripts/update-preview.sh`（详见 [工程手册](docs/engineering.md)） |

## 提交约定

- **Conventional Commits（英文）**：`<type>[scope]: <imperative>`（小写开头、无句号），type 仅用 `feat`/`fix`/`docs`/`style`/`refactor`/`perf`/`test`/`build`/`ci`/`chore`/`revert`；破坏性变更在 type 后加 `!` 或在 footer 写 `BREAKING CHANGE:`。
- **正文即过程档案**：`feat`/`fix`/`perf`/`refactor` 必须有正文（改了什么及原因、上游取舍、末段 `Verification:` 写实际执行／跳过原因／未测项）；仅文档或琐碎改动可只写标题。

## 验证与交付

- **按风险验证**：非平凡逻辑在 `Tests/` 补最小 XCTest 回归，测试固定数据放 `Tests/Fixtures/`；按改动域跑定向测试（见 [测试映射](docs/architecture.md#改动域与定向测试映射)）或全量检查。UI 改动在固定体验 App 核对双主题与操作（仅用允许素材）。纯文档改动跑 `python3 scripts/check-docs.py`、`python3 scripts/check-harness.py` 与 `git diff --check`，说明未运行应用测试。
- **诚实汇报**：区分已执行、跳过（如缺公开 RAW／模型）与未测项，不沿用旧测试数；原始日志、截图与测量 JSON 放 `build/` 不提交。小批次交付，只含本任务改动。

## 文档约定

文档只保留会影响后续开发与决策的现行事实，过程记录写进提交说明和回复。

- **默认不新建文档**：只有现有文档放不下的长期主题才新建，文件名不带日期并在 [docs/README.md](docs/README.md) 登记；禁止 `handoff/`、`validation/`、`archive/` 等过程目录。
- **`docs/STATUS.md` 为唯一交接**：只记会变的状态（`<= 100` 行且控制单行长度，防止超长段膨胀）；已完成且无遗留直接删掉。多会话并行时先重读，只改本任务条目，与代码同提交；“现状”只在环境或分支变化时改。
- **`docs/decisions.md` 记长期决定**：一条一行（决定、原因、重新考虑条件）；只记用户明确表态或已确认结论。
- **直接改写现行文档**：不追加“更新：日期”流水，不保留“此前……”叙述，过时即删（需要时查 git 历史）。不复述 AGENTS.md、代码或 git 历史已有信息。
- **守护脚本**：`scripts/check-docs.py` 与 `scripts/check-harness.py` 自动校验文档与架构约束；不要为通过检查而放宽脚本，规则调整前先问用户。

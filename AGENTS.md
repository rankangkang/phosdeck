# AGENTS.md

适用于整个仓库。始终用简体中文沟通；用户在当前任务中的明确要求优先于本文件。这里只保留原生 macOS 版（SwiftUI）的开发约定；当前进展和待决定事项见 [docs/STATUS.md](docs/STATUS.md)。

## 开工先读

1. 检查 `git status --short`、当前分支与最近提交。保留已有改动，不自行重置、切换分支或清理工作区。
2. 读 [当前状态](docs/STATUS.md) 和 [已定决策](docs/decisions.md)；需要找文档时看 [文档索引](docs/README.md)，查以往做法与验证用 `git log --grep=<scope>` 或 `git log -- <path>`。
3. UI 与交互工作读 [设计规范 v3](design/darkroom_instrument_design_system_v3.md) 和 [设计 Token v3](design/darkroom_instrument_tokens_v3.json)，功能参照见 [lightcraft 借鉴清单](docs/lightcraft_reference_checklist.md)；第三方来源与许可见 [第三方声明](docs/references/)。

说明：本仓库仅维护原生 macOS（SwiftUI + Metal）版。早期 Electron 前端、Rust 实验引擎及对应跨平台 CI 已移除，原生构建与检查不需要 Node.js 或 Rust 工具链。

## 工作边界

- 主线开发位于 `Sources/`、`Tests/`、`Phosdeck.xcodeproj/`；改动保留已有功能与交互，新增 Swift 文件需在 `Phosdeck.xcodeproj/project.pbxproj`（及 `project.yml`）登记。
- 不打开、读取或写入真实照片目录（`.phoscat`、`.omlcat`、`.omlrcat`）和私人原片。测试使用合成数据、`Samples/public-cc0/`，或已授权只读的 `Samples/PublicRAW/`；输出放临时目录或忽略的结果目录。样片不提交，不能把整个 `Samples/` 视为已授权素材。
- 开发阶段不考虑向后兼容。不要为旧配方、旧任务、旧目录或旧 schema 做迁移、升级或兼容层；结构变了就只服务当前版本，打不开的旧文件直接拒绝。当前正在使用的数据、备份和原片仍须保护，不能以“不兼容”为由清空或覆盖。
- 图库后缀统一为 `.phoscat`；用户明确要求继续打开 `.omlcat`／`.omlrcat`，并允许在打开时确认更换后缀。这仅限同目录无覆盖改名，不能改数据库内容，也不构成旧 schema 迁移的授权。
- 沿用 `docs/STATUS.md` 记录的分支安排；不自行合并或删除分支，不强推、不改写已推送历史。
- 不引入 GPL 依赖；新增依赖时核对许可及随包声明。安装较重工具链前先问用户；同一方向修正两次仍失败时，记录具体问题并请求决定，不要无界重试或自行扩大范围。
- 验收阈值和完成状态由用户决定，不能自行放宽或宣布通过。

## 提交约定

提交使用 [Conventional Commits](https://www.conventionalcommits.org/)，说明用英文：

```
<type>[optional scope]: <description>
```

- type 仅用 `feat`、`fix`、`docs`、`style`、`refactor`、`perf`、`test`、`build`、`ci`、`chore`、`revert`。
- description 用英文祈使句，首字母小写，句末不加句号；必要时加 scope，如 `feat(ui):`、`fix(catalog):`。
- 破坏性变更在 type 后加 `!`，或在 footer 写 `BREAKING CHANGE:`。
- 提交说明是过程档案。`feat`／`fix`／`perf`／`refactor` 必须有正文：改了什么及原因；上游参考与取舍（如有）；最后一段 `Verification:` 写实际执行、跳过及原因、未测项。仅文档或琐碎改动可只写标题。

```
feat(masking): add multiple people selection

<what changed and why>

Verification: SmartMaskTests 20 run, 19 passed, 1 skipped (FaceParsing
not prepared); ./scripts/check.sh 538 run, 534 passed, 4 skipped.
Not tested: reduced motion, small windows.
```

## 代码导航与实现约定

| 位置 | 职责 |
|---|---|
| `Sources/App/` | 应用入口、`AppModel`、键盘与工作区编排、预设／蒙版／污点／点颜色／堆叠／成对编辑与多规格输出状态 |
| `Sources/UI/` | SwiftUI 暗房仪表界面、画布与 Metal 预览（`WorkspaceView`、`PhotoCanvas`、`MetalPhotoView`、`DevelopPanel`、`DarkroomControls`、`DarkroomTheme` 等） |
| `Sources/Catalog/` | GRDB/SQLite 目录存储（`.phoscat`）、旧后缀确认改名、查询分页、关键词、智能集合、平面堆叠、RAW/JPEG 关联、局部参数预设 |
| `Sources/Imaging/` | 显影参数与配方（`EditRecipe`）、CIRAWFilter 与通用细节、色调／曲线／HSL／点颜色、蒙版与空间管线、裁剪／透视／翻转、直方图与预览缓存 |
| `Sources/Import/` | 引用与复制导入、导入规划、同名冲突处理与中断恢复 |
| `Sources/Export/` | 多格式导出（JPEG／PNG／TIFF16）、命名模板、元数据写入、批次计划与恢复 |
| `Sources/Files/` | 安全文件写入（`SafeFileWriter`）、沙箱书签访问、根目录重定位、存储统计 |
| `Tests/`、`scripts/` | XCTest 回归测试、全量检查入口 `./scripts/check.sh` 及辅助校准／准备脚本 |

- 先读实际调用链和全部调用方，再改共享根因。优先复用已有实现、标准库和已安装依赖；只做当前任务需要的最小改动，不预建框架或顺带重构。
- 开发 lightcraft 借鉴清单中的功能，或为其编写新会话 prompt 时，先读上游对应实现、调用方和测试，记录提交号、日期及路径；核对最新主线时说明相对清单固定基准的变化。在提交说明中分别写明直接移植、算法／交互借鉴、原生自有实现，以及未采用内容和原因；对后续仍有影响的取舍更新到借鉴清单对应条目。上游没有对应实现时如实记录；参考不等于逐像素复刻，保留已确认的原生外观、坐标、透明度和数据保护约定，复用代码时核对许可并保留归属。
- 保持已确认的显影顺序、色彩空间与透明度语义。草稿、质量预览、缩略图和导出共用管线约定；TIFF16 直接从浮点渲染管线量化为 16 位整数，不经过 8 位预览。
- 文件发布沿用同卷暂存、刷盘、无覆盖发布与回读核验；不以普通 `rename` 替换无覆盖语义。只清理已确认归属本任务的暂存文件。
- UI 复用设计 Token，照片及观片底保持中性；主题不得改变图像像素。保留键盘操作、焦点、数值输入和减少动态效果支持，不能用假数据冒充已实现功能。

## 高频交互与性能

- 滑块、画布与实时预览的状态由最小消费视图读取，避免工作区根视图订阅局部高频变化；拆分 View 后仍检查实际观察范围。复用视图时覆盖模型身份和交互行为，折叠面板按展开状态构造内容；画布与侧栏保持明确的布局边界，避免像素更新带动无关区域反复测量。
- 检查完整主线程调用链，包括校验、JSON、摘要、数据库与显示资源获取。高频路径避免重复的大载荷处理和同步等待 GPU／drawable；后台工作传递不可变快照，原生视图访问与状态发布遵守 MainActor。`Task {}` 不保证离开 MainActor；改线程安排仍须保留保存成功、错误及撤销语义。
- 未变的数据复用派生结果，局部编辑只刷新受影响照片与新增历史。缓存键与等价比较覆盖影响结果的来源、尺寸、参数及模式；保留损坏数据、来源身份与尺寸校验，增量查询保留排序、分页、换照片及撤销重做行为。
- 预览请求保持有界，合并为最新待处理状态，提交时核对照片、配方版本与会话；相同最终草稿可复用。节流／防抖须说明目的及端到端延迟代价，不能靠不断增开任务追赶过时输入。
- 性能优化先采集基线，分段区分输入／校验保存、预览请求、后台计算、主线程发布、画布更新与显示提交。前后固定样片、蒙版、参数、窗口、显示器、预览尺寸和构建配置，记录自动化／采样开销；保留逐次数据、中位数、最大值及异常。条件不同时不宣称严格提升比例，publish／呈现回调不冒充物理屏幕延迟。
- 为实际修复的阻塞、积压／过期结果、缓存身份和增量状态边界补最小回归；受控测试验证隔离与正确性，实窗测量验证端到端体验。候选机制标为假设，注入阻塞不等于原异常复现，常规样本变快不代表偶发卡顿已解决；工程检查通过不替代用户验收。

测量原始数据放在已忽略的 `build/` 下，结论与关键数字写进提交说明；仍未解决的问题记入 `docs/STATUS.md`。

## 原生 App 构建与体验

- 普通开发与流程审查固定复用同一份体验 App，不再按轮次复制新 App、建立新 bundle ID 或新建测试目录。先正常退出该 App，再用标准 Xcode Debug 增量构建；构建成功后覆盖更新固定 App、保持原身份并重新签名，随后打开同一路径。
- 固定体验 App：`build/unrated-stars-review/oh my lrc Star Review.app`；固定 bundle ID：`dev.cmkk.oh-my-lrc.unratedstars20261021`。继续使用其中现有合成 `UnratedReview.omlrcat`。路径和 ID 虽沿用历史命名，后续不随日期或任务更换。
- 正常构建入口：`xcodebuild -project Phosdeck.xcodeproj -scheme Phosdeck -configuration Debug -derivedDataPath build -destination 'platform=macOS' build`。产物为 `build/Build/Products/Debug/Phosdeck.app`；只覆盖固定体验 App 的程序包，不覆盖其目录、原片和偏好。保持现有沙箱／hardened runtime 与源 entitlements，核对当前有效开发签名。
- 不通过全局 `PRODUCT_NAME`／`CONFIGURATION_BUILD_DIR` 重定向所有依赖目标（会破坏 GRDB 资源包名称）。不要为普通体验切换工程的 bundle ID。测试继续使用合成／已授权样本，不自动打开正常产物身份可能恢复的私人最近目录。
- 复用 `build/` 增量缓存；历史结果和其他副本的清理单独核对归属，不把整个 `build/`、用户目录或照片当作可随意删除的缓存。

## 常用命令

本机环境：Apple Silicon（arm64）、macOS 26 或更新、Xcode 26 或更新（部署目标 macOS 26.0）。以下命令在仓库根目录执行：

| 用途 | 命令 |
|---|---|
| 全量原生测试检查（含文档检查） | `./scripts/check.sh` |
| 仅文档检查 | `python3 scripts/check-docs.py` |
| 增量 Debug 构建 | `xcodebuild -project Phosdeck.xcodeproj -scheme Phosdeck -configuration Debug -derivedDataPath build -destination 'platform=macOS' build` |
| 定向运行单个测试类 | `xcodebuild -project Phosdeck.xcodeproj -scheme Phosdeck -derivedDataPath build -destination 'platform=macOS' -only-testing:PhosdeckTests/<TestClass> test` |
| 暂存已准备的公开 RAW 测试资源 | Xcode 测试目标自动调用 `scripts/prepare-public-raw-test-resources.py` |

## 验证与交付

- 非平凡逻辑在 `Tests/` 中补一个能复现问题的最小 XCTest 回归检查；测试与脚本依赖的数据放 `Tests/Fixtures/`。按改动影响和风险选择必要的验证：纯文案或标点等低风险改动可只核对内容与受影响的显示，无需专门运行测试或全量检查；涉及行为或逻辑变化时运行相关定向测试，并按风险决定是否运行全量检查。失败、跳过或未运行要说明具体原因。
- UI 与交互变化按影响在固定体验 App 实际窗口中核对相关布局与操作；影响主题显示时核对米白与石墨双主题，涉及照片时仅用允许的合成或公开样本。
- 公开 RAW／特定环境测试在缺少样片或授权卷时会跳过。报告实际执行、跳过和未测量项，不能把“命令成功”写成所有场景通过，也不能沿用旧记录的测试数量作为本轮结果。
- 纯文档改动运行 `python3 scripts/check-docs.py` 与 `git diff --check`，核对内容、路径和命令，不为文档重新构建应用；明确说明未运行应用测试。
- 验证结果（实际执行、跳过、未测）写进提交说明正文和给用户的回复；日志、截图、测量 JSON 等原始证据放在已忽略的 `build/` 下，不提交。
- 开发批次遵循小批次检查、提交和推送约定，只包含本任务改动；用户要求草稿或仅评审时先交付草稿。完成后简要说明改了什么、实际验证结果和未完成项。

## 文档约定

文档只保留会影响后续开发与决策的内容；过程记录是噪音，不写进仓库。

- **默认不新建文档。** 本轮做了什么、怎么验证、测试数量、截图与跳过原因，写进提交说明和回复即可；git 历史就是过程档案。
- **`docs/STATUS.md` 是唯一的交接。** 只写会变的状态：现状、待用户验收、已知问题、候选下一步；不超过 100 行。已完成且无遗留的事项直接删掉；状态没变就不改。lightcraft 范围内的待验收只在借鉴清单维护，STATUS 不重复。
- **可能有多个会话并行。** 只改与本任务相关的条目，不整份重写；写之前重新读当前版本，与功能代码放在同一提交。“现状”一节只在用户要求或分支、环境确有变化时改。
- **长期决定写 `docs/decisions.md`。** 一条一行：决定、原因、重新考虑的条件；只记录用户明确表态或已确认的调查结论，不自行推断。用户验收、否决或改变主意时，同步删改 STATUS 与 decisions 的对应条目。
- **改现行文档，不写新报告。** 行为、用法、约定或决策变化时，更新对应主题文档（README、上手指南、国际化、智能蒙版模型、设计规范、借鉴清单等），直接改写成现行事实；不追加“更新：日期”段落，不保留“此前……”叙述。
- **新文档要有长期主题。** 只有现有文档都放不下的长期内容（新约定、许可依据、算法依据）才新建；文件名不带日期，并在 `docs/README.md` 登记一行。不新建 `handoff/`、`validation/`、`archive/` 之类的过程目录。
- **过时就删。** 内容失效时删除或改写，不移入归档；需要时查 git 历史。
- 不复述 AGENTS.md、代码或 git 历史已有的信息；一次性数字（测试项数、截图张数、逐轮耗时）不进文档，除非它是后续回归要比对的基线。
- `python3 scripts/check-docs.py`（`./scripts/check.sh` 会先跑它）检查过程目录、带日期文件名、“更新：”流水段落、STATUS 行数、失效链接和索引登记；纯文档改动也要跑。不要为通过检查而改脚本，规则本身需要调整时先问用户。

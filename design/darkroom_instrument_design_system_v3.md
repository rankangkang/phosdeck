# 暗房仪表 v3.1 · 实体操作件

原生 macOS（SwiftUI / AppKit）界面的外观、组件选型与交互规范。取值以 [Token v3.1](darkroom_instrument_tokens_v3.json) 与 [`DarkroomTheme.swift`](../Sources/UI/DarkroomTheme.swift) 为准（二者由 `scripts/check-harness.py` 校验同步）。

![米白主题编辑窗口](darkroom_workspace_ivory.jpg)

[石墨主题编辑窗口](darkroom_workspace_graphite.jpg)。截图使用合成测试图。

## 硬红线与反模式

新增或修改任何 `Sources/UI/` 界面时，以下规则不可突破（带 `*` 项已由 `scripts/check-harness.py` 静态守护）：

| 规则 | 必须做法（Do） | 禁止做法（Don't） |
|---|---|---|
| 颜色与主题 `*` | Chrome 用 `Theme.*` / `Palette.*`；观片底上的文字、选中框、焦点线用 `PhotoMat`（`mat.text` / `mat.selection` / `mat.focus`） | 裸系统色（`.blue` / `.secondary` / `.primary` / `.accentColor`）、随意硬编码 RGB、在观片底上套用 Chrome 主题色 |
| 色彩隔离 | 主题只改变机身 Chrome；观片底保持中性灰 | 把 `Theme` / `Palette` 传入 `ImagePipeline`、Metal 像素渲染或导出 |
| 材质与容器 `*` | 连续机身 `InstrumentPlate()` + `Seam()` / `Hairline()` 分隔 | `GroupBox`、`.regularMaterial` / `.ultraThinMaterial` 等玻璃材质、卡片嵌套、重复标题渐变、机身噪点纹理 |
| 控件体系 `*` | 连续数值用 `AdjustmentRow` / `GradientAdjustmentSlider`；按键用 `.key` / `.ghostTool` / `PrimaryKeyStyle`；开关用 `.instrument` / `.latchingKey` / `LampSwitch` | 原生 `Slider`、`.buttonStyle(.bordered)` / `.borderedProminent`、`.toggleStyle(.switch)` |
| 焦点与无障碍 | 禁用系统蓝色焦点外环（`.focusEffectDisabled()` / `focusRingType = .none`），用控件内底边短线 `instrumentFocusMark` 提示；保留键盘导航、VoiceOver 与减少动态效果 | 放任系统焦点外环覆盖控件、或禁用外环后不提供内部焦点提示 |
| 圆角与层次 `*` | 照片／缩略图／结构面板 `0 pt`；输入框 `2 pt`；键帽／数据屏 `3 pt`；自定义浮层上限 `4 pt` | 超过 `4 pt` 的自定义浮层或卡片圆角、对照片或滚动条做圆角裁切 |
| 主键与说明 | 单视图最多 1 颗 `PrimaryKeyStyle`；静态说明收进面板标题 `InfoHintButton`（`?` 弹窗）；带灯紧凑键的机制说明用 `.instrumentHoverHint` | 多个橙色主键、在参数流里堆砌多行静态提示文字、为非按键状态灯另起孤立灯珠 |
| Sheet 外壳 `*` | 所有独立 `*Sheet.swift` 与表单根节点统一套 `.instrumentForm()` | 独立弹窗漏套 `.instrumentForm()` 导致混用系统默认按钮／输入框／底色 |
| Token 同步 `*` | 修改共享色值或尺寸时同步更新 `DarkroomTheme.swift` 与 `darkroom_instrument_tokens_v3.json` | 单边修改 Swift 或 JSON 导致事实源分叉 |

## Swift 组件选型表

新建界面优先复用下列既有原语，不重复实现键帽、推子或分隔线：

| 交互意图 | 首选 Swift 原语 | 定义文件 | 关键约定 |
|---|---|---|---|
| 连续数值调整 | `AdjustmentRow` / `GradientAdjustmentSlider` | `ParameterRow.swift` | 标签 80 pt / 推子 / 数值 64 pt（含 16 pt 单位位）；支持 Shift 1/10 精调、双击复位、数值校验 |
| 视图唯一主操作 | `.buttonStyle(PrimaryKeyStyle(height:))` | `DarkroomControls.swift` | 每视图最多 1 颗；禁用态回退为同高中性禁用实体键 |
| 常规操作键 / 图标键 | `.buttonStyle(.key(...))` / `.iconKey` | `DarkroomControls.swift` | 默认 28 pt 高；联排传 `position: KeyPosition(index:count:)`；带键面灯传 `lampInside: true` |
| 次级工具栏轻量键 | `.buttonStyle(.ghostTool(...))` | `DarkroomControls.swift` | 用于标旗、评级、紧凑色标与弹窗开关；无实体侧壁，选中用 `Theme.selected` + 细描边 |
| 少量固定互斥选项 | `KeyRow` | `DarkroomControls.swift` | 默认外部下排灯（`lampsInside: false`）；顶栏与高频编辑行用 `lampsInside: true`；长标签传 `wrappingColumns:` |
| 低频离散档位 | `DetentSelector` | `DarkroomControls.swift` | 观片底等低频离散选择；不用于连续数值 |
| 有序固定档位滑槽 | `DetentSlider` | `InstrumentFormControls.swift` | 如缓存额度 1/5/10 GiB，三档吸附，双击回默认 |
| 视图／表单行为开关 | `Toggle` + `.toggleStyle(.instrument)` | `InstrumentFormControls.swift` | 58×26 pt 横向拨片，右侧单一“已开启／已关闭”，橙色仅表开启 |
| 独立多选开关 | `Toggle` + `.latchingKey` / `.namingComponent` / `.importCheck` | `InstrumentFormControls.swift` | 互相独立不联动；`instrumentForm()` 默认设为 `.latchingKey` |
| 面板启用／旁路灯键 | `LampSwitch` | `DarkroomControls.swift` | 16×16 pt 带灯自锁键，独立于折叠箭头 |
| 有界整数输入 | `InstrumentIntegerStepper` | `InstrumentFormControls.swift` | 数值窗 + 相邻加减键；无效草稿保留旧值并阻塞提交 |
| 表单文本框 / 参数读数 | `.textFieldStyle(.instrument)` / `ParameterReadout` | `DarkroomControls.swift` / `ParameterRow.swift` | 表单输入带凹槽描边；参数静止读数走独立原生绘制层，点击进入编辑器 |
| 折叠面板 / 标题 / 子分组 | `PanelSection` / `PanelTitle` / `SubgroupLabel` | `DarkroomControls.swift` | `PanelSection` 传 `info:` 自动渲染 `?` 帮助弹窗；`SubgroupLabel` 用 `SilkText` + `Hairline` |
| 区域与次级分隔 | `Seam()` vs `Hairline()` | `DarkroomControls.swift` | `Seam`（2 物理像素暗+亮刻缝）仅用于主区域边界；子分组与工具栏断点用 1 物理像素 `Hairline` |
| 说明提示与悬停浮层 | `InfoHintButton` / `.instrumentHoverHint(...)` / `.help(...)` | `DarkroomControls.swift` | 面板长解释用 `InfoHintButton`；带灯实体键机制解释用非激活悬停卡；简短提示用 `.help` |
| 数据屏与列表行 | `ScopeDisplay` / `PhotoDisplayFrame` / `ListRowLabel` | `DarkroomControls.swift` | `ScopeDisplay` 仅展示实测数据；`PhotoDisplayFrame` 为 3 pt 直角纯色框；选中行左侧 2 pt `accentSignal` |
| 换图暂锁与固有禁用 | `.editingDisabled(_:temporarilyLocked:)` / `.controlUnavailable(_:)` | `DarkroomControls.swift` | 换图暂锁保留亮度与选中灯；固有不可用控件仍显示禁用外观 |
| Sheet / 表单外壳 | `.instrumentForm()` | `DarkroomControls.swift` | 统一字体、机身底板 `InstrumentPlate()`、默认 `.key` / `.instrument` / `.latchingKey` 样式 |

字体统一使用 `DarkroomTheme.swift` 中的语义扩展：`.body13`（正文 13 pt）、`.section`（分组标题 12 pt semibold）、`.value`（12 pt medium 等宽数字）、`.caption11`（11 pt 辅助文案）、`.silk` / `SilkText`（11 pt semibold，拉丁字母自动大写并加 0.08 em 字距，中文不加字距）。

## 材质与几何

光源统一在上方。凸起件上亮下暗、投影向下；凹入件保留上边内影与下边亮边。机身不加噪声、照片纹理或玻璃反射；轻微厚度来自底侧面和投影，不在操作件周围增加外框或空白键槽。

| 部位 | 几何与光影 |
|---|---|
| 普通键 | 28 pt 高、3 pt 外圆角；顶面不内缩，底侧面 1.25 pt；沿外轮廓内缩 0.5 pt 描 0.75 pt 上半周渐变高光（顶部亮、中线渐隐），接触影 y 0.8／radius 0.6，扩散影 y 2／radius 2.5 |
| 紧凑键 | 18／22／24 pt 高；小于 22 pt 的底侧面 0.75 pt；联排键只在整组外角倒圆，保留 1 pt 接缝 |
| 轻量化工具键 | `GhostToolButtonStyle`（默认 22 pt，紧凑色标 20 pt）；静止无底无壁，悬停叠 6.5% `Theme.text`，选中填 `Theme.selected` 并加 0.5 pt `material.edge`（65%）轮廓 |
| 选中与按住 | 锁定时底侧面缩至 1/4，按住时为 0；选中用中性面、加粗字与橙灯；减少动态效果时取消标签位移和选择动画 |
| 禁用按键 | 保留键帽渐变、侧壁与锁定位置；键面叠加 45% `surface.panel`，阴影降为 45%，文字／图标用 `text.disabled`，轮廓 0.5 pt `material.edge`（增大对比度时 1 pt `border.control`）。鼠标受压只走剩余行程的 40%，松开、拖出或失焦回弹，不响应悬停。禁用橙色主键回退为同高中性禁用实体键 |
| 橙色主键 | 树脂渐变（`key.primaryTop` → `key.primaryBottom`）、相同薄底侧面与短投影；沿圆角上半周描 0.75 pt 柔和白边（45% 渐隐），不加整圈亮框 |
| 状态灯珠 | `Lamp` 直径 6 pt，内嵌灯座；熄灭态柔和低对比（`lamp.off` 45%），点亮呈镜面径向橙光并带微弱暖光晕（`lamp.on` 42%，radius 1.8）。键面灯由 `KeyButtonStyle(lampInside: true)` 统一驱动，灯随选中或可用按压点亮，禁用受压不点亮；业务视图不另绘孤立灯位 |
| 档位旋钮 | 底座 44 pt、帽面 34 pt，同心内缩 5 pt。引线径向伸出后折向横／竖尾段对齐文字，折角圆接；当前引线 1.5 pt、其余 1 pt，当前文字加粗，指针为信号橙。保留点击、方向键与辅助功能选择器 |
| 水平推子 | 槽高 3 pt，帽面 9×16 pt，交互热区 28 pt 高；帽面中央为竖向指针（1.5×9 pt，激活 2×9 pt）：静止为 45% `text.secondary`，已修改为 `accent.signal`，聚焦或拖动为 `lamp.on`，禁用为 55% `text.disabled`。次刻度弱化（32%），双极零点刻度保持清晰（75%）；悬停整行叠 3.5% `Theme.text` 引导，滑轨行不再在标签旁重复画修改橙点（仅隐藏滑轨的数值行保留）。导入和图库的缩略图大小复用此推子 |
| 禁用推子 | 保留凹槽、帽面渐变、侧壁与阴影（降为 45%），帽面与彩色轨道叠 45% `surface.panel`。拖动帽面最多偏移 ±2 pt 后硬止挡，受轨道端点约束；松手以 120 ms 回位动画释放（减少动态效果立即归位），不改值、不提交历史，键盘与辅助功能保持禁用 |
| 横向拨片 | 58×26 pt，帽面 25×20、行程 27；仅在右侧显示“已开启／已关闭”，橙色仅表示开启；高光内缩 1 pt 并裁切。26×50 pt 上下拨杆保留为组件，当前表单不使用 |
| 数据屏与机身 | 连续机身、双像素 `Seam` 主区域刻缝与单像素 `Hairline` 子分隔、数据屏外 3 pt 斜面；照片、观片底、缩略图和 Metal 预览不参与机身材质绘制 |

界面首次使用默认石墨主题，保留用户已有选择（石墨／清冷中性偏白米白／跟随系统），双主题共享完全一致的几何与布局。材质轮廓用 `material.edge`，状态识别靠内部焦点短线、选中灯、字重与增大对比度下的 `border.control`。禁用物理反馈遵循控件运动方向：按键向下触底，推子沿轨道限位。

## 连续参数与布局

- 曝光、对比度及其他连续数值一律用“标签／水平推子／数值”逐行布局；旋钮只用于观片底等低频离散档位。
- 数值列固定预留 16 pt 单位位置，无单位时仍保留；数值输入框保持同宽、右边缘对齐。基本调整按“白平衡／明暗／质感与色彩”分组，白平衡模式沿参数控制列对齐，不重复显示标题。
- 推子向右增大，抓住帽面不跳值；Shift 为 1/10 精调，切换 Shift 时重建锚点，一次拖动只提交一次。方向键、无障碍增减、双击复位、数值输入和撤销保持接通；滚轮经过只滚动面板。
- 数值输入在提交或失焦时校验；非数字、非有限值及超出范围的草稿保留原文，在字段下方用错误图标、错误色和文字说明允许范围及 Esc 取消方式，并发送辅助功能播报。有效纠正才改值，取消、原值提交及切换照片不产生修改。
- 亮度范围保留同轨双端推子，以细托线标出选中区间；两端复用实体帽面、精调和禁用限位，互相止挡。上下限读数分行，复用参数数值编辑及错误提示，允许范围随另一端更新；切换蒙版组件时清除草稿，不能把原组件的输入写入新组件。
- 布局核对须覆盖 1440×900、1280×800、1000×640，横／竖两种照片方向与石墨／米白双主题。照片坐标、观片底颜色、配方、取样与导出不随材质变化。

## 表单、弹窗与开关

| 操作关系 | 原生形式 |
|---|---|
| 固定、少量互斥选项 | `KeyRow` 联动琴键（导出元数据、主题、自动堆叠范围、智能集合布尔值等）；短表单键的状态灯放在键面 |
| 独立多选 | `.toggleStyle(.latchingKey)` 自锁键（照片勾选、候选来源、配对确认、批量调整项目）；多行标签可增高，导入缩略图文件名单行 |
| 命名组成 | `.toggleStyle(.namingComponent)` 各自锁定，上方显示首张照片真实值，固定顺序；预览与列表共用 `ExportNamingPlanner` 结果 |
| 视图行为开关 | `.toggleStyle(.instrument)` 横向拨片（显示选区、点颜色影响范围、约束裁剪、比较同步缩放） |
| 导入／导出行为开关 | `InstrumentToggleStyle(expand: true)`，标题在左，开关与单一状态文字在右对齐；长标题仅在左列换行。附件选项只在复制模式出现；“限制长边”同样用拨片 |
| 有顺序的固定档位 | `DetentSlider`（如缓存额度 1／5／10 GiB，三档吸附，双击回默认 5 GiB） |
| 有界整数 | `InstrumentIntegerStepper`（直接输入、Enter 提交、Esc 取消和相邻错误提示；无效草稿保留最后有效值并阻止保存预设与导出入队） |

- 所有独立 Sheet 与配置表单统一在根节点应用 `.instrumentForm()`，保证底板、字体、按键与输入框一致；系统原生 `Picker` / `Menu` 用于动态或长列表选项（预设、来源、集合等）。
- 处理方式、白平衡模式、曲线通道、暗角样式、智能选区方式、HSL 与色轮视图保留直接琴键入口，空间不足时传 `wrappingColumns:` 完整保留标签并换行；每行只在外角倒圆，方向键跨行切换。侧栏复制／粘贴及底部历史、参数传递放不下时换行排列，不截断操作名。
- 局部调整标题与蒙版名称分行，名称和操作提示按内容换行，不与状态及预览按钮争用宽度。画笔自动蒙版琴键保留可见分组标题，选项用开／关状态措辞；添加动作文案（“添加” / `Add`）与已添加状态文案区分。
- `DetentSelector.labelLayout` 默认 `.right`，可组合 `.top`/`.right`/`.bottom`/`.left` 按顺时针连续分组，按半粗体宽度预留避免切换移位；方向键上／左前一档、下／右后一档，首尾止挡。

## 工作流布局

- **顶栏与底栏工具条**：顶栏高 36 pt（键中心线 18 pt），右侧依次放“图库／编辑”键面灯联排键与橙色“导出”主键；画布上／下照片信息条保持 30 pt。图库与编辑中央工具栏按轻重分级（高频主开关与带灯状态键用实体键，标旗／评级／紧凑色标／弹窗开关用 `GhostToolButtonStyle` 并用 `Hairline` 分组），在 1440×900 下单排收净不折行。快捷收集（与目标菜单联排）和自动前进保留带灯实体键，并配 `.instrumentHoverHint` 非激活悬停说明浮层；切模块不重置图库查看方式（网格／单张／比较），来源、筛选、活动照片和选择集共用。
- **筛选器与零结果**：图库顶部为分组筛选器（文本／属性／元数据／无），反斜杠隐藏筛选器但保留查询，“无”关闭过滤但保留条件；零结果页提供清除筛选。
- **导入网格**：用格子描边标记选中范围，文件名旁勾记标记导入项；支持单击、Shift 范围、⌘ 多选、方向键、⌘A 与空格批量切换。已入库和疑似重复项在“所有照片”中可选中和勾选，未勾选时按 `thumbnail.importDuplicateShadeOpacity`（0.45）压暗；批量跳过开关作用于“全部勾选”，“新照片”随扫描追加。
- **文件夹差异**：独立确认表单（文件夹上下文菜单与“文件”菜单入口）。分类琴键显示数量，行内操作沿用带灯基础键且默认未选；路径与失败原因完整换行，多候选走原生菜单，冲突在表下说明并阻塞应用；Enter 仅应用已选项，Esc 处理时取消、空闲时关闭；扫描不写目录，缺失记录与编辑版本保留。
- **图库屏边与分格陈列**：主网格与胶片带外沿统一 3 pt 纯色直角屏边（`material.edge`，无渐变或叠层斜面），取自既有留白不额外增高胶片带；筛选栏直连屏边无白亮线；左右侧栏竖向调节线互为镜像（高光朝侧栏、暗线贴照片区）；底部内容与状态栏仅用细分隔线衔接。使用原生悬浮滚动条，滑块明暗随观片底切换；胶片带纵向滚轮转横向浏览（遵循系统滚动方向，横向手势仍走原生）。
- **缩略图与堆叠**：直角连续分格，相邻格共用 1 pt 分隔线；格顶左为去扩展名名称（虚拟副本保留完整版本名），右为独立文件类型，颜色标签为名称旁 6 pt 色点；格底共用整格背景无内横线，显示配对／旗标／评级与无前导零序号。堆叠用本页首／尾组员两侧细把手展开折叠，数量徽标只在本页首张底栏显示（全匹配简写总数，范围不全写 `匹配/整组`）；悬停整格轻微变底，细格线、选中描边与悬停仅用当前观片底中性色，照片保持原比例不被任何控件覆盖。
- **编辑画布与直方图**：调整工具在照片上／下方显示文件名与格式、相机与已有拍摄信息（观片底配色，不覆盖图像，不补造缺失元数据）。常规直方图绘图区高 80 pt，内含 5 区竖向网格与 3 行横向网格，按 10%／20%／40%／20%／10% 划分黑色、阴影、曝光、高光与白色，支持悬停读数、左右拖动、Shift 精调、Esc／失焦／换图取消与方向键微调；暗部与高光两颗键面灯键并排置于绘图区右上外侧，单击切换覆盖，按住 ⌥ 临时查看（松开／拖出／失焦／换图恢复）。紧凑蒙版直方图仍用 36 pt 图内控制。
- **照片切换暂锁与状态位**：常规切图在首帧就绪前保留上一张画布与导航器并立即暂锁编辑（`.editingDisabled(_:temporarilyLocked:)`），保留控件材质、亮度、选中灯、读数和滚动位置；固有不可用控件用 `.controlUnavailable(_:)` 保持禁用外观；受限物理反馈保持接通，数值改写、快捷键与星级／旗标／色标／快收暂锁，滚动／折叠／切图仍可用。窗口底栏照片状态位等待超 200 ms 显示小圆环进度（减少动态效果显示静态图标），连续切图持续显示，首帧就绪立即解锁且不做整栏淡入淡出；失败时保留旧控件仅作显示并提供重试。
- **自动调整、目标调整与去边**：基本调整的白平衡与明暗分组各配一颗紧凑“自动”文字键（局部参数不显示），分析期间保留读数与取消入口，单次提交。HSL、黑白混色、曲线的图上目标调整与手动去边的紫／绿边取样使用键面灯文字键，取样提示位于画布底边并沿用观片底配色，共用点击／拖动／Shift 精调／方向键与取消语义；系统 RAW 镜头校正开关保持独立。
- **组织、裁剪与相机风格**：底栏标旗用轻量化工具键，评级 0 与五星可直接点按，多选混合状态不点亮共同标旗或星级。裁剪页仅显示几何控制，裁剪／污点／蒙版有固定“完成”（Esc 完成，R/Q 开关裁剪／污点）；多选时右下提供“同步…”。RAW 相机风格用实体键展开双列品牌折叠侧栏，保持裁剪后比例，名称与勾记在图下，“完成”固定顶部，窄窗保证画布最小宽 480 pt。
- **导出、诊断、设置与菜单**：导出为 860×580 分组表单（左预设与分组跳转、右单滚动区、底栏持续显示摘要／首条阻塞原因与唯一橙色导出键）。相机诊断为 920×600 表单（阶段性单一橙色主键，未核验项保留独立标记）。设置分外观、缓存与存储、快捷键、Agent（服务与预览共享用横向拨片；语言切换重启生效，其余即时生效）。网格与胶片带右键菜单并列显示图标与文字，颜色标签用 `photoLabel.*` 色点，6–9 快捷键始终可用。
- **预设与窄窗蒙版**：预设左侧栏零结果时搜索栏固定顶部，空库提示只显示一次。窗口高度不足 800 pt 时，蒙版用 36 pt 紧凑直方图，省去独立检查提示行，人物／部位内容滚动且创建键固定底部，44 pt 头像与正文不缩小。

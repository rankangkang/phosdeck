# Phosdeck Agent 接入方案

目标是让 Agent 通过 MCP 完成 Phosdeck 已支持的几乎全部用户工作流，包括读取状态、查看图像、执行操作、核验结果，以及取消和恢复任务。用户从设置开启本地服务，Agent 客户端加载配套 Skill 后，可以连续完成已授权的操作，并在 Phosdeck 窗口中呈现进度和结果。

本方案规定实施顺序、接口要求和验证方法。各步骤可以继续拆成小批次提交。当前实施位置与待用户验收事项统一记录在 [STATUS](STATUS.md)，产品范围依据 [已定决策](decisions.md) 和 [上手指南](getting-started.md)。

## 功能覆盖

以用户动作计覆盖。同一动作的菜单、快捷键、上下文菜单和手势共用一个入口。表中的每个分支都要有对应的调用与验证，`tools/list` 只发布已实现的分支。参数默认沿用原生模型的枚举、单位、范围和可用条件。用户决定最终覆盖范围及例外。

原生系统选择面板由用户授予文件访问。MCP 开关、图像共享和连接凭据由本机用户管理。系统窗口管理、文字编辑器撤销及系统剪贴板走原生交互。App 专用的工作区布局、照片撤销和调整传递纳入工具。第二步的六个工具见[首批接口](#首批接口)。

### 第三步 图库 导入和恢复

| 工具 | 操作、输入及结果 | 原生入口和边界 |
|---|---|---|
| `list_library_sources`、`list_recent_catalogs` | 列出根目录、子目录、集合、特殊来源、近期图库及可用状态。返回 ID、名称和数量 | `AppModel.reload`、`CatalogStore.roots`／`folderPaths`、`recentCatalogs`。只读 |
| `create_catalog`、`open_catalog` | 名称与位置授权 ID 新建，或用近期图库 ID／位置授权 ID 打开。返回新图库会话 | `AppModel.createCatalog`／`finishCatalogOpen`、`CatalogExtensionChange`。核验位置与 schema，旧后缀沿用改名／保留／取消确认。新建与改名遵守无覆盖语义 |
| `request_file_access` | 按操作用途打开原生文件或目录面板。返回等待用户的任务，选定后返回本次用途的位置 ID | `AppModel.directoryPanel`、`NSOpenPanel`、`AccessLease`。保留 App 沙箱权限与后续文件校验 |
| `relocate_library_root`、`locate_photo_original` | 根目录 ID／照片版本 ID 与新位置，返回身份核验、不可用项和更新范围 | `AppModel.relocate`／`locateOriginal`、`RootRelocator.prepare`／`commit`。引用路径变化，身份核验及受影响版本保留 |
| `plan_photo_import` | 引用／复制、来源、目标、包含子目录、跳过已入库、候选筛选、日期布局、附件映射、同名策略、集合和成对检测。返回候选、阻塞问题及计划 ID | `ImportSheet`、`ReferenceImporter.preview`、`ImportPlanner.plan`。计划只读业务数据，冻结候选与文件身份 |
| `start_photo_import`、`resolve_import_conflict` | 计划 ID、候选 ID，按冲突 ID 选择独特命名／跳过／受限覆盖，显式指定是否应用到余项。返回任务和逐项结果 | `runReference`／`startCopy`／`runCopy`／`resolveImportConflict`。复制使用现有暂存、回读和旧文件保留 |
| `show_recent_import` | 打开最近导入、开始筛选或返回原来浏览位置，回读选择和筛选 | `showLastImport`／`returnFromImport`。工作区状态变化 |
| `scan_library_folder`、`plan_folder_review`、`apply_folder_review` | 根目录／子目录、包含子目录、已选差异及候选位置。返回直接扫描结果，或差异计划及应用报告 | `AppModel.scan`、`FolderReview.preview`／`selectionIssue`／`apply`。区分直接索引和只读预检，应用前重新核验 |
| `list_import_records`、`resume_photo_import` | 查看复制计划、已完成项、失败项和旧文件恢复状态，核验后继续未完成项 | `CopyImporter.savedPlans`／`run`、`ImportRecoverySheet`。沿用原计划、冻结身份与恢复日志 |
| `restore_import_backup`、`clean_import_backup` | 计划及成员 ID，恢复到新的授权位置，或按现有确认删除指定的旧文件备份 | `CopyImporter.restoreOld`／`cleanupOld`、`ImportRecoverySheet`。恢复无覆盖，清理沿用原生不可逆确认 |
| `get_job`、`cancel_job` | 任务 ID，查询阶段、进度、逐项结果和产物，或请求取消后继续查询 | `AppModel.taskProgress`、各服务自己的执行状态和记录。保留已发布结果及失败原因 |

对应回归入口为 `AgentLibraryTests`、`CatalogFileTests`、`ImportTests`、`FolderReviewTests`、`RecoveryTests` 与 `WorkflowTests`。MCP 场景覆盖等待授权、计划失效、重连和单独报告发布与入库结果。

### 第四步 浏览 整理和全局编辑

| 工具 | 操作、输入及结果 | 原生入口和边界 |
|---|---|---|
| `set_library_query`、`refresh_library_query` | 切换来源、筛选分区和开关，设置文件名、星级比较、旗标、色标、关键词、相机／镜头／ISO／日期、排序方向、手工顺序及冻结结果。返回新的查询状态 | `setScope`、`filterChanged`、`clearFilters`、`refreshResults`、`CatalogStore.holdResults`。复用冻结范围和排序 |
| `list_photos`、`list_selected_photos`、`select_photos` | 补齐完整命中与当前选择分页，显式选择／取消／全选查询结果或选匹配的堆叠成员，指定活动照片版本。返回实际选中 ID 及数量 | `CatalogStore.page`／`allResultIDs`、`choose`、`selectAllResults`／`selectStackMembers`、`openVersion`。全选包含跨页和折叠的匹配成员 |
| `navigate_library` | 前后照片、页、浏览前进／后退及已有位置 ID。返回新位置、可见范围与活动照片 | `move`、`changePage`、`navigateBrowse`、`recentBrowseLocations`。保留原有浏览历史 |
| `set_workspace_view`、`set_viewport` | 网格／单图／编辑／比较／调查视图、编辑工具、适合／填满／倍率、平移中心、锁定位置及比较联动。返回当前视图及实际倍率 | `selectWorkspace`／`selectDevelopTool`／`selectZoom`、`PhotoViewport`、`PhotoComparison.setLinked`。只改变工作区 |
| `set_compare_photos`、`set_survey_photos` | 指定比较对象、交换、候选转参考、限定当前组／全部结果、比较相关版本。调查选择、移除、翻页及打开单张 | `beginComparison`／`swapComparison`／`promoteComparisonCandidate`／`restrictComparisonToGroup`／`compareRelatedVersions`、`beginSurvey`／`updateSurveySelection`／`removeFromSurvey`／`changeSurveyPage` |
| `set_develop_reference`、`set_before_after` | 固定／清除参考照片、参考视口、前后对比布局、指定或清除历史／快照参考。返回两侧实际照片和修订号 | `pinActiveAsDevelopReference`／`clearDevelopReference`／`toggleDevelopReference`／`selectDevelopReferenceZoom`、`showBeforeAfter`／`setBeforeReference`／`resetBeforeReference` |
| `set_clipping_display`、`retry_photo_preview` | 显示高光和阴影剪切、查看状态或重试预览 | `ClippingVisibility`、`showShadowClipping`／`showHighlightClipping`、`retryPhotoLoad`。图像观察沿用同一显影管线 |
| `set_photo_ratings`、`set_photo_marks` | 批量设置或步进星级、设置选中／拒绝／无旗标、颜色标签，可显式前进。返回每张前后值及撤销 ID | `updateOrganization`／`stepRating`、`CatalogStore.setOrganization`／`setRatings`。图库写入，批次核对目标 |
| `list_keywords`、`edit_photo_keywords`、`rename_keyword`、`set_photo_caption` | 查看关键词、建议与计数，添加／移除词项、全局重命名、设置题注。返回实际影响的版本和可撤销结果 | `CatalogKeywords`、`changeKeywords`／`renameKeyword`／`changeCaption`。沿用版本作用域及冲突校验 |
| `get_collection`、`save_collection`、`delete_collection`、`set_collection_members` | 分页读成员与规则，创建／改名／移除普通集合、增减明确成员、将查询结果加入既有或新集合。返回集合及实际成员变化 | `CatalogStore`、`saveRegularCollection`／`setCollectionPresence`／`saveCollectionMembership`／`collectResults`。移除集合保留照片 |
| `set_target_collection`、`edit_quick_collection`、`reorder_collection` | 指定／清除目标集合、快速集合添加和移除、切换手工排序和移动成员。返回目标与实际顺序 | `setTargetCollection`／`toggleQuickCollection`／`setManualCollectionOrder`、`CollectionOrdering` |
| `save_smart_collection`、`delete_smart_collection` | 新建／改名、编辑规则来源、字段、操作符、值和组合方式，或用当前筛选新建。返回集合 ID 和匹配数量 | `SmartCollectionSheet`、`SmartRules.from`、`saveSmartCollection`／`deleteSmartCollection`。校验规则与名称 |
| `list_photo_versions`、`create_virtual_copies`、`rename_photo_version`、`remove_photo_versions` | 查看同原片版本，从当前或指定历史／快照建立版本，改名或移除明确版本。返回版本 ID 和撤销能力 | `CatalogStore.versions`、`saveVirtualCopies`／`renamePhotoVersion`／`removePhotoVersions`。移除编辑版本保留原片 |
| `list_photo_stacks`、`edit_photo_stack`、`plan_auto_stacks`、`apply_auto_stacks` | 查看组与有序成员，分组／合并、移出、拆分、解散、移动、设封面、折叠／展开指定组或查询范围。按拍摄时间自动分组先预览再应用 | `StackAction`、`saveStackAction`／`saveAutoStacks`、`AutoStackSheet`。回读实际成员及范围 |
| `list_raw_jpeg_pairs`、`plan_raw_jpeg_pairs`、`apply_raw_jpeg_pairs`、`unlink_raw_jpeg_pair` | 查来源和关系，范围内检测、核验候选、手动指定配对及解绑。配对版本定位、比较和入组复用选片、比较和堆叠工具 | `PairingSheet`、`RawJpegPairing`、`savePairs`／`removePair`。保留两侧来源及版本 |
| `get_photo_recipe`、`set_global_adjustments`、`reset_adjustments` | 读原生参数及有效范围，按字段设置或按原生重置范围恢复。覆盖白平衡／原样、曝光、对比、饱和、四段明暗、纹理、清晰度、去雾、鲜艳度、彩色／黑白 | `DevelopPanel`、`EditRecipe`、`DevelopAdjustments`、`changeRecipe`／`commitRecipe`。使用保存配方版本，限制文件格式及 RAW 解码能力 |
| `set_tone_curve`、`set_zone_lighting`、`set_color_adjustments` | 曲线通道及点增删改、通道重置、五区 EV、HSL 八色、黑白混色、阴影／中间调／高光／全局色彩分级与混合平衡 | `ToneCurvePanel`、`ToneZones`、`ColorGrading`、`DevelopPanel`。点颜色与画布取样见第五步 |
| `set_detail_adjustments`、`set_effects` | 通用锐化／降噪、RAW 锐化／降噪／镜头校正、紫边／绿边数量及范围、暗角样式和形状、颗粒大小和粗糙度。返回实际接受的参数 | `GeneralDetail`、`RAWDetailSettings`、`ManualDefringe`、`CreativeVignette`、`FilmGrain`。沿用渲染顺序与支持范围 |
| `run_automatic_adjustment`、`apply_relative_exposure`、`match_total_exposures` | 自动白平衡／色调、按 EV 调整目标、以明确源照片匹配总曝光。返回任务及跳过原因 | `AutomaticAdjustmentEditing`、`applyRelativeExposure`／`matchTotalExposures`。按现有批次事务保存与撤销 |
| `transfer_adjustments` | 复制、粘贴、同步、沿用上一张、应用预设，显式传源、目标和 `RecipePasteOptions` 组。支持已有强度及预览 | `copyAdjustments`／`applyAdjustments`、`AdjustmentPreview`。只改所选参数组，批量结果逐项回读 |
| `list_adjustment_presets`、`edit_adjustment_preset` | 搜索、筛选收藏／分组、保存／更新／改名／删除、收藏与分组。返回预设及是否可撤销 | `PresetBrowser`、`PresetManagement`、`savePreset`。按原生能力报告撤销 |
| `plan_xmp_preset_import`、`import_xmp_presets` | 从授权 XMP 读取支持字段、预检诊断、选择记录后批量导入。返回导入及跳过项 | `XMPPresetReader`、`XMPPresetImportSheet`、`importXMPPresets`。保留支持的 XMP 子集 |
| `list_edit_records`、`preview_adjustment`、`apply_edit_record` | 分页历史和快照，预览历史／快照／预设／参数组或恢复已保存记录。返回预览或新的保存版本 | `editHistory`／`loadMoreHistory`、`previewSavedEdit`／`previewPreset`／`beginDevelopGroupPreview`／`applySavedEdit`。预览只改工作区 |
| `save_edit_snapshot`、`delete_edit_snapshot`、`redo_operation` | 建立／改名／移除快照，或对已由 MCP 撤销的动作重做。返回快照及实际撤销语义 | `saveSnapshot`／`deleteSnapshot`、`AppModel.undo`。重做只匹配明确的操作 ID 与栈顶 |

对应回归包括 `CatalogQueryTests`、`BrowseHistoryTests`、`ComparisonTests`、`KeywordTests`、`CollectionOrderingTests`、`SmartCollectionTests`、`VirtualCopyTests`、`StackTests`、`RawJpegPairTests`、`DevelopV2Tests`、`AutomaticAdjustmentTests`、`PresetManagementTests`、`AdjustmentPreviewTests` 和 `XMPPresetImportTests`。测试按实际工具分支选择，补 UI 与 Agent 交替写入、版本冲突和同批重发。

### 第五步 画布 局部与修复

| 工具 | 操作、输入及结果 | 原生入口和边界 |
|---|---|---|
| `set_crop`、`set_photo_geometry` | 裁剪矩形、比例／锁定／横竖切换、拉直、九十度旋转、横纵翻转、透视滑块与约束裁剪。返回实际裁剪和保存版本 | `PhotoCanvas`、`CropInteraction`、`EditRecipe.cropFromDisplay`／`rotateCanvas`、`PhotoGeometry`。核对预览版本及几何可行性 |
| `solve_perspective`、`edit_perspective_guides` | 自动透视、参考线新增／选中／端点移动／删除／清除、完成及取消。返回求解状态、有效线和已应用参数 | `applyUpright`、`PerspectiveEditing`、`UprightCorrection`。复用计算及失效检查 |
| `sample_preview`、`adjust_from_preview` | 绑定预览的坐标读 RGB／剪切。白平衡中性取样、亮度分区定位、直方图分区调节、HSL／黑白／曲线目标调整、紫边／绿边取样 | `DisplayPixelSampler`、`ToneSampling`、`TargetedEditing`、`DirectAdjustments`。透明像素及数据不可用沿用原生判断 |
| `edit_point_color` | 点颜色添加／取样／选中、调整色相／饱和／亮度和范围、显示影响范围、重置及删除。返回采样与更新 | `PointColorEditing`、`PointColorPanel`。采样绑定当前渲染，修改使用配方事务 |
| `get_mask_state`、`edit_mask_group`、`edit_mask_component` | 查询选区，新增、选择、复制、重命名、组合／反转、启用／禁用和删除组或组件。返回实际 ID、顺序、操作和可撤销结果 | `MaskEditing`、`MaskPanel`、`LocalAdjustment`、`MaskComponent`。组与组件按版本隔离 |
| `apply_mask_brush_stroke`、`set_mask_shape`、`set_mask_range` | 画笔路径、大小、羽化、流量、密度、自动蒙版与擦除。线性／径向几何与控制点。颜色取样／增减和亮度上下限 | `maskPointer`、`sampleMaskColor`、`MaskGeometry`、`MaskPanel`。提取图像坐标动作，一次笔划或形状调整一次保存 |
| `get_photo_preview`、`set_mask_display`、`set_local_adjustments` | 补齐局部放大和叠加预览，引导线、选区覆盖颜色和样式、查看有无局部效果。设置或重置蒙版强度与局部显影参数 | `PhotoCanvas`、`MaskPanel`、`beginMaskEffectPreview`／`endMaskEffectPreview`、`changeLocalDevelop`。查看与保存分开，局部参数重置保留选区 |
| `transfer_local_adjustments`、`edit_local_adjustment_preset` | 复制／粘贴、列出／保存／应用／重命名／删除局部参数预设。返回参数或实际改动 | `MaskEditing`、`CatalogLocalPresets`。只改变局部参数，保留选区几何 |
| `start_smart_mask`、`edit_smart_mask_selection`、`apply_smart_mask` | 对象点／框、增减提示及提示撤销、候选；人物单选／多选／全选、整人、部位、脸框与细化、拆分或合并。返回分析任务、当前候选、叠加预览及新增组件 | `SmartMaskEditing`、`SmartMaskEngine`。绑定候选代次、照片及配方，缺模型返回条件，取消复用任务接口 |
| `get_spot_repairs`、`edit_spot_repair` | 查看和选中污点，点／路径、模式、半径／羽化／不透明度、移动、选择／重算来源、禁用和删除 | `SpotEditing`、`SpotRepair`。目标与采样源各自校验，回读实际 ID、来源和修订号 |
| `set_canvas_guides` | 设置构图辅助线、裁剪引导及污点引导显示，返回当前显示状态 | `cycleCropGuide`、`PhotoCanvas`、`SpotPanel`。只改变显示 |

对应回归包括 `PerspectiveTests`、`UprightTests`、`FlipTests`、`InspectionWorkflowTests`、`TargetedAdjustmentTests`、`DirectAdjustmentTests`、`PointColorTests`、`ManualDefringeTests`、`MaskingTests`、`SmartMaskTests`、`LocalParameterPresetTests` 和 `SpotRepairTests`。关键验收用有方向标记的合成图核对 Agent 输入的位置和原生结果。

### 第六步 合成和输出

| 工具 | 操作、输入及结果 | 原生入口和边界 |
|---|---|---|
| `plan_photo_merge` | 明确源照片版本及顺序，选择全景、HDR、HDR 全景、对焦、平均、中值、加法、变亮、变暗或滤色。校验对齐、去鬼影、投影、裁剪、自动调平、边界变形、填边、包围曝光张数及源尺寸 | `PhotoMergeSession`、`PhotoMergeOptions.validate`、`PhotoMergeEngine`。计划绑定原片身份与集合范围 |
| `render_merge_preview`、`get_merge_preview` | 计划 ID 生成预览，可调整显示 EV 并回读对应图像和预览代次 | `PhotoMergeSession.makePreview`／`updateDisplay`。复用取消和失效语义，显示 EV 单独记录 |
| `save_photo_merge` | 预览 ID、TIFF32／DNG、授权位置和文件名，设置与来源堆叠。返回文件 ID、入库版本 ID、当前普通集合的加入状态和堆叠结果 | `PhotoMergeSession.save`、`completePhotoMerge`。分别报告发布、核验和入库，只有堆叠等原生可撤销动作返回撤销 ID |
| `list_export_presets`、`edit_export_preset` | 列出内置／自定义预设，另存、改名、删除和恢复默认。返回导出选项 | `ExportPreferences`、`ExportSheet`。沿用内置预设限制 |
| `plan_export`、`get_export_preview` | 明确照片、授权位置、单／多规格、预设、JPEG／PNG／TIFF16、质量、长边、铺底、命名组件、序列、子目录、元数据。返回命名／同名检查和铺底预览 | `prepareExport`／`prepareMultiExport`、`ExportBatchPlanner`、`ExportSheet`。预览沿用已显影图，输出保存冻结配方 |
| `run_export` | 计划 ID，返回任务及每个版本／规格的实际输出 | `AppModel.export`、`ExportService.run`。同卷暂存、无覆盖发布并回读，原片受保护 |
| `list_export_records`、`verify_or_retry_export`、`reauthorize_export_location` | 过滤未完成记录、单项／整批校验并重试、重授原始目标。返回冻结名称、结果与错误 | `ExportRecoverySheet`、`retryExports`、`ExportService.history`／`reauthorizeTarget`。保持原目标和方案，核验已发布文件 |
| `reveal_file_in_finder` | 按当前图库、导入旧文件备份或输出 ID 在 Finder 显示已解析文件 | `WorkspaceCommands`、`ImportRecoverySheet`、`revealExports`。通过已有对象与访问权限解析位置 |

对应回归包括 `PhotoMergeTests`、`PhotoMergeFinishTests`、`FocusStackRegressionTests`、`ExportTests`、`MultiExportTests`、`ExportNamingTests`、`ExportMetadataTests` 和 `RecoveryTests`。合成母版发布后入库失败与导出部分成功分别验证。

### 第七步 设置 诊断和维护

| 工具 | 操作、输入及结果 | 原生入口和边界 |
|---|---|---|
| `get_preferences`、`set_preferences` | 外观、观片底、左右栏／胶片带及大小、导航器、筛选条、集合／预设／历史／快照／蒙版面板展开、单分组和已修改筛选、缩略图大小及自动前进 | `SettingsSheet`、`WorkspaceView`、`DevelopPanel`、`AppModel.persistWorkspace`。按现有控件约束及作用域更新 |
| `show_app_panel` | 打开指定的设置页、快捷键、任务结果、导入或输出恢复面板。返回打开后的状态 | `WorkspaceCommands`、`SettingsPane`、`WorkspaceView`。沿用当前窗口与模态约束 |
| `list_language_packs`、`edit_language_pack`、`select_language` | 查看、从授权文件导入、选择或移除语言包。返回选择及重启生效提示 | `LanguagePackSettings`、`LanguagePackStore`。沿用解析和文件写入约定 |
| `get_storage_usage`、`set_cache_quota`、`clear_thumbnail_cache` | 度量图库、缓存、任务暂存和恢复文件，设置原生容量档位或清理当前图库缩略图。返回实际值、不可访问项数与完成状态 | `StorageInspector`、`updateCacheQuota`／`clearThumbnailCache`。跟随缓存维护锁 |
| `back_up_catalog`、`restore_catalog_backup`、`export_catalog_manifest` | 选择授权目标，备份当前图库，或从授权备份恢复为新图库，或导出 JSON 管理清单。回读目标及新图库会话 | `AppModel.backup`／`restoreBackup`／`createCatalog`、`CatalogStore`。新建及发布无覆盖 |
| `run_camera_diagnostics`、`save_camera_diagnostics_report` | 授权目录、本地相机诊断、取消及保存报告。返回每张检查与预览结果及报告 ID | `CameraDiagnosticsView`、`CameraDiagnostics.files`／`inspect`／`save`。沿用本地处理和样本范围 |

对应回归包括 `LocalizationTests`、`FoundationTests`、`WorkflowReuseTests`、`CameraDiagnosticsTests` 与 `CatalogFileTests`，设置和报告另在固定体验 App 实窗核对。检查名单同时覆盖菜单、网格与胶片带上下文动作、左栏、右栏、画布、设置和任务面板。

## 接口设计

首批注册项按下方接口实现。后续工具沿用相同的状态、任务和结果语义，具体字段以各批注册的 schema 为准。

### 共享原生操作

调用链为 Agent 客户端 → MCP 协议适配 → 原生操作入口 → 现有图库、显影及文件服务。UI 与 MCP 共同使用业务校验、提交、刷新和撤销逻辑。按功能逐步提取当前混在手势或表单中的逻辑，操作返回结构化结果。

工具按稳定的业务动作组织，支持参数化查询和批量操作。注册项同时描述输入和输出 schema、枚举、单位和范围，并标注只读或实际写入行为。字段校验复用现有模型，写入只接受已声明的操作和字段。原生调用从结构化业务结果生成界面状态和提示，MCP 从同一结果生成响应。

### 工具结果

`structuredContent` 始终含 `status`（`success`、`warning` 或 `error`）、`summary`、`next_actions` 和 `artifacts`。`data` 按工具返回业务数据。`artifacts` 含对象类型、ID 和必要的显示名称，文件位置由 App 依据授权和已有记录解析。文本块携带同一 JSON，预览另带 `image/png` 图像块。业务失败使用 `isError: true`，并返回 `error.code` 和恢复条件。协议消息的错误由 MCP 层返回。[MCP 工具规范](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)

| 错误代码 | 调用方下一步 |
|---|---|
| `invalid_arguments`、`unsupported_operation` | 读取 schema 或可用条件，修正请求。 |
| `no_catalog`、`catalog_changed`、`stale_cursor` | 读取工作区，取得当前图库会话和查询。切库后重新定位对象。 |
| `photo_unavailable`、`stale_photo`、`stale_preview` | 回读照片、来源和配方，必要时重新取图。未能确认目标时结束当前修改。 |
| `workspace_busy`、`native_interaction_active` | 查询当前状态。等待任务结束或用户完成原生编辑，再核对目标。 |
| `image_access_disabled`、`file_access_required` | 等待用户开启图像共享，或按任务要求完成原生文件授权。 |
| `rating_conflict`、`undo_conflict` | 回读实际评级和工作区状态。只有用户意图仍匹配时才提交新的修改。 |
| `collection_unavailable`、`stale_collection`、`stale_stack`、`pair_unavailable` | 回读集合、堆叠或配对及其成员，核对当前 ID 与顺序。 |
| `request_id_conflict`、`request_expired` | 核对上次调用结果，回读后以新请求标识提交当前动作。 |
| `stale_plan`、`stale_conflict` | 重新查看计划或任务，依据当前候选或冲突选项提交。 |
| `job_unavailable`、`import_record_unavailable` | 核对图库及复制记录，确认是否可以继续。 |
| `service_stopped` | 在设置重新取得连接配置和令牌，再读工作区。 |
| `operation_failed` | 按结果中的提交状态恢复。保存状态不确定时先回读记录或文件。 |

### 状态与图像

当前打开的图库使用 `catalog_session_id`，每次切库或重开时重新生成。`photo_id` 对应版本 `Photo.id`。`source_revision`、`recipe_revision` 分别使用 `Photo.revision`、`Photo.recipeRevision`。虚拟副本独立定位并沿用原片身份校验。MCP 传输会话、服务实例和图库会话各有独立生命周期。

查询沿用 `PhotoQuery` 和 `CatalogStore.page`。`matched_count` 是当前筛选的完整命中数，`visible_count` 是按折叠规则呈现的总数，堆叠行带本次命中组员数及整组数。读取列表保持界面选片和页位置。游标绑定图库会话、查询、列表类型、数据库变更和页大小。选择列表还绑定选择代次。发生变化时返回 `stale_cursor`，从首屏重读。页内数据由同一数据库读取得出。

预览绑定图库会话、照片 ID、来源与配方修订号、渲染方式、实际尺寸和 `preview_id`。首批按已保存配方显影，未建立配方的照片在内存中使用原生基线。来源文件身份检查沿用 `ImagePipeline`。工作区显示上张照片、处于临时对比或存在草稿时，仍按请求中的明确版本读取。预览查询不触发 `loadActive` 的保存和元数据刷新。发布前复查图库和修订号，过期结果返回错误。

对外坐标采用已返回图像的左上原点，横向向右、纵向向下，以图像边界归一化到 `[0,1]`。像素中心按实际宽高换算，局部图像返回其在完整预览中的范围。画笔、取样和参考线请求携带 `preview_id`，从同一渲染几何转换至原生坐标。第五步用旋转、翻转、裁剪及透视的合成图核对该转换。

设置说明图像共享及数据去向，初次开启服务时默认关闭图像共享，用户可在本机开启。使用云端模型的客户端可能向模型服务发送工具返回的图像。普通查询返回必要的显示名、版本、评级和来源状态，安全书签、原片绝对路径和原始配方数据由 App 管理。

### 修改与撤销

修改指定图库会话、目标 ID、期望值或版本及请求标识。耗时查询和计算传递不可变快照，业务提交和必要的 UI 状态发布遵守现有隔离约定。来自多个客户端的修改串行执行，在数据库事务中再次核对目标和期望值。用户手动编辑、切换图库或存在未完成手势时，返回冲突原因及刷新／等待的动作。

单次和批次修改沿用现有事务与撤销边界。结果返回实际受影响对象、`commit_state`（`not_committed`、`committed` 或 `unknown`）和可撤销的 `operation_id`。事务已保存、后续界面刷新失败时返回 `warning` 和已提交状态，客户端先回读，避免重复写入。撤销绑定实际 `AppModel.undo` 栈顶动作及其分组身份，`redo_operation` 使用通过 MCP 撤销时的同一 ID。其他动作入栈、用户先行撤销、栈清空或切库时，旧操作标识会失效。无值变化时返回空操作标识。文件写入报告发布和回读结果及可用的恢复方式。

写入携带 `get_workspace` 返回的 `request_epoch` 及客户端生成的 `request_id`。同一代次内，同 ID 和相同参数返回已有结果或已受理的任务 ID，同 ID 不同参数报冲突。切库使旧会话的新写入请求失效，并保留已受理动作的重发结果。去重记录有界，换代前等待在途任务结束，代次过期后先回读再提交。任务控制使用 `job_id`，冲突选择还绑定 `conflict_id`。HTTP 重连保留业务去重，App 重启后按已有持久化任务回读结果，无法确定的状态先核验实际数据。

### 多步任务

导入、智能选择、合成和导出以任务 ID 连接准备、预览、执行及结果。任务提供进度、阶段、已完成对象、失败原因、取消入口及实际支持的恢复动作。文件或选项选择面板对应等待用户输入状态，用户完成后可继续同一任务。

任务使用 `queued`、`running`、`waiting_for_user`、`succeeded`、`partially_succeeded`、`failed` 和 `cancelled`。取消请求先返回当前状态，达到终态后按已提交或已发布内容报告结果。客户端断线后通过 `get_job` 查询业务状态，取消通过 `cancel_job` 进入原生取消流程。服务关闭时停止接受新调用，并按现有任务的提交边界结束或取消执行。

### 本地连接

设置提供本地 MCP 开关、图像共享、状态、实际端点和连接配置。开关默认关闭，开启偏好按 App 安装身份保存。运行期间绑定 `127.0.0.1:0`，由系统分配端口，成功后公布实际 `/mcp` 端点。正式 App 与 Preview 可同时运行，`serverInfo.name` 区分应用名称，`get_capabilities` 另返回 bundle ID 和本次启动的实例 ID。每次启动监听生成独立令牌，重启服务后客户端重新取得端点及令牌。绑定失败显示错误和重试入口。

首批互通以 MCP `2025-11-25` 的 Streamable HTTP 为基线，使用官方 Swift SDK `0.12.1` 的 `StatefulHTTPServerTransport` 处理 MCP 消息，使用 SwiftNIO `2.105.0` 的 `NIOPosix`／`NIOHTTP1` 提供回环监听和 HTTP 解析。每个 MCP 会话拥有各自的 transport 和 `Server`，请求 ID 仅在该会话内匹配。参考官方 conformance server 的分层和会话路由，App 的监听、认证、队列和启停用原生实现。若后续需要较新协议版本，随 SDK 能力及真实客户端互通更新。[MCP 传输规范](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports) · [Swift SDK 会话路由](https://github.com/modelcontextprotocol/swift-sdk/blob/a0ae212ebf6eab5f754c3129608bc5557637e605/Sources/MCPConformance/Server/HTTPApp.swift)

在聚合请求体和分配会话前校验确切的回环 `Host`、存在时的 `Origin` 及 `Authorization: Bearer`。无效凭据返回 HTTP `401` 和 Bearer 质询，不匹配的 `Host`／`Origin` 返回 `403`。控制请求体、空闲连接、并发和会话数量，关停时关闭监听及活动连接并清除本次凭据。网络解析在主线程之外运行。沙箱使用入站网络权限，签名沿用已有构建约定。服务生命周期由 App 持有，设置窗口负责呈现和控制。[入站网络权限](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server)

首批 HTTP 响应流随 POST 请求返回。独立 GET 流返回 `405`。每次连接处理一个请求，请求体上限 64 KiB。传输会话空闲 15 分钟或达到消息及响应大小上限时需要重新初始化，业务请求代次在监听运行期间继续有效。分页游标使用数据库读中的变更计数，目录写入后可重新读取工作区与首屏。

“复制 JSON 配置”适用于接受 `mcpServers` 和 `headers` 的 Streamable HTTP 客户端。复制的内容含当前 `url` 和 `Authorization` 请求头。服务重启后重新复制配置。

“复制 Codex 配置”生成 Streamable HTTP 的 TOML 片段。下例端口由设置实际显示值替换，`PHOSDECK_MCP_TOKEN` 由启动客户端的环境提供。Codex 配置引用变量名，令牌由用户在设置中单独复制。Preview 使用独立的服务器配置名和令牌环境变量。[OpenAI Docs 的 MCP 配置](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)

```toml
[mcp_servers.phosdeck]
url = "http://127.0.0.1:49152/mcp"
bearer_token_env_var = "PHOSDECK_MCP_TOKEN"
```

配套 Skill 随仓库发布。支持项目级 Skill 的客户端可从仓库发现；在其他工作区使用时，将 `phosdeck` 文件夹复制到客户端配置的用户 Skill 目录。[Phosdeck Skill](../.agents/skills/phosdeck/SKILL.md)

### 首批接口

工具名和业务字段采用 `snake_case`。空输入使用 `{}`。照片查询默认每页 50 张，上限 200 张。显影预览默认长边 768 像素，上限 1024 像素，使用原生 sRGB 与透明度语义。这些是第二步的有界默认值，随实际客户端接收和资源验证核对。

| 工具 | 输入 | `data` 与主要原生入口 |
|---|---|---|
| `get_capabilities` | `{}` | 应用名称、版本、bundle ID、`instance_id`、各已注册工具的当前可用性及原因，图像共享状态。取自 `Bundle`、服务设置及 `AppModel` 的可用条件 |
| `get_workspace` | `{}` | `catalog_session_id`、`request_epoch`、图库显示名、当前来源和查询、视图和工具、活动 `photo_id` 与修订号、选择数量及最多 50 个 ID、是否截断、任务和草稿状态。无图库时会话和活动照片为空，仍可读取服务状态。取自 `AppModel`，完整选择用 `list_selected_photos` 分页 |
| `list_photos` | `catalog_session_id`，可选 `cursor`、`page_size`、`listing` | `items`、`matched_count`、`visible_count`、`next_cursor`。每项含 `photo_id`、名称、版本、源与配方修订号、拍摄信息、评级、旗标、色标、源可用性和堆叠信息。使用 `CatalogStore.page`，返回稳定的排序和分页状态 |
| `get_photo_preview` | `catalog_session_id`、`photo_id`、`source_revision`、`recipe_revision`，可选 `long_edge` | `preview_id`、目标身份、实际图像尺寸、坐标空间与直方图，另附 PNG。使用 `CatalogStore.photo`、`ImageRequest` 和 `ImagePipeline.render`，校验图像共享、来源及版本 |
| `set_photo_rating` | `catalog_session_id`、`photo_id`、`expected_rating`、`rating`（两种评级均为 0 至 5 的整数）、`request_epoch`、`request_id` | `photo_id`、`previous_rating`、`rating`、`changed`、`commit_state`、`operation_id`。复用 `AppModel.updateOrganization` 的保存和回读。MCP 明确指定目标，事务校验期望评级，并关闭自动前进 |
| `undo_operation` | `catalog_session_id`、`operation_id`、`request_epoch`、`request_id` | 被撤销的 `operation_id`、已核对的恢复结果及 `commit_state`。复用 `AppModel.undo`，栈顶身份或当前值冲突返回 `undo_conflict` |

第二步沿 `CatalogQueryTests`、`StackTests` 和 `WorkflowTests` 验证分页查询跨页、折叠堆叠两种计数、切库后的旧游标和已保存预览版本。用合成图库的一张明确照片验证评级并回读，重复相同请求只产生一次提交，手动改动触发版本冲突，用户在原生菜单可撤销 MCP 评级，MCP 只能撤销匹配的栈顶动作。验证结果同时核对当前照片、数据库、界面及真实客户端返回。

### 图库和导入接口

具体输入以 `tools/list` 为准。图库打开后，`request_file_access`、`create_catalog` 和 `open_catalog` 同样携带当前 `catalog_session_id`。系统面板返回按用途绑定的 `access_id`，打开新位置的图库文件时还会核对包含它的文件夹。切库和停止服务会使旧授权与计划失效。文件授权、计划和任务结果返回名称、相对名称及业务 ID。[macOS App 沙箱文件授权](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)

长操作返回 `job_id`，用 `get_job` 查看 `state`、`phase`、进度、`user_action` 和结果。等待复制冲突时，结果提供 `conflict_id`、文件名和当前允许的策略。取消后继续读终态及已保存结果。任务结果和来源列表用 `next_offset` 分页。工作区的 `agent_job` 表示当前进行中的 Agent 任务。

引用导入按候选 ID 选择，复制按组 ID 选择。逐张修改复制组的输入或分配附件时，用 `base_plan_id` 及原计划的候选、附件或组 ID 生成新计划。执行复用保存的源身份及复制命名决策。文件夹差异使用单独的差异与位置 ID，应用时整批重新核验。

复制记录的 `record_id` 随图库持久化。在同一图库中可用它调用 `get_job`，检查文件发布、入库、恢复记录，再继续未完成的工作。内存中的其他任务可跨 HTTP 会话查询。服务重新启动后，从当前图库和复制日志回读状态。

### 浏览选片和标记接口

`set_library_query` 接受 `list_library_sources` 返回的 `source_id`、原生筛选条件和排序。传入条件会启用相应筛选分区，也可显式控制 `filter_sections` 和 `filters_enabled`。`filters_open` 只控制筛选器显示。`hold_results` 冻结成员和顺序，`refresh_library_query` 重新计算。根据 `get_workspace` 的 `query_revision` 和 `selection_revision` 可核对全选、增减选择等依赖当前工作区的操作。

`list_photos` 默认 `listing=visible`，`listing=matches` 按查询顺序包含折叠组员。`list_selected_photos` 按版本 ID 分页，包含跨页或折叠的已选版本。`select_photos` 可替换、增加、移除或清空选择，也可选中全部命中或一个堆叠的匹配成员。打开指定版本使用 `open_version`，浏览位置和前后页用 `navigate_library`。

工作区、比较和调查工具返回实际活动照片、参考／候选版本和可见调查页。缩放和平移以对应视口为准，平移返回归一化的当前中心与等待新渲染几何的请求位置。剪切开关只影响界面显示。通过 `get_photo_preview` 查看已保存的显影结果，沿用独立图像共享开关。

`set_photo_ratings` 和 `set_photo_marks` 单次接收最多 200 个明确目标。每张传入所修改字段的当前值，任一不匹配时整批保留，并返回 `marks_conflict` 和对应照片的实际标记。相对星级以各张照片原值步进，越界停在 0 或 5。`advance` 显式开启时，仅从本批目标中的活动照片前进。批量写入返回各版本的前后标记和共同的撤销 ID。

`list_keywords` 可搜索目录词表、返回近期关键词和选中计数，并按 `photo_id` 回读该版本的关键词及题注。添加与移除限定版本，重命名沿用全图库关联校验。题注以 `expected_captions` 核对每张现有内容，遇到 `caption_conflict` 时先核对新值再决定是否重发。关键词和题注变更可通过原生撤销栈撤销。

### 集合、版本、堆叠与配对接口

`get_collection` 分页读取实际成员，普通集合按保存的手工顺序，智能集合按现行规则计算。`collection_revision` 跟踪保存的名称、规则或成员顺序。`set_collection_members` 的 `collect_results` 使用当前查询的全部命中，包含跨页、折叠及冻结范围。快速集合动作使用 `get_workspace` 的目标 ID。普通集合创建、改名及收集查询结果沿用原生保存语义，其余动作按结果中的 `operation_id` 判断能否撤销。智能集合可提供 `rules` 或 `from_current_query=true`，保存后可用返回的 `source_id` 打开。

`photo_id` 指照片版本。`list_photos` 与版本工具返回的物理 `source_id` 指同一原片。`list_photo_versions` 可用其中任一 ID 查同原片的编辑版本。`list_edit_records` 用 `record_type=history` 或 `snapshots` 查指定版本的保存记录。`create_virtual_copies` 默认复制当前保存编辑，也可以给单个目标指定一个 `history_id` 或 `snapshot_id`。复制和移除可用 `expected_revisions` 核对各目标的来源与配方，移除版本保留原片及撤销所需记录。

`list_photo_stacks` 返回各组的封面、匹配数及成员总数。指定 `stack_id` 或成员 `photo_id` 时可分页查看完整顺序及每张是否在查询内。`plan_auto_stacks` 按相邻拍摄时间差生成计划，`get_job` 分页列出候选组员及跳过原因计数。`apply_auto_stacks` 应用所审查的整个计划，提交时重新核对查询和输入，整批使用一次原生撤销。

`list_raw_jpeg_pairs` 查询已有关系，`listing=sources` 列出物理 RAW 与 JPEG 来源及目录记录的可用状态。自动配对依次调用 `plan_raw_jpeg_pairs` 的 `detect`、`verify`，再以核验后的 `plan_id` 和 `candidate_ids` 调用 `apply_raw_jpeg_pairs`。已明确是同一次拍摄时，也可用 `action=manual`、两侧来源 ID 与 `same_capture=true` 生成核验计划。每步任务均通过 `get_job` 回读。应用时复查原片和已存关系，整批提交并返回配对 ID 和撤销标识。过期时重新检测或核验。解绑保留双方原片和编辑版本。配对任一侧可用其物理来源 ID 查版本，再通过已有工具定位、比较或加入堆叠。

## 实施顺序

### 第一步 核定操作清单和接口契约

以本文件的操作清单、原生入口、系统边界和首批接口为交付。连接方式与依赖组合通过签名沙箱探针及本机客户端确认。后续具体字段随代码注册及对应测试维护，待完成项在 STATUS 追踪。

### 第二步 接入本地服务和观察能力

依赖第一步。

- 接入设置开关、服务生命周期、身份校验、实例识别和连接配置。开放能力查询、当前状态、分页照片查询和版本化图像预览。
- 建立一个由 UI 与 MCP 共用的可撤销操作作为写入接通验证，覆盖请求去重、版本冲突和明确的提交结果。
- 同步建立配套 Skill 的连接与观察部分，工具名称引用本步真实注册项。
- 验证协议交互、有效及无效凭据、Origin／Host、端口占用、多客户端、启停和 App 退出。用实际客户端读取合成照片并完成一次修改及撤销，在固定体验 App 中核对中英双主题设置与状态。

### 第三步 接入图库 导入和任务状态

依赖第二步。

- 接入图库创建／打开／切换、原生授权等待、来源重定位、引用和复制导入、冲突选择及文件夹差异。
- 从现有任务流程提取可观察的状态和结果，先覆盖导入的取消、恢复和断线后查询，供后续合成及输出复用。
- 验证从授权目录导入、跨页查询和定位。回归同名冲突、取消、部分失败、过期差异计划、切库和重新连接。输出逐项结果，并核对文件及数据库的实际状态。

### 第四步 接入整理 全局显影和记录

依赖第三步。

- 接入覆盖表中的整理、集合、版本、堆叠、关联和查询动作，以及全部现有全局参数、自动调整、预设、参数传递、历史和快照。
- 接入浏览／比较／参考照片、缩放、前后对比和常用面板状态。批量显影返回每张实际结果和整批撤销能力。
- 验证跨页选片、冻结筛选、折叠堆叠、虚拟副本身份、同请求重发、手动编辑冲突、批次保存失败和撤销／重做。预设及配方与 UI 操作使用相同语义。

### 第五步 接入画布 几何和局部编辑

依赖第四步的配方、观察和撤销契约。

- 定义预览坐标到源坐标的转换，接入裁剪、拉直、透视参考线、污点、颜色取样、图上目标调整、画笔路径、渐变、范围和蒙版组件操作。
- 接入智能蒙版的分析、候选查看、选择、增减提示、局部参数和提交，返回模型可用性及分析失败原因。
- 用同一预览版本核对坐标和参数，一笔或一次几何调整对应其原生提交边界。先定位 STATUS 中四分之一旋转为 1 或 3 的逆映射问题，再验证相关操作。
- 回归旋转、翻转、裁剪、透视、缩放及图像边缘的命中位置，同时覆盖取消、换图、过期预览和缺少模型。用合成色块／梯度核对像素位置，用已授权人物素材核对智能选区与叠加结果。

### 第六步 接入照片合成和完整输出

依赖第三步的任务及文件授权、第四步的配方和组织能力。包含局部编辑的全链路联调还依赖第五步。

- 接入所有现有合成方式、来源顺序、选项、预览、母版保存、入库和组织结果。
- 接入导出预设、命名检查、元数据、全部现有格式、多规格输出、记录、重试和取消。复用冻结配方、来源身份核验及安全发布流程。
- 验证完整任务“导入包围曝光 → HDR DNG → 人物蒙版提亮 → 两种尺寸 JPEG”。其他合成方式、PNG／TIFF16、透明度及失败恢复分别核对。
- 回归目标冲突、磁盘写入失败、发布后入库失败、取消发生在提交边界、客户端断开和任务重复请求。根据实际文件回读尺寸、格式、位深、元数据和完成数量。

### 第七步 补齐设置 维护和能力缺口

依赖已接入的图库和任务基础。

- 接入其余视图与偏好、语言包、缓存与存储、相机检查、备份、恢复为新图库及管理清单。
- 重新检查所有菜单、上下文菜单、画布、设置和恢复面板，将覆盖清单逐项对应到可调用工具及验证入口。
- 验证设置持久化、需要重启的状态反馈、缓存清理与渲染并发、备份回读和恢复定位。对受环境或授权约束的功能返回具体条件。
- 列出所有剩余缺口供用户决定处理方式，覆盖率的分母采用第一步的实际操作清单。

### 第八步 完成 Skill 客户端联调和整体验收

依赖前七步。Skill 在第二步起随每批能力维护，本步完成整体验证和分发。

- 提供可安装的 `phosdeck` Skill，主文件描述触发条件、连接、状态读取、执行及结果核验。整理、显影、局部编辑、合成、导出和恢复细节按工作流放入参考文件。
- Skill 使用工具发现和返回的 schema，引用真实工具及可用条件，按用户授权连续推进任务。需要用户输入时说明待完成动作，得到输入后继续，结束时回读实际结果。
- 在本机 Codex 完成主验收，再用第二个独立客户端核对协议及图像返回。
- 跑完整工作流、人工与 Agent 交替编辑、重连、错误恢复及覆盖清单回归。完成与覆盖范围相符的原生全量检查、固定体验 App 实窗检查和依赖声明检查，交由用户体验验收。

## 验证与交付约定

每批交付包含可执行能力、对应的 Skill 内容、受影响的回归检查，以及用户可复现的体验步骤。操作入口测试检验校验、保存和状态，MCP 集成测试检验协议到原生执行的完整调用链，实际客户端与原生窗口核对可观察结果。

整体验收至少覆盖整理与批量显影、手工几何及局部精修、智能蒙版、合成后继续编辑、多规格输出、授权及任务恢复六组工作流。小规模样例完成后，补测大批量分页、多个客户端和长任务期间的 UI 操作，检查队列上限及过期请求处理。性能测试按 AGENTS.md 固定条件记录基线与后续结果。

新增能力与现有 App 行为逐项核对。仍缺失的动作、环境跳过、未验证客户端及模型依赖都明确记录，最终完成状态由用户确认。原始日志和测量保存在 `build/`，实际检查和限制写入提交说明。

## 技术依据

- Swift SDK `0.12.1` 对应提交 `a0ae212`（2026-04-29），SwiftNIO `2.105.0` 对应提交 `2f58d8e`（2026-11-02）。引入时以实际 Xcode 解析的依赖为准，将各包的 LICENSE 和存在的 NOTICE 随包分发。Swift SDK 处于 MIT 至 Apache-2.0 迁移期，保留原始许可说明。[Swift SDK 许可](https://github.com/modelcontextprotocol/swift-sdk/blob/a0ae212ebf6eab5f754c3129608bc5557637e605/LICENSE) · [SwiftNIO 版本](https://github.com/apple/swift-nio/releases/tag/2.105.0)
- 文件选择授权与后续访问沿用系统安全作用域书签。[App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
- 配套 Skill 采用包含 `SKILL.md` 的目录结构，连接配置及工具实际支持情况由客户端联调核定。[Agent Skills 规范](https://agentskills.io/specification)

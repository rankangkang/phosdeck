# 智能蒙版模型与可用状态

系统 Vision 的整个人物选择无需额外权重；可选的对象／部位识别仍按本地研究资源提供。本文区分既有许可核查、现有程序行为和剩余事项。

## 现在能用什么

| 构建或资源状态 | 当前行为 |
|---|---|
| 干净检出的默认 Debug；没有另行准备模型 | 人物入口可检测并创建整个人物选区；对象禁用、部位注明未包含。没有自动下载。 |
| 没有模型，打开当前格式中已保存的智能蒙版 | 固定覆盖率仍可显示、调整和导出。人物可重新选择全身；对象重新识别需要 SAM，对应部位重新识别需要其模型。仍须满足原片访问、来源身份和几何校验。 |
| 只准备完整 SAM 三部分 | 对象点选／框选可用；系统整个人物仍可用，部位不启用。 |
| SAM + Selfie，没有 FaceParsing | 对象、整个人物和粗脸肤／身体皮肤／头发／衣服可用；粗脸肤明确标示“粗略”，精细五官注明未包含。 |
| 仅 Selfie，或仅 FaceParsing | 各自独立启用粗部位或可检测人脸内的精细部位；不要求 SAM。FaceParsing 的既有研究／分发限制不变。 |
| Debug 已准备完整研究模型 | 按能力复制资源并按需加载，支持既有组合；选区质量及人脸授权边界见下文。 |
| Release 产物 | 本阶段负责的研究权重会移除，保留系统人物与已保存选区；这不等于已建立正式模型分发流程。 |

画笔、线性／径向渐变、颜色／亮度范围蒙版及一般显影不依赖这些权重。已生成的选区以 UInt16 覆盖率栅格（LZFSE 压缩，单块不超过 1024×1024）随配方保存；重开、历史、快照、备份和冻结导出都不重跑模型，跨来源粘贴会跳过栅格失配的蒙版组。

**增量产物按组件更新。** 复制阶段只清理其负责的五个固定模型路径及声明，再按当前资源复制；不清理整个 `build/` 或无关文件。SAM 缺任一部分时不复制整组，Selfie 与 FaceParsing 分开处理。运行时检查完整组及文件／目录类型，损坏权重仍由实际加载报告错误，存在性检查不等于模型有效性证明。LiteRT 许可独立复制到 `Contents/Resources/SmartMaskRuntime-LICENSE.txt`，不依赖是否含权重。

## 模型来源与许可

固定文件大小和 SHA-256 见[模型清单](../Tests/Fixtures/smart-mask-fixture.json)。这些文件和照片未提交到仓库；`.mlmodelc` 为本机编译结果，不能用源文件摘要直接核对。

| 组件 | 本项目用途与固定来源 | 已核对的使用和分发条件 |
|---|---|---|
| SAM 2.1 Tiny，Core ML FP16 | 对象点选、框选与排除点；Apple 转换版本 `39ae0a8a83e5e6cd196e804bf7cccc5f8171f306`，编码器／提示编码器／解码器三部分 | Apple 模型卡标注 Apache-2.0，Meta 也明确将模型 checkpoints 置于 Apache-2.0。可按该许可使用、修改和分发，包括商业用途；保留适用声明。见[Apple 固定模型卡](https://huggingface.co/apple/coreml-sam2.1-tiny/blob/39ae0a8a83e5e6cd196e804bf7cccc5f8171f306/README.md)与[Meta 许可说明](https://github.com/facebookresearch/sam2#license)。 |
| SelfieMulticlass 256，TFLite float32 | 脸部皮肤、身体皮肤、头发和衣服的粗分类；SHA-256 `c6748b1253a99067ef71f7e26ca71096cd449baefa8f101900ea23016507e0e0` | Google 模型卡首页明确标注 Apache-2.0，可按该许可使用和分发，包括商业用途。依据是[模型卡](https://storage.googleapis.com/mediapipe-assets/Model%20Card%20Multiclass%20Segmentation.pdf)，而非开发者网页页脚对示例代码的许可；该 URL 未固定版本，核对时文件为 1,378,158 字节、SHA-256 `59372fce0666d4c75b3877540fa77f80ac4b2a0f75e914711417f85fc490a9e6`。 |
| FaceParsing，BiSeNet Core ML | 人脸区域内的皮肤、眉毛、眼睛和嘴唇细分；转换版本 `289c64b0db3acb100e22a650becb5e300be8b7f4` | 权重公开下载，转换作者明确声明按 MIT 再分发；上游训练数据另有非商业限制。权重的完整分发依据仍未确认；继续限于本地非商业研究，公开权重包或 App 分发前取得可核对授权或替换权重。见下节。 |
| Apple Vision | 逐人物实例和人脸框定位，使用系统 API；不复制独立权重 | 通过 macOS 自带框架调用，不随本仓库再分发 Apple 模型文件。见[人物实例请求](https://developer.apple.com/documentation/vision/vngeneratepersoninstancemaskrequest)和[人脸框请求](https://developer.apple.com/documentation/vision/vndetectfacerectanglesrequest)。整个人物入口已独立于 SAM、Selfie 和 FaceParsing。 |
| LiteRT 2.3.0 | Selfie 的官方 macOS C 运行时，属于程序依赖；[2.3.0 发布版本](https://github.com/google-ai-edge/LiteRT/releases/tag/v2.3.0)指向提交 `4352e261d3f1b3cda00345db5dbd75859d3bf0d3` | 根许可为 Apache-2.0，已与[上游固定版本](https://github.com/google-ai-edge/LiteRT/blob/4352e261d3f1b3cda00345db5dbd75859d3bf0d3/LICENSE)及[本地许可](../Packages/SmartMaskRuntime/LICENSE)核对一致；[依赖声明](references/litert-NOTICES.txt)保留固定 workspace 中的运行时及候选依赖许可，并随 App 复制。官方预编译包未提供完整构建清单，源码依赖清单不能当作完整二进制 SBOM。 |

Apache-2.0 的分发要求包括提供许可副本、保留适用声明和上游 NOTICE（如有），并对修改文件标明改动；完整条件以[许可正文](https://www.apache.org/licenses/LICENSE-2.0)为准。项目自有代码的 [AGPL-3.0-only](../LICENSE)不会替代模型许可，也不会补足未确认的权重分发权利。

Google 将 Selfie 用于交互式人物效果，说明其不适合要求像素级完美的蒙版；这项用途／质量说明与 Apache 许可分别记录。当前组合也不提供独立的虹膜、眼白、牙齿和胡须类别，细边缘及遮挡仍需人工检查。

### 人脸权重与训练数据

证据链为：

1. [Core ML 转换模型卡](https://huggingface.co/mickeyvanolst/face-parsing-coreml/blob/289c64b0db3acb100e22a650becb5e300be8b7f4/README.md)声明来自 `yakhyo/face-parsing`，并标注 MIT。
2. [上游训练说明](https://github.com/yakhyo/face-parsing#dataset)说明使用 CelebAMask-HQ；[原作者的模型归属说明](https://yakhyo.github.io/uniface/license-attribution/)将该 BiSeNet 权重标为跟随原项目许可，并单独列出明确禁止商用的其他权重。
3. [数据集协议](https://github.com/switchablenorms/CelebAMask-HQ#dataset-agreement)将数据集用于非商业研究，并限制图像及衍生数据的商业使用和数据集再分发。

转换作者明确将该权重按 MIT 再分发；训练数据集另有非商业条款，条款没有明确说明训练后的权重是否属于其“衍生数据”。不能因此断言权重自动变成非商业许可，也不能仅凭模型卡排除该条款对具体分发的影响。当前源码仓库不包含权重，Release 也会移除它；开源这些源码不等于分发该权重。

项目现阶段选择将这份权重限于本地非商业研究；[研究声明](references/smart-mask-research-NOTICE.txt)保留上游 MIT 全文与来源。若将来要随 App 公开分发，先核对具体用途下数据集条款的适用性，或换用授权依据明确的权重。

研究探针另用 LiteRT 2.3.2 的 Swift 源码 `c54e491a1ea07abdb931233eadf2f432db656997`；这与 App 使用的 2.3.0 预编译 C 运行时是两个独立版本。两个版本的根许可及上述 workspace 文件经逐字节比对一致。

## 开发者需要准备模型吗

普通构建与 `./scripts/check.sh` 不会调用智能蒙版研究准备脚本；缺少公开模型夹具的推理用例会按各自前置条件跳过。普通合成覆盖率、保存与渲染检查仍可运行，报告时分别说明实际结果。

[`prepare-smart-mask-validation.py`](../scripts/prepare-smart-mask-validation.py)是已有的整套研究实验准备入口，会获取三组权重、LiteRT 和固定公开验证照片，并编译原生探针及 Core ML 模型，输出在忽略的 `build/smart-mask-validation/`。它会获取授权尚待厘清的 FaceParsing，不是普通开发的前置步骤，也不是已建立授权的公开模型安装器。脚本固定版本／大小／摘要并拒绝不匹配文件，不代表同时完成分发许可核对。

Debug 复制脚本按下列能力读取已准备的资源；SAM 三部分须齐全，其他两项彼此独立：

```text
build/smart-mask-validation/models/
  SAM2_1TinyImageEncoderFLOAT16.mlmodelc/
  SAM2_1TinyPromptEncoderFLOAT16.mlmodelc/
  SAM2_1TinyMaskDecoderFLOAT16.mlmodelc/
  FaceParsing.mlmodelc/
  selfie_multiclass_256x256.tflite
```

程序只从 App 的 `Contents/Resources/SmartMaskModels` 读取模型，没有模型导入界面或外部模型目录设置。仅将文件放入研究目录而不重新构建，不会让已运行的 App 获得新模型。

只补精细面部的本地非商业研究资源时，可运行 `python3 scripts/prepare-smart-mask-validation.py --face-only`。它只获取固定摘要的人脸模型并用 Xcode 编译，不获取其他模型、运行时或照片；授权边界与整套研究准备相同。随后按正常 Debug 构建和固定体验 App 更新流程复制资源。

每个人物仅有一个检测人脸时自动精分；多个检测结果可在“面部定位与修正”中选择，也可手动画脸框。“恢复自动定位”清除当前人物的手动脸框并复用相应缓存。精细识别失败或脸框内无可用面部部位时，保留已生成的粗部位并允许重试；失败结果不进入部位缓存。取消、来源变化和无效裁图仍使请求失败。多人只有部分脸肤精分时标示“部分粗分”，不能把另一人物的精分状态当作全体成功。

对象选区先放大浮点输出再取 0 阈值，最长边不超过 1024；精细脸肤在粗皮肤可用时受其支持度约束，减少遮脸物被覆盖。头盔面罩可能无法自动定位人脸；贴脸手套仍会残留误选，发丝、轮圈、水线与水花仍有漏选／误选，需要手动修补。[遮挡与细边缘夹具](../Tests/Fixtures/smart-mask-edge-checks.json)仅给出公开样例的人工稀疏检查点，不是完整分割真值，也不代表总体准确率。

## 能力检查与剩余事项

当前程序按下表拆分；FaceParsing 权重的正式分发条件仍待解决：

| 功能 | 应独立检查的依赖 | 缺少时的处理 |
|---|---|---|
| 对象点选／框选 | SAM 三部分 | 仅禁用对象生成／重新识别，并提示此构建未包含对象选择。 |
| 整个人物 | 系统 Vision | 不被 FaceParsing 或 Selfie 缺失挡住；无检测结果时可改用已可用的对象或手动画笔。 |
| 人物粗部位 | 人物实例 + Selfie | 缺少 Selfie 时保留整个人物；粗脸部皮肤须明确标示精度，不承诺排除五官。 |
| 精细面部 | 人物实例 + FaceParsing；正式分发需先解决授权 | 仅影响对应部位与面部精修，可独立于粗部位；保留其他已可用选区。 |

按组件打包、完整 SAM 资源检查、所属旧资源移除及独立 LiteRT 许可复制已实现。模型有效性、来源摘要和声明仍须核对实际产物；完整传递依赖声明、模型正式安装／分发方案及人脸权重授权仍未完成。

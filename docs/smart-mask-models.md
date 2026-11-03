# 智能蒙版模型与可用状态

系统 Vision 的整个人物选择无需额外权重。对象与部位识别使用另行准备的本地研究模型。

## 现在能用什么

| 构建或资源状态 | 当前行为 |
|---|---|
| 默认 Debug，未准备研究模型 | 人物入口可检测并创建整个人物选区；对象禁用、部位注明未包含。没有自动下载。 |
| 没有模型，打开当前格式中已保存的智能蒙版 | 固定覆盖率仍可显示、调整和导出。人物可重新选择全身；对象重新识别需要 SAM，对应部位重新识别需要其模型。仍须满足原片访问、来源身份和几何校验。 |
| 只准备完整 SAM 三部分 | 对象点选／框选可用；系统整个人物仍可用，部位不启用。 |
| SAM + Selfie，没有 FaceParsing | 对象、整个人物和粗脸肤／身体皮肤／头发／衣服可用；粗脸肤明确标示“粗略”，精细五官注明未包含。 |
| 仅 Selfie，或仅 FaceParsing | 各自独立启用粗部位或可检测人脸内的精细部位；不要求 SAM。FaceParsing 的既有研究／分发限制不变。 |
| Debug 已准备完整研究模型 | 对象、整个人物、粗部位与精细面部可用；选区质量及人脸授权限制见下文。 |
| Release 产物 | 移除研究权重，保留系统人物与已保存选区；正式模型分发流程尚未建立。 |

画笔、线性／径向渐变、颜色／亮度范围蒙版及一般显影不依赖这些权重。已生成的选区以 UInt16 覆盖率栅格（LZFSE 压缩，单块不超过 1024×1024）随配方保存；重开、历史、快照、备份和冻结导出都不重跑模型，跨来源粘贴会跳过栅格失配的蒙版组。

增量构建只更新五个固定模型路径及声明，保留无关文件。SAM 缺任一部分时不复制整组，Selfie 与 FaceParsing 分开处理。运行时先检查资源组合和文件类型，模型加载失败时报告错误。无论是否包含权重，LiteRT 许可都会复制到 `Contents/Resources/SmartMaskRuntime-LICENSE.txt`。

## 模型来源与许可

固定文件大小和 SHA-256 见[模型清单](../Tests/Fixtures/smart-mask-fixture.json)。这些文件和照片未提交到仓库；`.mlmodelc` 为本机编译结果，不能用源文件摘要直接核对。

| 组件 | 本项目用途与固定来源 | 已核对的使用和分发条件 |
|---|---|---|
| SAM 2.1 Tiny，Core ML FP16 | 对象点选、框选与排除点；Apple 转换版本 `39ae0a8a83e5e6cd196e804bf7cccc5f8171f306`，编码器／提示编码器／解码器三部分 | Apple 模型卡标注 Apache-2.0，Meta 也明确将模型 checkpoints 置于 Apache-2.0。可按该许可使用、修改和分发，包括商业用途；保留适用声明。见[Apple 固定模型卡](https://huggingface.co/apple/coreml-sam2.1-tiny/blob/39ae0a8a83e5e6cd196e804bf7cccc5f8171f306/README.md)与[Meta 许可说明](https://github.com/facebookresearch/sam2#license)。 |
| SelfieMulticlass 256，TFLite float32 | 脸部皮肤、身体皮肤、头发和衣服的粗分类；SHA-256 `c6748b1253a99067ef71f7e26ca71096cd449baefa8f101900ea23016507e0e0` | Google 模型卡首页明确标注 Apache-2.0，可按该许可使用和分发，包括商业用途。依据是[模型卡](https://storage.googleapis.com/mediapipe-assets/Model%20Card%20Multiclass%20Segmentation.pdf)，而非开发者网页页脚对示例代码的许可；该 URL 未固定版本，核对时文件为 1,378,158 字节、SHA-256 `59372fce0666d4c75b3877540fa77f80ac4b2a0f75e914711417f85fc490a9e6`。 |
| FaceParsing，BiSeNet Core ML | 人脸区域内的皮肤、眉毛、眼睛和嘴唇细分；转换版本 `289c64b0db3acb100e22a650becb5e300be8b7f4` | 权重公开下载，转换作者明确声明按 MIT 再分发；上游训练数据另有非商业限制。权重的完整分发依据仍未确认；继续限于本地非商业研究，公开权重包或 App 分发前取得可核对授权或替换权重。见下节。 |
| Apple Vision | 逐人物实例和人脸框定位，使用系统 API；不复制独立权重 | 通过 macOS 自带框架调用，不随本仓库再分发 Apple 模型文件。见[人物实例请求](https://developer.apple.com/documentation/vision/vngeneratepersoninstancemaskrequest)和[人脸框请求](https://developer.apple.com/documentation/vision/vndetectfacerectanglesrequest)。整个人物入口已独立于 SAM、Selfie 和 FaceParsing。 |
| LiteRT 2.3.0 | Google 提供的 macOS C 运行时，用于 Selfie；[2.3.0 发布版本](https://github.com/google-ai-edge/LiteRT/releases/tag/v2.3.0)指向提交 `4352e261d3f1b3cda00345db5dbd75859d3bf0d3` | 根许可为 Apache-2.0，已与[上游固定版本](https://github.com/google-ai-edge/LiteRT/blob/4352e261d3f1b3cda00345db5dbd75859d3bf0d3/LICENSE)及[本地许可](../Packages/SmartMaskRuntime/LICENSE)核对一致；[依赖声明](references/litert-NOTICES.txt)保留固定 workspace 中的运行时及候选依赖许可，并随 App 复制。预编译包未提供完整构建清单，二进制依赖仍须核对。 |

Apache-2.0 的分发要求包括提供许可副本、保留适用声明和上游 NOTICE（如有），并对修改文件标明改动；完整条件以[许可正文](https://www.apache.org/licenses/LICENSE-2.0)为准。项目自有代码的 [AGPL-3.0-only](../LICENSE)不会替代模型许可，也不会补足未确认的权重分发权利。

Selfie 用于交互式人物效果，细边缘和遮挡仍需人工检查。当前模型组合不提供独立的虹膜、眼白、牙齿和胡须类别。

### 人脸权重与训练数据

来源与条款：

1. [Core ML 转换模型卡](https://huggingface.co/mickeyvanolst/face-parsing-coreml/blob/289c64b0db3acb100e22a650becb5e300be8b7f4/README.md)声明来自 `yakhyo/face-parsing`，并标注 MIT。
2. [上游训练说明](https://github.com/yakhyo/face-parsing#dataset)说明使用 CelebAMask-HQ；[原作者的模型归属说明](https://yakhyo.github.io/uniface/license-attribution/)将该 BiSeNet 权重标为跟随原项目许可，并单独列出明确禁止商用的其他权重。
3. [数据集协议](https://github.com/switchablenorms/CelebAMask-HQ#dataset-agreement)将数据集用于非商业研究，并限制图像及衍生数据的商业使用和数据集再分发。

转换作者按 MIT 再分发权重；训练数据集另有非商业条款，但未明确训练后的权重是否属于“衍生数据”。这些条款对权重在具体用途下的分发是否适用，仍须核对。

这份权重仅用于本地非商业研究；[研究声明](references/smart-mask-research-NOTICE.txt)保留上游 MIT 全文与来源。公开分发前需确认授权，或换用授权依据明确的权重。

研究探针使用 LiteRT 2.3.2 的 Swift 源码 `c54e491a1ea07abdb931233eadf2f432db656997`；App 使用 2.3.0 预编译 C 运行时，二者版本分别固定。

## 准备研究模型

普通开发无需准备模型。构建与 `./scripts/check.sh` 不会调用研究准备脚本；缺少公开模型夹具时，相关推理用例会跳过，合成覆盖率、保存与渲染检查仍可运行。

[`prepare-smart-mask-validation.py`](../scripts/prepare-smart-mask-validation.py)会下载三组权重、LiteRT 和固定公开验证照片，核对版本、大小与摘要，再编译原生探针及 Core ML 模型，输出到已忽略的 `build/smart-mask-validation/`。其中包含仅限本地非商业研究的 FaceParsing，使用前请阅读上面的授权限制。

Debug 复制脚本按下列能力读取已准备的资源；SAM 三部分须齐全，其他两项彼此独立：

```text
build/smart-mask-validation/models/
  SAM2_1TinyImageEncoderFLOAT16.mlmodelc/
  SAM2_1TinyPromptEncoderFLOAT16.mlmodelc/
  SAM2_1TinyMaskDecoderFLOAT16.mlmodelc/
  FaceParsing.mlmodelc/
  selfie_multiclass_256x256.tflite
```

程序从 App 的 `Contents/Resources/SmartMaskModels` 读取模型，没有模型导入界面或外部目录设置。准备资源后须重新构建，再打开更新后的 App。

只补精细面部的本地非商业研究资源时，可运行 `python3 scripts/prepare-smart-mask-validation.py --face-only`。它只获取固定摘要的人脸模型并用 Xcode 编译，不获取其他模型、运行时或照片；授权边界与整套研究准备相同。随后按正常 Debug 构建和固定体验 App 更新流程复制资源。

每个人物仅有一个检测人脸时自动精分；多个检测结果可在“面部定位与修正”中选择，也可手动画脸框。“恢复自动定位”清除当前人物的手动脸框并复用相应缓存。精细识别失败或脸框内无可用面部部位时，保留已生成的粗部位并允许重试；失败结果不进入部位缓存。取消、来源变化和无效裁图仍使请求失败。多人只有部分脸肤精分时标示“部分粗分”，不能把另一人物的精分状态当作全体成功。

对象选区先放大浮点输出再取 0 阈值，最长边不超过 1024；精细脸肤在粗皮肤可用时受其支持度约束，减少遮脸物被覆盖。头盔面罩可能无法自动定位人脸；贴脸手套仍会残留误选，发丝、轮圈、水线与水花仍有漏选／误选，需要手动修补。[遮挡与细边缘夹具](../Tests/Fixtures/smart-mask-edge-checks.json)记录了公开样例的人工稀疏检查点，未提供完整分割真值或总体准确率。

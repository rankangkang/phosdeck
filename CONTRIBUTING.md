# 贡献与反馈

欢迎报告问题、改进文档或提交代码。当前维护的主线是原生 macOS App；源码构建见 [README](README.md#快速上手)，使用流程见[上手指南](docs/getting-started.md)。较大的功能或方向变更，建议先说明要解决的问题和预期行为，便于讨论范围。

## 反馈问题

仓库可访问且启用 Issues 时，可以在 [Issues](https://github.com/rankangkang/phosdeck/issues) 提交问题。请尽量提供：

```text
版本或提交号：
macOS 版本、芯片架构；构建问题另附 Xcode 版本：
操作步骤（尽可能使用合成素材）：
预期结果：
实际结果、出现频率和相关错误提示：
已尝试的方法，以及是否使用了社区语言包或可选模型：
```

macOS 版本和芯片信息可在“关于本机”查看；源码检出可用 `git rev-parse --short HEAD` 获取提交号，构建问题可用 `xcodebuild -version` 查看 Xcode 版本。

提交前检查截图、录屏、日志和文字中的用户名、邮箱、令牌、绝对路径、照片文件名、位置、人物及相机元数据。**不要直接上传私人原片、`.omlrcat`、SQLite 图库备份、JSON 管理清单、访问书签或未经检查的日志。** 这些文件可能包含个人信息，即使没有附带照片也不适合公开。

优先用自己生成的合成图片复现；如果必须使用其他素材，先确认有权分享，检查画面及元数据中的个人信息，并说明来源及许可。无法安全分享素材时，请说明限制，不必为反馈问题公开私人数据。

## 本地开发与检查

代码主要位于 `Sources/`，回归检查位于 `Tests/`。请遵循仓库的[开发约定](AGENTS.md)，尤其是照片和图库保护、Swift 文件登记、文件写入及性能约束。测试使用合成数据，或使用仓库明确允许且已授权的公开样片；不要编写自动搜索私人图库或原片的测试。`Samples/` 被 Git 忽略，不要将整个目录视为可提交素材。

在仓库根目录运行完整检查：

```sh
./scripts/check.sh
```

完整检查会先运行文档检查；只改文档时可单独运行 `python3 scripts/check-docs.py`。

针对受影响的测试类，也可以先运行定向检查，例如：

```sh
xcodebuild -project Phosdeck.xcodeproj -scheme Phosdeck -derivedDataPath build -destination 'platform=macOS' -only-testing:PhosdeckTests/FoundationTests test
```

测试准备阶段需要 `python3` 标准库，不需要额外 Python 包。没有准备公开 RAW 或智能蒙版素材、没有相应授权环境时，部分检查会跳过；请报告本次实际执行、跳过和失败的结果，不要把跳过算作通过。涉及界面交互的修改还需要用允许的素材检查实际窗口和相关操作。

普通开发无需下载智能蒙版权重。研究准备脚本会获取含人脸权重在内的整套实验资源，其授权限制、模型版本和缺失时的行为见[智能蒙版说明](docs/smart-mask-models.md)。

新增 Swift 文件时，要同步登记到 `Phosdeck.xcodeproj/project.pbxproj` 和 `project.yml`。新增依赖前核对许可和随包声明；仓库不引入 GPL 依赖。项目自身的许可及第三方声明见 [README 许可说明](README.md#许可)。

## 提交变更

提交前检查差异和 `git diff --check`，确保没有混入私人素材、构建产物、本地签名配置或无关改动。提交信息使用英文 [Conventional Commits](AGENTS.md#提交约定)，例如 `docs: clarify catalog backup` 或 `fix(import): preserve selected photos`。

提交 Pull Request 时，请描述要解决的问题、主要变化和实际验证结果；有失败或跳过也如实说明。界面变化可附经过检查的合成数据截图。社区语言包的制作与维护方式见[国际化说明](docs/localization.md)。

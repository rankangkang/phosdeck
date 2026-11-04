# 贡献与反馈

[English](CONTRIBUTING.md) · [简体中文](CONTRIBUTING.zh.md)

可以通过报告问题、修改文档或提交代码参与项目。应用面向原生 macOS，静态产品官网位于 `site/`。App 源码构建见 [README](README.zh.md#快速上手)，使用流程见[上手指南](docs/getting-started.md)。较大的功能或方向变更，建议先在 Issue 中说明问题和预期行为，讨论后再动手。

## 反馈问题

在 [Issues](https://github.com/rankangkang/phosdeck/issues) 提交问题时，请尽量提供：

```text
版本或提交号：
macOS 版本、芯片架构；构建问题另附 Xcode 版本：
操作步骤（尽可能使用合成素材）：
预期结果：
实际结果、出现频率和相关错误提示：
已尝试的方法，以及是否使用了社区语言包或可选模型：
```

macOS 版本和芯片信息可在“关于本机”查看；源码检出可用 `git rev-parse --short HEAD` 获取提交号，构建问题可用 `xcodebuild -version` 查看 Xcode 版本。

提交前检查截图、录屏和日志中的用户名、邮箱、令牌、绝对路径、照片文件名及元数据。不要上传私人原片、`.phoscat`／`.omlcat`／`.omlrcat` 图库、SQLite 备份、JSON 管理清单或访问书签；这些文件即使不含照片，也可能泄露个人信息。

优先用自己生成的合成图片复现；如果必须使用其他素材，先确认有权分享，检查画面及元数据中的个人信息，并说明来源及许可。无法安全分享素材时，请说明限制，不必为反馈问题公开私人数据。

## 本地开发与检查

代码主要位于 `Sources/`，回归检查位于 `Tests/`。请遵循仓库的[开发约定](AGENTS.md)，尤其是照片和图库保护、Swift 文件登记、文件写入及性能约束。测试使用合成数据，或使用仓库明确允许且已授权的公开样片；不要编写自动搜索私人图库或原片的测试。`Samples/` 被 Git 忽略，不要将整个目录视为可提交素材。

`site/` 以外的 JPG、JPEG、PNG、WebP、GIF 和 TIFF 资源统一由 Git LFS 跟踪，配置方法见 [README](README.zh.md#快速上手)。官网资源为适配 GitHub Pages 保留在普通 Git 中；LFS 不会改变样片和图库的忽略规则。

在仓库根目录运行完整检查：

```sh
./scripts/check.sh
```

完整检查会先运行文档检查。只改文档时，运行：

```sh
python3 scripts/check-docs.py
git diff --check
```

README 和贡献指南各有中英文版本，修改公共说明时请同步两种版本。

针对受影响的测试类，也可以先运行定向检查，例如：

```sh
xcodebuild -project Phosdeck.xcodeproj -scheme Phosdeck -derivedDataPath build -destination 'platform=macOS' -only-testing:PhosdeckTests/FoundationTests test
```

测试准备阶段使用 `python3` 标准库，不需要额外 Python 包。缺少公开 RAW、智能蒙版素材或相应授权环境时，部分检查会跳过；请分别报告本次执行、跳过和失败的结果。界面交互修改还需要用允许的素材检查实际窗口和操作。

普通开发无需下载智能蒙版权重。研究准备脚本会获取含人脸权重在内的整套实验资源，其授权限制、模型版本和缺失时的行为见[智能蒙版说明](docs/smart-mask-models.md)。

新增 Swift 文件时，要同步登记到 `Phosdeck.xcodeproj/project.pbxproj` 和 `project.yml`。新增依赖前核对许可和随包声明；仓库不引入 GPL 依赖。项目自身的许可及第三方声明见 [README 许可说明](README.zh.md#许可)。

## 持续集成

GitHub Actions 使用只读仓库权限执行以下检查；Pages 部署单独授予发布权限：

- `Check repository`：PR、`master` 推送及手动运行时检查文档、差异空白、Python／Shell 语法和工作流语法。
- `Check native app`：原生源码、测试、工程及相关资源变更时，用 macOS 26 和 Xcode 26.6 构建全部测试代码并运行选定的核心回归；Actions 手动运行时可勾选 `full_suite` 执行完整 XCTest。CI 的临时签名测试关闭 hardened runtime；正式发行签名不受此设置影响。
- `Check website and deploy GitHub Pages`：相关 PR 和手动运行执行官网检查、构建及静态测试；自动部署条件见[官网开发](#官网开发)。
- `Verify release package`：Release 发布后自动复核，也可手动输入已有标签（如 `v0.1.0-alpha.1`）。下载 ZIP 与 SHA-256 文件，检查版本、双架构、签名、公证票据、Gatekeeper 和随包内容；使用当前 `master` 上的验证规则。

原生 CI 不下载 RAW 样片或研究模型；核心套件不等于完整覆盖，完整套件的已知失败与缺少资源造成的跳过须分别查看。XCTest 结果包、日志及统计保留 7 天。[已知问题](docs/STATUS.md#已知问题)中的焦点与沙箱复制失败仍需修复。`Tests/test_calibration_paths.py` 使用合成数据，单独在 macOS CI 执行。签名、公证、打包及 GitHub Release 发布继续在本地执行，CI 不持有 Apple 凭据，也不创建或修改 Release。

## 本地预发布准备（维护者）

当前预发布标识为 `0.1.0-alpha.1`。macOS 的 `CFBundleShortVersionString` 使用纯数字 `0.1.0`，`CFBundleVersion` 为构建号 `1`；完整标识另存于 `PhosdeckReleaseVersion`，用于发行包名称。系统“关于”窗口显示数字版本和构建号。准备下一次分发时，在 `project.yml` 和 `Phosdeck.xcodeproj/project.pbxproj` 同步更新版本与递增的构建号；改变预发布阶段时，同时更新 `project.yml`、`Sources/App/Info.plist` 和版本回归测试中的标识。

先运行适用的检查，记录失败和跳过；核对发布说明、支持的 macOS 与芯片、图库兼容限制、[模型内容及许可](docs/smart-mask-models.md)和[已知分发问题](docs/STATUS.md)。Release 不包含研究模型。打包和签名不会代替真实机器上的体验与安装验证。

使用与 Developer ID 对应的 Apple 开发者团队，在钥匙串或 Xcode 中准备好 `Developer ID Application` 证书及私钥，并在 Xcode 登录对应账号。不要把证书、私钥或凭据放入仓库。以下命令在仓库根目录和同一个终端中运行，归档放入新的本地目录：

```sh
mkdir -p build
RELEASE_DIR="$(mktemp -d "$PWD/build/release.XXXXXXXX")"
xcodebuild -project Phosdeck.xcodeproj -scheme Phosdeck -configuration Release \
  -derivedDataPath build -destination 'generic/platform=macOS' \
  -archivePath "$RELEASE_DIR/Phosdeck.xcarchive" archive
```

归档使用临时签名。将 `TEAM_ID` 改成证书所属团队的十位 ID，再导出 Developer ID 签名的 App；无需更改工程或通过全局构建设置为依赖签名：

```sh
TEAM_ID="YOUR_TEAM_ID"
plutil -create xml1 "$RELEASE_DIR/ExportOptions.plist"
plutil -insert method -string developer-id "$RELEASE_DIR/ExportOptions.plist"
plutil -insert destination -string export "$RELEASE_DIR/ExportOptions.plist"
plutil -insert signingStyle -string manual "$RELEASE_DIR/ExportOptions.plist"
plutil -insert signingCertificate -string 'Developer ID Application' "$RELEASE_DIR/ExportOptions.plist"
plutil -insert teamID -string "$TEAM_ID" "$RELEASE_DIR/ExportOptions.plist"
xcodebuild -exportArchive -archivePath "$RELEASE_DIR/Phosdeck.xcarchive" \
  -exportPath "$RELEASE_DIR/export" -exportOptionsPlist "$RELEASE_DIR/ExportOptions.plist"
```

公证前运行 `xcrun notarytool store-credentials PhosdeckNotary`，按交互提示将凭据存入钥匙串；不要把凭据写入仓库或命令历史。以下操作会把已签名的应用二进制提交给 Apple 检查，不会创建公开下载。确认提交状态为 `Accepted` 后再继续：

```sh
ditto -c -k --sequesterRsrc --keepParent "$RELEASE_DIR/export/Phosdeck.app" "$RELEASE_DIR/notary.zip"
xcrun notarytool submit "$RELEASE_DIR/notary.zip" --keychain-profile PhosdeckNotary --wait
xcrun stapler staple "$RELEASE_DIR/export/Phosdeck.app"
xcrun stapler validate "$RELEASE_DIR/export/Phosdeck.app"
```

对导出的 App 运行：

```sh
./scripts/package-release.sh "$RELEASE_DIR/export/Phosdeck.app"
```

脚本要求带时间戳、启用 hardened runtime 的 Developer ID 签名及已附加的公证票据，通过 `scripts/verify-release.sh` 检查 Gatekeeper、嵌套代码、双架构、沙箱权限、研究模型和随包声明，并在独立的 `build/releases/` 目录生成 ZIP、解包回读和 SHA-256。失败时保留中间文件，不覆盖既有包，也不会上传。实际分发前，还需在允许使用的素材和独立测试环境中验证从下载、安装、启动到导入／编辑／导出的流程，并核对公开分发所需的许可；本地检查或公证结果不等于用户验收。

## 官网开发

中英双语的 Astro 官网复用 App 的设计 Token 和已确认的品牌资源。仅网站开发需要 Node.js 22.23.4 或更新版本、npm 9.6.5 或更新版本，原生 App 构建不依赖它们。在仓库根目录运行：

```sh
npm --prefix site ci
npm --prefix site run dev
```

英文预览为 `http://127.0.0.1:4321/phosdeck/`，中文为 `http://127.0.0.1:4321/phosdeck/zh/`。未保存网站主题选择时，两者都默认石墨。`/phosdeck/` 前缀与计划使用的 GitHub Pages 项目路径一致。停止本地服务可运行 `npm --prefix site run stop`。

提交网站改动前运行：

```sh
npm --prefix site run check
npm --prefix site run build
npm --prefix site test
python3 scripts/check-docs.py
git diff --check
```

实窗核对桌面与手机布局，覆盖中英双语和两种主题。仅当推送到 `master` 且本次变更包含 `site/**` 时，GitHub Actions 才重新部署到 [GitHub Pages](https://rankangkang.github.io/phosdeck/zh/)。PR 和手动运行只做检查。官网引用 `design/` 的 Token 与字标；单独修改这些共享资源不会触发部署，会随下一次 `site/` 变更上线。

网站构建使用 Astro、`@astrojs/check`（MIT）、TypeScript（Apache-2.0），以及 Astro 的可选图像工具 sharp（Apache-2.0）与 libvips（LGPL-3.0-or-later）；静态产物不包含这些构建工具或原生库，安装包保留各自的许可声明。

## 提交变更

提交前检查差异并运行 `git diff --check`，确保没有混入私人素材、构建产物、本地签名配置或无关改动。提交信息使用英文 [Conventional Commits](AGENTS.md#提交约定)，例如 `docs: clarify catalog backup` 或 `fix(import): preserve selected photos`。

提交 Pull Request 时，请描述要解决的问题、主要变化和实际验证结果；有失败或跳过也如实说明。界面变化可附经过检查的合成数据截图。社区语言包的制作与维护方式见[国际化说明](docs/localization.md)。

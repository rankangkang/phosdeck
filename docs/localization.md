# 原生 App 国际化与社区语言包

官方维护英文 `en` 和简体中文 `zh-Hans`。App 默认使用 macOS 为当前 App 选择的语言；无法匹配时使用英文。在“系统设置 → 通用 → 语言与地区 → 应用程序”中，可以单独指定 App 语言。语言变更在重新打开 App 后生效。

主词表是 [`Localizable.xcstrings`](../Sources/App/Localizable.xcstrings)，文件类型说明使用 [`InfoPlist.xcstrings`](../Sources/App/InfoPlist.xcstrings)。README 不属于本地化范围。

## App 文案与数据

App 自有文案经 [`L10n.text`](../Sources/App/Localization.swift) 查询。启动时固定资源与语言，菜单、状态、错误和控件共用同一环境；不会在滑块或画布刷新时扫描语言包。

```swift
Text(L10n.text("app.importPhotos", defaultValue: "Import Photos…"))
```

新增文案需要在主词表中添加稳定键及中英译文，保持参数类型一致。`defaultValue` 使用英文。词表条目采用手动维护状态；不要依赖 Xcode 自动发现自定义包装函数。数量使用 String Catalog 的原生复数规则。英文、简体中文和社区语言分别使用自己的格式化语言；社区缺词时，资源查找与复数规则一起回退到英文。

`String` 的 `locale` 参数不能独自保证切换资源查找语言，因此官方文案显式选择对应 `.lproj`。Xcode 自动生成的 `LocalizedStringResource` 绑定原资源包，不能在创建后直接换成社区包。

文件名、路径、用户填写的集合名、关键词、题注、预设名和快照名作为原文显示。既有历史和日志保留保存时的文字，新建的 App 消息使用当前语言。数据库字段、JSON 键、枚举存储值和照片处理标识不翻译，不修改图库格式或原片。

## 用户安装与切换

在 App 的“设置 → 外观 → 语言”中导入 `.bundle`，选择一个社区翻译或“使用官方语言”。导入成功后选中该包，下次打开 App 生效。用户无需安装 Xcode。

语言包复制到 App 沙箱的 Application Support 下 `OhMyLRC/LanguagePacks/<UUID>.bundle`，不修改 App 程序包，也不依赖下载目录的长期授权。更新使用新 UUID 目录；当前进程继续使用原来的资源。移除正在使用的包时，先恢复官方语言偏好，下一次启动清理旧包。

损坏、缺失或不支持的包不会阻止 App 启动；App 恢复官方语言，在设置中显示说明。安装失败时已有包和已选偏好保留。社区作者自行维护、更新和分发译文；官方维护加载器、协议和模板。

## 制作语言包

1. 复制官方 `Localizable.xcstrings` 到自己的仓库，用 Xcode 打开。
2. 添加目标语言，例如 `ru`、`ja` 或 `zh-Hant`，保留英文源语言、键名、参数类型和注释。
3. 翻译需要提供的条目，并将其状态标记为已翻译。数量词条在 Xcode 中使用目标语言的复数分支。
4. 使用本仓库的打包脚本。作者需要 Xcode 自带的 `xcstringstool`，没有额外 Python 包或运行时依赖：

```sh
python3 scripts/make-language-pack.py /path/to/Russian.xcstrings \
  --language ru \
  --name 'Русский' \
  --author 'Community author' \
  --identifier org.example.phosdeck.russian \
  --version 1 \
  --output /path/to/Russian.bundle
```

输出路径必须不存在。脚本只编译完整、标为已翻译的目标语言条目，避免把编译器生成的未译键名占位误算成译文。没有提供的条目由 App 使用英文。脚本使用同卷临时目录、刷盘和 Darwin 无覆盖发布；已有包不会被覆盖。

```text
Russian.bundle/
  Contents/
    Info.plist
    Resources/
      ru.lproj/
        Localizable.strings
        Localizable.stringsdict
```

`Info.plist` 中的约定字段：

| 字段 | 内容 |
|---|---|
| `OMLRCFormatVersion` | 整数 `1`，只接受当前格式 |
| `OMLRCPackIdentifier` | 作者维护的稳定包标识 |
| `OMLRCLanguage` | BCP 47 语言代码，与 `.lproj` 目录一致 |
| `OMLRCName` | 语言显示名 |
| `OMLRCAuthor` | 作者显示名 |
| `CFBundleVersion` | 作者维护的包版本 |
| `CFBundlePackageType` | `BNDL` |
| `CFBundleDevelopmentRegion` | 目标语言代码 |
| `CFBundleIdentifier` | bundle 标识；安装时重建为 App 所有的独立标识 |

名称、作者、标识和版本限 1–200 个字符，不含控制字符。单个资源文件最多 8 MiB。加载器检查普通文件和目录、参数位置和类型、复数规则；普通词条和数字复数是本版支持的格式。不要使用其他平台变体、自定义格式执行器、动态库或脚本。官方英文和简体中文不能被社区包替换。

资源中的 `%%` 表示带参数格式内的百分号；`%@`、`%lld` 等参数类型必须与英文词条一致。可以使用 `%1$@` 等位置参数调整语序，不能把整数参数换成字符串参数，或加入新的参数。

App 仅安装经过校验的文字表及重建的元信息，不加载可执行代码。未知键、空译文和“键名等于译文”的未译占位不启用。不支持的旧包格式直接拒绝，不做迁移。

## 边界与验证

社区包只提供 App 自有文案。macOS 文件选择框、系统生成的菜单及文件类型说明使用系统的语言机制；外部包不登记到系统的单 App 语言列表。照片坐标、方向、像素、色彩与透明度规则不受界面语言影响。

测试入口：

```sh
xcodebuild -project Phosdeck.xcodeproj -scheme Phosdeck -derivedDataPath build \
  -destination 'platform=macOS' -only-testing:PhosdeckTests/LocalizationTests test
./scripts/check.sh
```

既有界面与错误断言测试固定使用简体中文，`LocalizationTests` 显式检查中英和合成俄语资源，避免测试读取用户安装的语言包。实际窗口另行检查中英、米白／石墨主题，以及导入、重启启用、缺词回退和移除闭环。工程检查与用户体验验收分别记录。

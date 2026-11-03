# README 视觉素材

首页由 GitHub 支持的 Markdown、少量 HTML、SVG 封面、信息徽章和真实界面截图组成，没有新增应用依赖或构建工具链。

## 封面

- [米白](hero-ivory.svg)／[石墨](hero-graphite.svg)：各约 6.5 KB 的静态 SVG，均为 1200 × 340；没有脚本、外部字体、远程图片或动画。
- 字标直接复用[Phosdeck Logo](../../../design/logo/README.md)中的 `logo-wordmark-ivory.svg`／`logo-wordmark-graphite.svg` 路径；右侧图标复用 `Sources/App/AppIcon.icon/Assets/` 中对应的已确认几何。
- 封面机身、文字、分隔线和状态灯配色来自[设计 Token v3](../../../design/darkroom_instrument_tokens_v3.json)。
- 首页通过 `<picture>` 和 `prefers-color-scheme` 选择主题，并保留米白版作为回退。后续调整直接编辑 SVG；不需要部署网站或图片生成服务。

在仓库根目录使用本机已有的 `rsvg-convert` 可检查光栅化结果，例如：

```sh
rsvg-convert --width 1200 --output /tmp/phosdeck-hero-ivory.png docs/assets/readme/hero-ivory.svg
```

## 截图与徽章

首页直接引用 2026-11-03 的[米白实窗](../../../design/darkroom_workspace_ivory.jpg)和[石墨实窗](../../../design/darkroom_workspace_graphite.jpg)，原文件未裁切、拼接或修改。两图来自既有合成 UnratedReview 目录，画布是合成渐变图。截图展示当时界面，首页标明日期，不能当成最新产品逐项验收证据。

徽章使用 [Shields.io 静态徽章](https://shields.io/badges)，仅显示 macOS 版本、SwiftUI／Metal、开发预览阶段和 `AGPL-3.0-only`。没有添加 CI 通过、覆盖率、性能或下载量徽章。徽章图片由外部服务提供，离线时依赖图片的替代文字；应用运行和本地 SVG 封面不依赖该服务。

GitHub 的主题图片用法见[官方文档](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/quickstart-for-writing-on-github)。

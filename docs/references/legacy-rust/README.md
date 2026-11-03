# 已移除 Rust 实验的第三方声明

2026-10-30，旧跨平台 Rust 引擎、依赖清单、工具链配置与对应 CI 已从当前工作树移除。这里仅保留其历史版权与许可声明，不表示当前原生 App 依赖这些 Rust 组件，也不参与原生构建或随包资源复制。

三份声明由原 `engine/native/` 原样移入，内容逐字节保留：

- [SHA-2 及相关依赖](sha2-NOTICES.txt)。
- [rusqlite／SQLite 及相关依赖](sqlite-NOTICES.txt)。
- [Unicode normalization 及相关依赖](unicode-NOTICES.txt)。

声明中提及的 `engine/Cargo.lock` 等路径用于标识旧依赖来源，不属于当前构建。

# Aphros

一个自用的词典 App（iOS + macOS）。读本地的 MDict（`.mdx` / `.mdd`）词典，
只做四件事：查词、朗读单词发音、收藏、深色模式。macOS 版另有两样：
**⌥D 划词翻译**（任意 App 里划中文本弹浮窗，见 ADR 0013）和菜单栏常驻。

**纯自用，不上架。** 最低 iOS 26 / macOS 26。

## 快速开始

```bash
make test       # 解析层测试，不需要 Xcode，秒级
make build      # 编译 iOS App（模拟器，不需要签名）
make run        # 装到模拟器并启动
make build-mac  # 编译 macOS App
make run-mac    # 编译并启动 macOS App（词典放 ~/Documents/Dict）
make device     # 装到连着线的 iPhone（Release，UDID=<设备UDID>）
make dmg        # 出 macOS 分发 DMG（Release + Developer ID 签名 + 公证）
```

`Dict.xcodeproj` 由 `project.yml` 生成，**不在版本库里**——改工程配置改
`project.yml`，然后 `make project`。这样每一处改动都体现在 YAML 的 diff 里，
不会有 pbxproj 那种没法 review 的冲突。

## 词典数据

`dicts/` 下共 3.3 GB，**不在版本库里**（见 `.gitignore`）。App 只挂载
Documents 下找到的第一部 `.mdx`（iOS 是沙盒 Documents，用「文件」App 拖入；
macOS 是 `~/Documents/Dict`）：

| 目录 | 词典 | mdx | mdd | 词头 | 中文词头 |
|---|---|---|---|---|---|
| `oalecd_10_refined/` | 牛津高阶英汉双解 第10版增强 | 112 MB | 1.9 GB | 463,860 | 183,858 |
| `Oxford Advanced/` | 牛津高阶英汉双解 第8版 | 19 MB | 316 MB | 109,473 | 0 |
| `cecd_2024/` | 剑桥英汉双解 2024 | 33 MB | 1.1 GB | 85,867 | 0 |

**实际只用第 10 版**（ADR 0007：第 8 版和剑桥都砍掉，2026-08-25 取消备用）
——只有它带中文词头，输入「上当」能直接查到。另两部留在磁盘只作解析层
测试的对照语料。

没有 `dicts/` 时依赖它的测试会自动跳过，其余照常。

## 结构

```
Sources/MDictKit/       L1 解析：头部、RIPEMD-128、zlib 区块、键索引、记录索引
Sources/DictIndex/      L2 索引：常驻内存的词头查询表 + 落盘缓存（ADR 0008）、
                        前缀/子串搜索、划词归一化、@@@LINK 重定向、mdd 资源库
Sources/DictRender/     L3 渲染：词典 HTML → 可喂进 WebView 的完整文档
App/Shared/             双端共用壳层：store、历史、音频、颜色、WebView 核心
App/iOS/                iPhone 界面：单栏、玻璃搜索条
App/macOS/              Mac 界面：双栏、划词浮窗、菜单栏常驻（ADR 0011–0013）
App/Resources/*.css     词条正文样式表（完全替换词典自带的）
Tests/                  golden test，期望值由参考实现实测生成
```

引擎三层不许 import UIKit，`App/Shared` 双平台可编译——平台差异走
`#if os(...)`，专属代码放 `App/iOS` / `App/macOS`。

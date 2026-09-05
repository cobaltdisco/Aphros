# Aphros

一个自用的词典 App（iOS + macOS）。读本地的 MDict（`.mdx` / `.mdd`）词典，
只做四件事：查词、朗读单词发音、收藏、深色模式。macOS 版另有三样：
**⌥D 划词翻译**（任意 App 里划中文本，弹浮窗出释义，零第三方依赖）、
菜单栏常驻（关窗不退出，热键照常）、历史记录选中后 ⌫ 直接删。

**纯自用，不上架。** 最低 iOS 26 / macOS 26。

## 快速开始

```bash
make test       # 引擎 + DictCore 测试，不需要 Xcode，80 个用例约 3 秒
make build      # 编译 iOS App（模拟器，不需要签名）
make run        # 装到模拟器并启动
make build-mac  # 编译 macOS App
make run-mac    # 编译并启动 macOS App（词典放 ~/Documents/Dict）
make device     # 装到连着线的 iPhone（Release，UDID=<设备UDID>）
make dmg        # 出 macOS 分发 DMG（Release + Developer ID 签名 + 公证）
make help       # 列出全部命令
```

`Dict.xcodeproj` 由 `project.yml` 生成，**不在版本库里**——改工程配置改
`project.yml`，然后 `make project`。这样每一处改动都体现在 YAML 的 diff 里，
不会有 pbxproj 那种没法 review 的冲突。

## 词典数据

App **只用一部词典**：`oalecd_10_refined/`（牛津高阶英汉双解 第 10 版增强，
mdx 112 MB + mdd 1.9 GB，词头 463,860，其中中文词头 183,858——输入「上当」
能直接查到）。App 挂载 Documents 下找到的第一部 `.mdx`：iOS 是沙盒
Documents，用「文件」App 拖入；macOS 是 `~/Documents/Dict`。

`dicts/` 整个目录（3.3 GB）**不在版本库里**（见 `.gitignore`）。里面另有
两部（牛津第 8 版、剑桥 2024）App 不读，只作解析层测试的对照语料——它们的
头部写法、键序乱序和第 10 版不同，拿来保证解析器不是只认一部词典。
没有 `dicts/` 时依赖它的测试会自动跳过，其余照常。

## 结构

```
Sources/MDictKit/       L1 解析：头部、RIPEMD-128、zlib 区块、键索引、记录索引
Sources/DictIndex/      L2 索引：常驻内存的词头查询表 + 落盘缓存、
                        前缀/子串搜索、划词归一化、@@@LINK 重定向、mdd 资源库
Sources/DictRender/     L3 渲染：词典 HTML → 可喂进 WebView 的完整文档、桥条目识别
Sources/DictCore/       L4 门面：DictionaryStore（查词策略唯一入口）、历史、
                        音频、落盘路径——壳层只看得见这一层
App/Shared/             双端共用壳层：WebView 核心、资源 scheme、颜色
App/iOS/                iPhone 界面：单栏、玻璃搜索条
App/macOS/              Mac 界面：双栏、划词取词与浮窗、全局热键、菜单栏常驻
App/Resources/*.css     词条正文样式表（完全替换词典自带的）
Tests/                  golden test，期望值由参考实现实测生成
```

依赖只能向下：`MDictKit → DictIndex → DictRender → DictCore → App/Shared →
App/iOS · App/macOS`。前四层不许 import 任何 UI 框架，所以整条链能在 Mac 上
`swift test`；三个 `App/` 目录只 import `DictCore`，视图要什么就给
`DictionaryStore` 加方法。`App/Shared` 双平台可编译——平台差异走
`#if os(...)`，专属代码放 `App/iOS` / `App/macOS`。

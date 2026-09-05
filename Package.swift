// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DictEngine",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "MDictKit", targets: ["MDictKit"]),
        .library(name: "DictIndex", targets: ["DictIndex"]),
        .library(name: "DictRender", targets: ["DictRender"]),
        .library(name: "DictCore", targets: ["DictCore"]),
    ],
    targets: [
        // L1 解析层：纯 Foundation，无 UIKit 依赖，可在 macOS 上跑 `swift test`
        .target(name: "MDictKit"),
        .testTarget(
            name: "MDictKitTests",
            dependencies: ["MDictKit", "DictIndex", "DictRender", "DictCore"],
            resources: [.copy("Fixtures/goldens.json")]
        ),
        // L2 索引层
        .target(name: "DictIndex", dependencies: ["MDictKit"]),
        // L3 渲染层：纯字符串变换，不碰 WebKit，可在 macOS 上测
        .target(name: "DictRender"),
        // L4 应用核心：store（查词策略、历史/收藏）、音频、落盘路径。
        // 是 App 层里**不碰 UI 框架**的那一半（2026-08-31 从 App/Shared 抽出）：
        // 允许 AVFoundation，不许 SwiftUI/UIKit/AppKit/WebKit——抽出来就是为了
        // 让它能进 `swift test`，之前 App 层零测试、iOS 漂了一轮没人红。
        // 默认 MainActor 隔离和 App target 的设置对齐（project.yml 的
        // SWIFT_DEFAULT_ACTOR_ISOLATION），代码搬过来不用改隔离。
        .target(
            name: "DictCore",
            dependencies: ["MDictKit", "DictIndex", "DictRender"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)

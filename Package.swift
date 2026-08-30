// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DictEngine",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "MDictKit", targets: ["MDictKit"]),
        .library(name: "DictIndex", targets: ["DictIndex"]),
        .library(name: "DictRender", targets: ["DictRender"]),
    ],
    targets: [
        // L1 解析层：纯 Foundation，无 UIKit 依赖，可在 macOS 上跑 `swift test`
        .target(name: "MDictKit"),
        .testTarget(
            name: "MDictKitTests",
            dependencies: ["MDictKit", "DictIndex", "DictRender"],
            resources: [.copy("Fixtures/goldens.json")]
        ),
        // L2 索引层
        .target(name: "DictIndex", dependencies: ["MDictKit"]),
        // L3 渲染层：纯字符串变换，不碰 WebKit，可在 macOS 上测
        .target(name: "DictRender"),
    ]
)

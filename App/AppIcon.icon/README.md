# 图标源

米色纸面上一个「a」。来源是设计包里的 `dictionary-icon-layer-{background,foreground}.svg`
（no-rim 那版，字形不描边）。

## 和设计包不一样的两处，都是 actool 逼的

- **背景渐变是 2 色不是 3 色。** 源文件是 `#F4F1E9 → #E6E0D4 → #C5BCAC`，
  但 `icon.json` 的 `linear-gradient` 给三个色 actool 直接崩
  （`attempt to insert nil object from objects[0]`），二分出来的。去掉中间那个，
  中段最多差 10 个灰阶。
- **纸面没做成图层。** 做成图层能逐位还原 3 色渐变（试过，中心正好 `#E6E0D4`），
  但 Clear / Tinted 模式剥的是背景**填充**，图层不剥——一整张不透明的纸会把
  Clear 变成实心方块。

## 另外两条实测

- `orientation` 字段 actool **不认**，渐变方向由两个颜色的**顺序**决定。
- `groups` 里**列在前面的画在上面**。

## Dark / Tinted 下字形的颜色覆盖

SVG 里烘死的深色渐变只适合浅色纸面。Dark 模式系统会把背景填充自动换成深底，
字形却原样保留——深上加深几乎看不见；Tinted 模式拿字形**亮度**当着色模板，
深色字形着完色照样暗。

解法是给字形图层加 `fill-specializations`（写法从 IconComposerFoundation 的
strings 里挖的，`appearance` 只有 `dark` / `tinted` 两个值，不写 = 默认外观）：
dark 用纸面那对米色渐变（正好反转），tinted 用纯白（着色拿满亮度）。
Clear 的深色变体是运行时从 dark 堆栈派生的，跟着一起好。

核对办法：ictool 编译出 Assets.car 后，烘焙的 1024px fallback 位图带着
`UIAppearanceDark` / `ISAppearanceTintable` 标签，用 CoreUI 私有 API
（`CUICatalog` + `enumerateNamedLookupsUsingBlock:`）能抽出来直接看。

## 离线预览（不用跑 Xcode，两秒）

```
/Applications/Xcode.app/Contents/Developer/usr/bin/ictool --compile out \
  --platform iphoneos --minimum-deployment-target 26.0 --app-icon AppIcon \
  --output-partial-info-plist /dev/null App/AppIcon.icon
```

目录名必须叫 `AppIcon.icon`，图标堆栈的名字从文件名来。

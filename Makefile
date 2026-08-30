# ⚠️ 改了 App/Resources/ 下的文件（CSS 等），xcodebuild **不一定会重新拷贝**——
# 编译成功、bundle 里还是旧的，于是样式改了不生效，还以为是 CSS 写错了。
# 实测：改内容不触发重拷，touch 一下才触发。所以 build 前无条件 touch 一遍。
# 复现在 CLAUDE.md「已知的坑」里。
.DEFAULT_GOAL := help
SIM ?= iPhone 17 Pro
# 默认只推正文。1.1 GB 的 oaldpe.1.mdd 等 M4 做发音时再推。
SRC ?= dicts/oalecd_10_refined/oaldpe.mdx

help:  ## 列出所有命令
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | column -t -s $$'\t'

project:  ## 从 project.yml 生成 Dict.xcodeproj（工程文件不入库）
	xcodegen generate

test:  ## 跑解析层测试（不需要 Xcode，秒级）
	swift test

build:  ## 编译 iOS App（模拟器，不需要签名）
	@$(MAKE) -s project
	@touch App/Resources/*      # 见下
	@# touch 也有失手的时候（时钟跳变后 mtime 比不过），产物里的 CSS 直接删掉最稳
	@rm -f "$$(xcodebuild -project Dict.xcodeproj -scheme Dict \
		-destination 'platform=iOS Simulator,name=$(SIM)' -showBuildSettings 2>/dev/null | \
		awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $$2}')/Dict.app/"*.css 2>/dev/null || true
	xcodebuild -project Dict.xcodeproj -scheme Dict \
		-destination 'platform=iOS Simulator,name=$(SIM)' build | \
		grep -E 'error:|warning:|BUILD (SUCCEEDED|FAILED)' || true

run:  ## 装到模拟器并启动
	@$(MAKE) -s build
	@xcrun simctl boot "$(SIM)" 2>/dev/null || true
	@open -a Simulator
	@xcrun simctl install booted "$$(xcodebuild -project Dict.xcodeproj -scheme Dict \
		-destination 'platform=iOS Simulator,name=$(SIM)' -showBuildSettings 2>/dev/null | \
		awk -F' = ' '/ BUILT_PRODUCTS_DIR/{d=$$2} / FULL_PRODUCT_NAME/{n=$$2} END{print d"/"n}')"
	@xcrun simctl launch booted com.fx.dict

build-mac:  ## 编译 macOS App
	@$(MAKE) -s project
	@touch App/Resources/*      # 同 build：改了 CSS 不 touch 不重拷
	@rm -f "$$(xcodebuild -project Dict.xcodeproj -scheme DictMac -showBuildSettings 2>/dev/null | \
		awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $$2}')/Aphros.app/Contents/Resources/"*.css 2>/dev/null || true
	xcodebuild -project Dict.xcodeproj -scheme DictMac build | \
		grep -E 'error:|warning:|BUILD (SUCCEEDED|FAILED)' || true

run-mac:  ## 编译并启动 macOS App（词典放 ~/Documents/Dict）
	@$(MAKE) -s build-mac
	@open "$$(xcodebuild -project Dict.xcodeproj -scheme DictMac -showBuildSettings 2>/dev/null | \
		awk -F' = ' '/ BUILT_PRODUCTS_DIR/{d=$$2} / FULL_PRODUCT_NAME/{n=$$2} END{print d"/"n}')"

dmg:  ## 出 macOS 分发 DMG（Release + Developer ID 签名 + 公证；词典不进 DMG）
	@$(MAKE) -s project
	@touch App/Resources/*
	@# Release 不是仪式感（同 device）：建索引 debug 比 release 慢 23 倍。
	xcodebuild -project Dict.xcodeproj -scheme DictMac -configuration Release \
		-derivedDataPath DerivedData build | grep -E 'error:|BUILD (SUCCEEDED|FAILED)' || true
	@rm -rf dist/dmgroot && mkdir -p dist/dmgroot
	@cp -R DerivedData/Build/Products/Release/Aphros.app dist/dmgroot/
	@# 重签成 Developer ID（构建时是 Apple Development，只在本机受信）。
	@# --options runtime（Hardened Runtime）和 --timestamp 是公证的硬要求。
	codesign --force --timestamp --options runtime \
		--sign "$(SIGN_ID)" dist/dmgroot/Aphros.app
	@codesign --verify --deep --strict dist/dmgroot/Aphros.app && echo "签名校验通过"
	@ln -sf /Applications dist/dmgroot/Applications
	hdiutil create -volname Aphros -srcfolder dist/dmgroot -ov -format UDZO "$(DMG)"
	@# 公证 + 装订：凭据是钥匙串档案 dict（xcrun notarytool store-credentials dict …
	@# 一次性存好）。--wait 等 Apple 审完（通常一两分钟）；stapler 把票据钉进
	@# DMG，目标机离线也能过 Gatekeeper。
	xcrun notarytool submit "$(DMG)" --keychain-profile dict --wait
	xcrun stapler staple "$(DMG)"
	@ls -lh dist/*.dmg

VERSION := $(shell awk -F'"' '/MARKETING_VERSION/{print $$2; exit}' project.yml)
DMG     := dist/Aphros-$(VERSION).dmg
# Developer ID 证书。本机钥匙串里有两张同名的，按名字签会报 ambiguous，
# 用哈希指定（security find-identity -v -p codesigning 可查）。
SIGN_ID ?= 73D4246880EE405E4704CE7BFBB18779DB0596F4

device:  ## 装到连着线的真机并启动（UDID=<设备UDID>）
	@test -n "$(UDID)" || (echo "用法: make device UDID=<设备UDID>  （xcrun devicectl list devices 可查）" && exit 1)
	@$(MAKE) -s project
	@# Release 不是仪式感：建索引的排序 debug 比 release 慢 23 倍（实测 322 ms vs 14 ms），
	@# 冷启动 1.15 s 里大头全是 -Onone 的税。模拟器无所谓，装上真机用的必须是 Release。
	xcodebuild -project Dict.xcodeproj -scheme Dict -destination 'generic/platform=iOS' \
		-configuration Release \
		-derivedDataPath DerivedData build | grep -E 'error:|BUILD (SUCCEEDED|FAILED)' || true
	xcrun devicectl device install app --device $(UDID) DerivedData/Build/Products/Release-iphoneos/Aphros.app
	xcrun devicectl device process launch --device $(UDID) com.fx.dict

sim-dicts:  ## 把 mdx 拷进模拟器沙盒（只拷 mdx，1.1 GB 的音频等 M4）
	@xcrun simctl get_app_container "$(SIM)" com.fx.dict data >/dev/null 2>&1 || \
		(echo "先 make run 装一次 App" && exit 1)
	@mkdir -p "$$(xcrun simctl get_app_container "$(SIM)" com.fx.dict data)/Documents/dicts"
	cp dicts/oalecd_10_refined/oaldpe.mdx \
		"$$(xcrun simctl get_app_container "$(SIM)" com.fx.dict data)/Documents/dicts/"

push-dicts:  ## 把词典推到真机（默认只推 113 MB 的 mdx；SRC= 可指定别的）
	@test -n "$(UDID)" || (echo "用法: make push-dicts UDID=<设备UDID>  （xcrun devicectl list devices 可查）" && exit 1)
	xcrun devicectl device copy to --device $(UDID) \
		--domain-type appDataContainer --domain-identifier com.fx.dict --user mobile \
		--source "$(SRC)" --destination Documents/dicts/ --timeout 3600

clean:  ## 清掉构建产物
	rm -rf .build DerivedData Dict.xcodeproj

.PHONY: help project test build run build-mac run-mac dmg device sim-dicts push-dicts clean

#!/bin/sh
# 把一台 iOS 模拟器启动起来并把它的画面开出来，兼容 Xcode 27（Device Hub）和 Xcode ≤26（Simulator.app）。
# 不含任何项目相关的东西，可以整个文件拷到别的 iOS 项目里用。
#
# 用法:
#   scripts/sim-open.sh <模拟器名 | UDID>        启动 + 开窗，stdout 只打印 UDID
#   scripts/sim-open.sh -n <模拟器名 | UDID>     只把名字解析成 UDID，什么都不动（给 $(shell …) 用）
#
# 典型接法:
#   udid=$(scripts/sim-open.sh "iPhone 17") &&
#   xcrun simctl install "$udid" path/to/App.app &&
#   xcrun simctl launch  "$udid" com.example.app
#
# 为什么要有这个脚本（Xcode 27 实测，2026-09）:
#   1. Xcode 27 砍掉了 Simulator.app，`open -a Simulator` 直接报找不到应用。模拟器画面并进了
#      Device Hub（<Xcode>/Contents/Applications/DeviceHub.app，bundle id com.apple.dt.Devices）。
#   2. Device Hub 不会跟着新启动的设备走：simctl boot 一台新的、再打开它，窗口停在上次选中的那台上。
#      要点名开窗只能用它没公开的 URL scheme:  devices://device/open?id=<UDID>
#      （动作名 open / select / showInspector 和参数名 id 是从 DeviceKit.framework 反汇编出来的；
#      没在跑也能靠这条 URL 冷启动，开出来的是 Xcode 运行时那种紧凑窗口。）
#   3. simctl 按名字找设备会撞车：同名机型可能横跨多个运行时（比如 iPhone Air 在 26.5 和 27 各一台），
#      所以这里先把名字解析成 UDID，取运行时版本最高的那台，后面全用 UDID。
#   4. 退出 Device Hub 会把所有模拟器一起关掉（和老 Simulator.app 一样）；它启动时若没有在跑的
#      设备就不开任何窗口，看着像没起来，其实进程在。所以顺序必须是先 boot 再开窗。
set -eu

resolve_only=0
if [ "${1:-}" = "-n" ]; then resolve_only=1; shift; fi
target="${1:-}"
if [ -z "$target" ]; then
  echo "用法: $0 [-n] <模拟器名 | UDID>" >&2; exit 2
fi

# 名字 → UDID。传进来的已经是 UDID 就原样用。
case "$target" in
  ????????-????-????-????-????????????) udid="$target" ;;
  *)
    udid=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
cands = []
for runtime, devices in json.load(sys.stdin)["devices"].items():
    # runtime 形如 com.apple.CoreSimulator.SimRuntime.iOS-27-0
    ver = tuple(int(x) for x in runtime.rsplit(".", 1)[-1].split("-")[1:] if x.isdigit())
    for d in devices:
        if d["name"] == name:
            cands.append((ver, d["udid"]))
print(max(cands)[1] if cands else "")
' "$target")
    if [ -z "$udid" ]; then
      echo "找不到模拟器「${target}」。有哪些看: xcrun simctl list devices available" >&2; exit 1
    fi ;;
esac

if [ "$resolve_only" = 1 ]; then echo "$udid"; exit 0; fi

# 已经在跑的 boot 会报 "Unable to boot device in current state: Booted"，无害，吞掉。
xcrun simctl boot "$udid" 2>/dev/null || true

# 开窗。按当前 xcode-select 指向的那份 Xcode 判断，而不是猜 LaunchServices 会把 devices:// 派给谁——
# 机器上同时装着 26 和 27 时后者不可靠。
dev_dir=$(xcode-select -p)
if [ -d "$dev_dir/../Applications/DeviceHub.app" ]; then
  open "devices://device/open?id=$udid"
elif [ -d "$dev_dir/Applications/Simulator.app" ]; then
  open -a "$dev_dir/Applications/Simulator.app" --args -CurrentDeviceUDID "$udid"
else
  echo "既没有 Device Hub 也没有 Simulator.app：$dev_dir" >&2; exit 1
fi

echo "$udid"

#!/usr/bin/env bash
# CI 用（build.yml 的 android job 调用）：在 x86_64 安卓模拟器里装测试包，冷启动、截图、按返回键、收日志。
# 模拟器是软件渲染，只能证明“能装、能启动、能进菜单、返回键不退出、刷新率申请的 Java 调用走得通”，
# 不代表真机的帧率和画面。
# 用法: bash scripts/android-emu-test.sh <apk> <输出目录>
set -u
APK="$1"
OUT="$2"
PKG=com.adamdashen666.apexdriftmobile
mkdir -p "$OUT"
dsh() { adb shell "$@" | tr -d '\r'; }

adb wait-for-device
for i in $(seq 1 60); do [ "$(dsh getprop sys.boot_completed)" = "1" ] && break; sleep 2; done
echo "模拟器: API $(dsh getprop ro.build.version.sdk) $(dsh getprop ro.product.cpu.abi) vulkan=$(dsh getprop ro.hardware.vulkan) egl=$(dsh getprop ro.hardware.egl)"
dsh dumpsys display | grep -E "mSupportedModes|mActiveModeId|renderFrameRate" | head -6 > "$OUT/display.txt" || true

adb install -r -g "$APK" > "$OUT/install.txt" 2>&1 || { cat "$OUT/install.txt"; echo "安装失败"; exit 1; }
cat "$OUT/install.txt"
adb logcat -c
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1

# 软件渲染下第一次编译着色器很慢：等进了主菜单（main.gd 会打“进入主菜单”）
started=0
for i in $(seq 1 120); do
  sleep 2
  if adb logcat -d -s godot:I 2>/dev/null | grep -q "进入主菜单"; then started=1; break; fi
  [ -n "$(dsh pidof $PKG)" ] || { [ $i -gt 5 ] && break; }
done
echo "等待 $((i * 2)) 秒，进菜单=$started"
sleep 10
adb exec-out screencap -p > "$OUT/1_menu.png"
pid1=$(dsh pidof $PKG)

# 返回键：主菜单上只弹提示，不退出
adb shell input keyevent KEYCODE_BACK
sleep 0.8
adb exec-out screencap -p > "$OUT/2_back_toast.png"
sleep 4
pid2=$(dsh pidof $PKG)

adb logcat -d > "$OUT/logcat.txt" 2>&1
grep -E "AndroidRuntime|FATAL|libc  |DEBUG   " "$OUT/logcat.txt" | head -40 > "$OUT/crash.txt" || true
echo "---- 游戏日志 ----"
grep -E "\[APEX\]|SCRIPT ERROR|USER ERROR|Vulkan|OpenGL" "$OUT/logcat.txt" | head -60

echo "进程: 启动后 ${pid1:-无}，按返回键后 ${pid2:-无}"
fail=0
[ $started = 1 ] || { echo "::warning::模拟器里没等到游戏进主菜单"; fail=1; }
[ -n "$pid1" ] && [ "$pid1" = "$pid2" ] || { echo "::warning::模拟器里按返回键后进程变了或游戏崩了"; fail=1; }
grep -q "SCRIPT ERROR" "$OUT/logcat.txt" && { echo "::warning::模拟器里有脚本错误"; fail=1; }
exit $fail

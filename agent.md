# APEX DRIFT 移动版 交接

## 目标
把 Windows 版 APEX DRIFT 做成移动版：目标 120fps、不锁帧。iOS 出**未签名 IPA** 给用户自己签；安卓出**已签名、可直接安装的 APK**。

## 结构（非显而易见的部分）
- Godot 工程在 `game/`；全部逻辑是 GDScript（`game/scripts/`），界面自绘（`ui.gd`），材质全在 `mats.gd`。
- 素材不手改：由 UE 工程 `C:/Users/Admin/.gemini/antigravity/scratch/ApexDrift/Tools/mobile/` 下脚本生成到 `game/assets`（`build_cars.py`、`build_flora_props.py`、`build_maps.py`、`build_misc.py`，新增贴图后跑 `write_imports.py <game>`）。
- 车是 RigidBody3D + 射线悬挂（`car.gd`），物理 120Hz，手动插值。坐标：UE (x, y, z 上) → Godot (x, z, y)，航向 yaw = atan2(z, x)。
- 操控三档都在 `car.gd` 的 `_drive`（直接设速度方向和横摆的手感模型，不是轮胎物理）。拟真档 = Windows v2.10（v2.5 的做法 + 倒着滑）：平时走抓地态的车身稳定（拟真专用 LatMax 14、横摆上限 80°/s、转角上限 +4°）；手刹+方向 >30km/h 进 `_sim_slide`（= UE `UpdateSimSlide`）：车头相对行进方向的转动按惯性积分，回正力矩 90° 内 −K·sinψ，80°–105° 过渡到 +0.45K·sinψ、阻尼 6（`SIM_BACK_ALIGN` / `SIM_BACK_DAMP`），所以甩过约 93° 松手会一直倒着滑到 <12km/h。UE 抓地态横摆闭环里“允许少量侧滑（低速 3°、高速 0.3°，油门加方向再多约 9°）”没有照搬：移动版是运动学模型，轮胎自己不产生侧滑，照搬只会让车头滞后形成方向不对的侧滑，所以保留原来的全程扶正（Windows v2.10 实测这些场景也只滑 0.5–1.7°）。v2.6–v2.9 的轮胎物理和“牵引力控制”设置已删掉（旧存档里的 `tcs` 键不再读）。
- 地图网格材质名以 `X_` 开头，`world.gd` 按名字换成 `mats.gd` 的材质；节点名 `Road_` 进路面碰撞，`Solid_` 是实体碰撞，`Rail_` / `Marks_` 只看不撞。
- 性能手段：顶点色材质、树远景 impostor 图集、MultiMesh 分格 + visibility_range、正交单级阴影、动态分辨率（`perf.gd`）、HUD 60Hz 重画。
- 署名文件 `game/CREDITS.txt`，导出时随包（include_filter `*.txt`），游戏内可看；素材来源有变要同步改。
- 安卓专用代码只在 `droid.gd`（`Droid.active` 为假时全是空操作）：经 AndroidRuntime 插件 + JavaClassWrapper 取屏幕支持的最高刷新率，对渲染 SurfaceView 的 Surface / SurfaceControl 调 `setFrameRate`。`perf.gd` 在安卓上每 2 秒核对系统实际刷新率（省电 / 过热 / 用户锁 60 时直接按 60 跑）。
- 返回键：`main.gd` 的 `go_back()`（安卓返回键 / 桌面 Esc）——游戏中打开暂停，暂停里继续，设置 / 帮助 / 署名 / 结算返回上一级，主菜单 2 秒内按两次才退出。`quit_on_go_back=false`。
- 安卓图标：`game/android_icons/`（带 `.gdignore`，不进 pck）由 `python scripts/make_android_icons.py` 从 `game/icon.png` 生成前景 / 背景 / 单色三层；改了 icon.png 要重跑。
- 安卓导出用 gradle 构建（只有 gradle 构建才能设最低版本），模板在 CI 里 `--install-android-build-template` 装到 `game/android/`（已 gitignore）。

## 验证
- CI `preview`：`--autotest` 逻辑测试（四图静置、自动漂移一圈、三档操控、拟真档场景 `_sim_tests`（对照 UE `-ApexBenchSim` / `-ApexBenchGrip`：直线起步、S60/S120/S180、低速全油门满舵、全刹、手刹甩到 40° 自己回正、甩到 140° 倒着滑、甩起来只给油门维持角度不转圈、按住手刹 360、倒车、滑动中复位）、坡道、撞道具、双击复位、存档写读、菜单每个按钮、用真实触摸点地图卡（含第 4 张训练场）再开赛、返回键各级）+ 无参数正常启动两次 + `--shots=<目录>` 截图。
- `[ipa]` 提交才跑 macOS：导出 Xcode 工程 → 未签名 IPA → 在 macOS 上用 Metal 跑截图、跑导出的 pck、跑分（官方模板的模拟器库只有 x86_64 且不支持 Metal 渲染，所以不用模拟器）。
- `[apk]` 提交才跑安卓（ubuntu）：gradle 导出 arm64 APK → `apksigner verify`、`aapt2 dump badging`（包名、最低 API 29、只有 arm64-v8a、只有 VIBRATE 权限、桌面入口）、体积 < 200MB → 解出 APK 的 `assets/`，用 Linux 版 Godot `--main-pack assets/assets.sparsepck` 加软件 Vulkan 跑截图 → 另导一个 x86_64 测试包在 API 34 模拟器（SwiftShader Vulkan）里冷启动、按返回键，看游戏日志（Vulkan 初始化、进菜单、首帧画出、刷新率申请的 Java 调用、返回键只提示不退出）。**模拟器测试不稳定、未作为门槛**（`continue-on-error`，结果在 `android-logs/emulator/`）：模拟器截屏多为黑屏或旧帧，不能当画面证据；画面以 Linux 跑 APK 里的 pck 截图为准。
- 手动触发 workflow 时 iOS 和安卓都出。Windows 上不在本机运行 Godot（权限不允许），全部在 CI 上跑；`scripts/ci-run.sh` 推送并等构建、下载产物到 `out/<run_id>/`。

## 当前状态
- 最新包：run 46143249763（2026-11-28，当前代码，拟真档 = Windows v2.10）：iOS 未签名 IPA 约 92MB（iOS 16+，A12 起，`out/46143249763/ios-app/`），安卓 APK 约 145MB（versionCode 22，调试签名，`out/46143249763/android-apk/`）；三个任务全绿，macOS Metal 截图正常。首个 iOS 包是 run 45689037016。
- 已同步到 Windows v2.10：拟真档回到 v2.5 的做法 + 甩过约 93° 后倒着滑，设置页去掉“牵引力控制”，帮助页拟真说明与 Windows 同文（分两行）。v2.6 的另两个修复移动版不需要：复位 bug 是 UE Chaos `ResetVehicleState` 特有的（移动版没有 Chaos、没有手动挡），第 4 张地图卡移动版本来就能点；两者都有测试。DLSS 不适用。
- 拟真档 CI 数值（APEX GT，训练场平地）：0-100 2.44s、S60（定速）/S120/S180 侧滑 1.0°/0.5°/0.2°、55km/h 全油门满舵 1.0°、150km/h 全刹 0°；100km/h 手刹甩到 40° 全松：最大 71° 后转回朝前；110km/h 甩到 141° 全松：倒着滑满 4 秒（Windows 也是 4 秒）；甩起来只给油门+满舵：维持在 75° 以内不转圈；按住手刹满舵 2.5s 转 682°（记 360 两次）；三辆车手刹+满舵 0.9s 甩过 130–162° 后都稳在倒着滑（172–177°）。
- 安卓 v1.0 已交付（最终绿灯 run 45824639448，APK 在 `out/45824639448/android-apk/`）：APK 约 138MB（其中 libgodot_android.so 71MB 不压缩存放），versionName 1.0，最低 Android 10（API 29），target 36，只有 arm64-v8a，权限只有 VIBRATE，横屏 userLandscape，gradle 构建。
- 安卓签名：默认每次构建临时生成调试密钥库（`androiddebugkey`/`android`），**签名每次不同，覆盖安装前要先卸载旧版**；仓库若配了 `ANDROID_KEYSTORE_BASE64` / `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_ALIAS` 三个 secrets 就用用户证书（用户自己运行 `scripts/set-android-signing.sh` 设置）。versionCode = 构建序号。
- `perf.gd`：动态分辨率 → 到底还掉帧就逐级关 MSAA、再降分辨率、关阴影；低电量锁 60 时自动按 60 跑。
- 每帧约 140–330 draws、9–19 万三角。CI 的 macOS 虚拟机（Apple 虚拟 GPU，关垂直同步，约 1.39M 像素的 3D 画面）平均 97–216fps，机器波动大，只能看趋势，不代表 iPhone。

## 未覆盖
- 拟真档手感没在真机上试过。甩起来只给油门+满舵维持的角度移动版是 75°，Windows 写的是约 50°（同一套力矩公式，轨迹 / 车速模型不同），没调。
- 没有真机：120fps、重力感应、震动、手柄、声音、发热都没在真机验证；A13 以上走的 Metal 参数缓冲路径 CI 上也跑不到（虚拟 GPU 是 Apple5）。
- 安卓同样没有真机：高刷申请（`Surface.setFrameRate`）、关掉 Swappy 后的帧节奏、刘海安全区、180° 翻转后的重力方向、震动强度都只在代码层面和模拟器里走过。
- 首次启动要在设备上编译着色器（虚拟机上约 40 秒，之后不到 1 秒），没有做导出时预编译（shader_baker 需要把材质改成资源文件，且没有真机可验）。

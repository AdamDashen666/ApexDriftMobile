# APEX DRIFT 移动版 交接

## 目标
把 Windows 版 APEX DRIFT 做成移动版：目标 120fps、不锁帧。iOS 出**未签名 IPA** 给用户自己签；安卓出**已签名、可直接安装的 APK**。

## 结构（非显而易见的部分）
- Godot 工程在 `game/`；全部逻辑是 GDScript（`game/scripts/`），界面自绘（`ui.gd`），材质全在 `mats.gd`。
- 素材不手改：由 UE 工程 `C:/Users/Admin/.gemini/antigravity/scratch/ApexDrift/Tools/mobile/` 下脚本生成到 `game/assets`（`build_cars.py`、`build_flora_props.py`、`build_maps.py`、`build_misc.py`，新增贴图后跑 `write_imports.py <game>`）。
- 车是 RigidBody3D + 射线悬挂（`car.gd`），物理 120Hz，手动插值。坐标：UE (x, y, z 上) → Godot (x, z, y)，航向 yaw = atan2(z, x)。
- 操控三档都在 `car.gd`：均衡 / 专业是直接设速度的手感模型（`_drive`）；拟真档 `_sim()` 是 Windows 版 v2.9 `UpdateSimPhysics` 的移植（四轮轮胎模型 + 载荷转移 + 后轮胎面速度 + 自动挡 + 牵引力控制 / 关掉时的空转上限；v2.9 起拉手刹起的横滑期间（`sim_hand_slide`：拉手刹起，到车身不再横滑且松手刹超过 1 秒）牵引力控制不限油门、按关掉时的上限和手刹增益 2.0 处理，可以用油门续漂，`SIM_*` 常量 = UE `namespace ApexSim`，共用 UE 主角车底盘的轮位），只在不锁车时跑（倒计时 / 菜单仍走 `_drive` 的低速保持）。风阻 0.95v² 在拟真档里显式加（UE 是 Chaos 出的），驱动力里等量补回。牵引力控制：存档 `Save.tcs`（默认开），`start_race` 和设置按钮写进 `car.tcs`；`reset_state()` 只清动态状态、不碰设置。
- 地图网格材质名以 `X_` 开头，`world.gd` 按名字换成 `mats.gd` 的材质；节点名 `Road_` 进路面碰撞，`Solid_` 是实体碰撞，`Rail_` / `Marks_` 只看不撞。
- 性能手段：顶点色材质、树远景 impostor 图集、MultiMesh 分格 + visibility_range、正交单级阴影、动态分辨率（`perf.gd`）、HUD 60Hz 重画。
- 署名文件 `game/CREDITS.txt`，导出时随包（include_filter `*.txt`），游戏内可看；素材来源有变要同步改。
- 安卓专用代码只在 `droid.gd`（`Droid.active` 为假时全是空操作）：经 AndroidRuntime 插件 + JavaClassWrapper 取屏幕支持的最高刷新率，对渲染 SurfaceView 的 Surface / SurfaceControl 调 `setFrameRate`。`perf.gd` 在安卓上每 2 秒核对系统实际刷新率（省电 / 过热 / 用户锁 60 时直接按 60 跑）。
- 返回键：`main.gd` 的 `go_back()`（安卓返回键 / 桌面 Esc）——游戏中打开暂停，暂停里继续，设置 / 帮助 / 署名 / 结算返回上一级，主菜单 2 秒内按两次才退出。`quit_on_go_back=false`。
- 安卓图标：`game/android_icons/`（带 `.gdignore`，不进 pck）由 `python scripts/make_android_icons.py` 从 `game/icon.png` 生成前景 / 背景 / 单色三层；改了 icon.png 要重跑。
- 安卓导出用 gradle 构建（只有 gradle 构建才能设最低版本），模板在 CI 里 `--install-android-build-template` 装到 `game/android/`（已 gitignore）。

## 验证
- CI `preview`：`--autotest` 逻辑测试（四图静置、自动漂移一圈、三档操控、拟真档轮胎物理场景 `_sim_tests`（对照 UE `-ApexBenchSim` / `-ApexBenchGrip`：直线起步、S60/S120/S180、低速全油门满舵、全刹、手刹、甩圈、倒车、复位后设置保持，牵引力控制开 / 关各一遍）、坡道、撞道具、双击复位、存档写读、菜单每个按钮、用真实触摸点地图卡（含第 4 张训练场）再开赛、返回键各级）+ 无参数正常启动两次 + `--shots=<目录>` 截图。
- `[ipa]` 提交才跑 macOS：导出 Xcode 工程 → 未签名 IPA → 在 macOS 上用 Metal 跑截图、跑导出的 pck、跑分（官方模板的模拟器库只有 x86_64 且不支持 Metal 渲染，所以不用模拟器）。
- `[apk]` 提交才跑安卓（ubuntu）：gradle 导出 arm64 APK → `apksigner verify`、`aapt2 dump badging`（包名、最低 API 29、只有 arm64-v8a、只有 VIBRATE 权限、桌面入口）、体积 < 200MB → 解出 APK 的 `assets/`，用 Linux 版 Godot `--main-pack assets/assets.sparsepck` 加软件 Vulkan 跑截图 → 另导一个 x86_64 测试包在 API 34 模拟器（SwiftShader Vulkan）里冷启动、按返回键，看游戏日志（Vulkan 初始化、进菜单、首帧画出、刷新率申请的 Java 调用、返回键只提示不退出）。**模拟器测试不稳定、未作为门槛**（`continue-on-error`，结果在 `android-logs/emulator/`）：模拟器截屏多为黑屏或旧帧，不能当画面证据；画面以 Linux 跑 APK 里的 pck 截图为准。
- 手动触发 workflow 时 iOS 和安卓都出。Windows 上不在本机运行 Godot（权限不允许），全部在 CI 上跑；`scripts/ci-run.sh` 推送并等构建、下载产物到 `out/<run_id>/`。

## 当前状态
- 最新包：run 46131199240（2026-11-28，当前代码，含拟真档轮胎物理 + 牵引力控制）：iOS 未签名 IPA 约 92MB（iOS 16+，A12 起，`out/46131199240/ios-app/`），安卓 APK 约 145MB（versionCode 19，调试签名，`out/46131199240/android-apk/`）；逻辑测试全过，macOS Metal 截图正常。上一版（旧操控）是 run 46105249531，首个 iOS 包是 run 45689037016。
- 已同步 Windows v2.6–v2.9 的操控：拟真档轮胎物理 + 设置“牵引力控制”（拟真档起作用，默认开；开 = 平时不会被油门甩尾，手刹起漂后可以用油门续漂）。v2.6 另两个修复移动版不需要：复位 bug 是 UE Chaos `ResetVehicleState` 特有的（移动版没有 Chaos、没有手动挡），第 4 张地图卡移动版本来就能点；两者都加了测试。DLSS 不适用。
- 拟真档 CI 数值（APEX GT，平地）：牵引力控制开 0-100 3.44s、S60/S120/S180 侧滑 2.2°/3.8°/3.9°、55km/h 全油门满舵 2.1°、150km/h 全刹 0°、手刹一甩全松转到 182°（倒着滑，不拉回）、按住手刹满舵 1.2s 转 184°、手刹一甩再油门满舵能甩圈（横滑中不限油门，稳住后恢复）；关：直线全油门不转圈（0-100 3.48s）、55km/h 全油门满舵甩到 58°、手刹一甩再油门满舵 4 秒转约一圈。
- 安卓 v1.0 已交付（最终绿灯 run 45824639448，APK 在 `out/45824639448/android-apk/`）：APK 约 138MB（其中 libgodot_android.so 71MB 不压缩存放），versionName 1.0，最低 Android 10（API 29），target 36，只有 arm64-v8a，权限只有 VIBRATE，横屏 userLandscape，gradle 构建。
- 安卓签名：默认每次构建临时生成调试密钥库（`androiddebugkey`/`android`），**签名每次不同，覆盖安装前要先卸载旧版**；仓库若配了 `ANDROID_KEYSTORE_BASE64` / `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_ALIAS` 三个 secrets 就用用户证书（用户自己运行 `scripts/set-android-signing.sh` 设置）。versionCode = 构建序号。
- `perf.gd`：动态分辨率 → 到底还掉帧就逐级关 MSAA、再降分辨率、关阴影；低电量锁 60 时自动按 60 跑。
- 每帧约 140–330 draws、9–19 万三角。CI 的 macOS 虚拟机（Apple 虚拟 GPU，关垂直同步，约 1.39M 像素的 3D 画面）平均 97–216fps，机器波动大，只能看趋势，不代表 iPhone。

## 未覆盖
- 拟真档手感没在真机上试过。牵引力控制关时比 Windows 版更容易被油门甩出去（55km/h 全油门满舵 58° vs Windows 报告的 25–35°，全油门打方向 S60 能甩到 88°），同一套公式，差别来源没查（底盘 / 悬挂不同、测试起点是传送而不是加速上来）。
- 没有真机：120fps、重力感应、震动、手柄、声音、发热都没在真机验证；A13 以上走的 Metal 参数缓冲路径 CI 上也跑不到（虚拟 GPU 是 Apple5）。
- 安卓同样没有真机：高刷申请（`Surface.setFrameRate`）、关掉 Swappy 后的帧节奏、刘海安全区、180° 翻转后的重力方向、震动强度都只在代码层面和模拟器里走过。
- 首次启动要在设备上编译着色器（虚拟机上约 40 秒，之后不到 1 秒），没有做导出时预编译（shader_baker 需要把材质改成资源文件，且没有真机可验）。

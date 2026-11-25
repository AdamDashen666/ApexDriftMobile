# APEX DRIFT 移动版 交接

## 目标
把 Windows 版 APEX DRIFT 做成 iOS 移动版：目标 120fps、不锁帧，出**未签名 IPA** 给用户自己签。

## 结构（非显而易见的部分）
- Godot 工程在 `game/`；全部逻辑是 GDScript（`game/scripts/`），界面自绘（`ui.gd`），材质全在 `mats.gd`。
- 素材不手改：由 UE 工程 `C:/Users/Admin/.gemini/antigravity/scratch/ApexDrift/Tools/mobile/` 下脚本生成到 `game/assets`（`build_cars.py`、`build_flora_props.py`、`build_maps.py`、`build_misc.py`，新增贴图后跑 `write_imports.py <game>`）。
- 车是 RigidBody3D + 射线悬挂（`car.gd`），物理 120Hz，手动插值。坐标：UE (x, y, z 上) → Godot (x, z, y)，航向 yaw = atan2(z, x)。
- 地图网格材质名以 `X_` 开头，`world.gd` 按名字换成 `mats.gd` 的材质；节点名 `Road_` 进路面碰撞，`Solid_` 是实体碰撞，`Rail_` / `Marks_` 只看不撞。
- 性能手段：顶点色材质、树远景 impostor 图集、MultiMesh 分格 + visibility_range、正交单级阴影、动态分辨率（`perf.gd`）、HUD 60Hz 重画。
- 署名文件 `game/CREDITS.txt`，导出时随包，游戏内可看；素材来源有变要同步改。

## 验证
- CI `preview`：`--autotest` 逻辑测试（四图静置、自动漂移一圈、三档操控、360、坡道、撞道具、双击复位、存档写读、菜单每个按钮）+ 无参数正常启动两次+ `--shots=<目录>` 截图。
- `[ipa]` 提交才跑 macOS：导出 Xcode 工程 → 未签名 IPA → 在 macOS 上用 Metal 跑截图、跑导出的 pck、跑分（官方模板的模拟器库只有 x86_64 且不支持 Metal 渲染，所以不用模拟器）。
- Windows 上不在本机运行 Godot（权限不允许），全部在 CI 上跑。

## 当前状态
- v1.0 已交付（run 45689037016，未签名 IPA 约 92MB，iOS 16+，A12 起）。
- `perf.gd`：动态分辨率 → 到底还掉帧就逐级关 MSAA、再降分辨率、关阴影；低电量锁 60 时自动按 60 跑。
- 每帧约 140–330 draws、9–19 万三角。CI 的 macOS 虚拟机（Apple 虚拟 GPU，关垂直同步，约 1.39M 像素的 3D 画面）平均 97–216fps，机器波动大，只能看趋势，不代表 iPhone。

## 未覆盖
- 没有真机：120fps、重力感应、震动、手柄、声音、发热都没在真机验证；A13 以上走的 Metal 参数缓冲路径 CI 上也跑不到（虚拟 GPU 是 Apple5）。
- 首次启动要在设备上编译着色器（虚拟机上约 40 秒，之后不到 1 秒），没有做导出时预编译（shader_baker 需要把材质改成资源文件，且没有真机可验）。

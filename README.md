# APEX DRIFT 移动版

Godot 4.7.2（Mobile 渲染器，iOS 走 Metal）写的轻量漂移赛车，是 Windows 版 APEX DRIFT（UE 5.9）的独立移动版：地图、车辆、玩法沿用原创设计，渲染和物理全部重写，以 120fps 为目标。

- 4 张地图：富士樱湖、红枫峠、黑潮港湾、湖畔训练场；每图 3 种天气；7 辆车、8 种漆色。
- 三档操控（均衡 / 专业 / 拟真），自动漂移一圈（含 360），三分钟挑战。
- 触控（按键 / 摇杆 / 重力感应）和手柄。

## 出包
推送即跑 `Test and preview (Linux)`（导入、逻辑测试、软件 Vulkan 截图）。
提交信息带 `[ipa]`，或手动触发 workflow，才会在 macOS 上导出并编译，产物 `ios-app/ApexDriftMobile-unsigned.ipa`，需要自己签名。

## 署名
素材来源与许可见 [CREDITS.txt](game/CREDITS.txt)，游戏内“设置 → 素材署名”可查看。

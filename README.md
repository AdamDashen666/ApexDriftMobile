# APEX DRIFT 移动版

Godot 4.7.2（Mobile 渲染器，iOS 走 Metal，安卓走 Vulkan）写的轻量漂移赛车，是 Windows 版 APEX DRIFT（UE 5.9）的独立移动版：地图、车辆、玩法沿用原创设计，渲染和物理全部重写，以 120fps 为目标。

- 4 张地图：富士樱湖、红枫峠、黑潮港湾、湖畔训练场；每图 3 种天气；7 辆车、8 种漆色。
- 三档操控（均衡 / 专业 / 拟真），自动漂移一圈（含 360），三分钟挑战。
- 触控（按键 / 摇杆 / 重力感应）和手柄。

## 出包
推送即跑 `Test and preview (Linux)`（导入、逻辑测试、软件 Vulkan 截图）。

- 提交信息带 `[ipa]`：在 macOS 上导出并编译，产物 `ios-app/ApexDriftMobile-unsigned.ipa`，需要自己签名。
- 提交信息带 `[apk]`：在 Linux 上用 gradle 导出已签名的安卓包，产物 `android-apk/ApexDriftMobile.apk`（arm64-v8a，Android 10 及以上），可以直接安装。
- 手动触发 workflow：两个都出。

### 安卓签名
- 默认：每次构建临时生成一个调试密钥库签名。**每次构建的签名都不同**，手机上已装旧版时要先卸载再装新版（存档会一起清掉）。
- 可选：用自己的证书，签名就固定，可以一直覆盖安装。在 Git Bash 里运行
  `bash scripts/set-android-signing.sh <密钥库文件> <别名>`（没有密钥库就加 `--new` 新建），
  脚本把证书和密码写进本仓库的 Actions secrets（`ANDROID_KEYSTORE_BASE64` / `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_ALIAS`），不进代码仓库。
  `--remove` 删掉这三个 secrets，回到调试签名。

## 署名
素材来源与许可见 [CREDITS.txt](game/CREDITS.txt)，游戏内“设置 → 素材署名”可查看。

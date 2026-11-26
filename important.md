# 长期事项

- 用户要求：移动端 120fps 以上、不限帧率；iOS 交付未签名 IPA（用户自签，不要催证书），安卓交付已签名可直接安装的 APK；沟通、注释、界面用中文。
- 内容原创，不复刻任何具体游戏；素材只用原创或 CC0 / CC-BY，包内必须带 `CREDITS.txt`。
- 仓库公开（macOS 构建免费），代码和素材别人都能看到，不要放任何密钥、密钥库、密码；签名 secrets 只能由用户自己设置（`scripts/set-android-signing.sh`），代理不要代设、不要接触用户证书。
- `preferredFrameRate=120` 需要 `display/window/ios/allow_high_refresh_rate=true` 且 Info.plist `CADisableMinimumFrameDurationOnPhone=true`，CI 会检查；60Hz 机型和低电量模式上限就是 60。
- 安卓高刷：Android 15 起系统默认把游戏压在 60Hz，必须对渲染 Surface 调 `setFrameRate()`（`droid.gd`）。Godot 自带的 Swappy 会按启动时刻的刷新率定死交换间隔（启动时 60 就一直 60），所以 `display/window/frame_pacing/android/enable_frame_pacing=false`，别打开。
- GDScript 调 Java（JavaClassWrapper / AndroidRuntime）前先 `has_java_method`：方法不存在时直接调用会让整个函数报错中断。
- 安卓导出必须用 gradle 构建：非 gradle 的模板 APK 最低版本固定 API 24，改不了；gradle 模板（4.7.2）要 build-tools 36.1.0、platform 36、JDK 17。aapt2 的 badging 写 `minSdkVersion:`，桌面入口是 activity-alias（不显示为 launchable-activity）。
- 安卓包里的工程数据是 sparse pck：`assets/assets.sparsepck` 只是目录，文件散在 `assets/` 下；Linux 编辑器版 Godot 用 `--main-pack <解包目录>/assets/assets.sparsepck` 能直接跑。
- glTF 顶点色被 Godot 导入时编码成 sRGB，shader 里用网格 `COLOR` 要先 `pow(2.2)`；SurfaceTool 自建网格不用。
- 天空 HDR（`sky/*.hdr`）和 JPG 的经度差 90°，`SKY` shader 的 cubemap 分支里已补偿。
- shader 里不要用 `filter_*_anisotropic`：A12 及更老的机型走 Metal 直接绑定，采样器只有 16 个槽，各向异性那个会越界，整个材质不显示（2026-11 路面和平场中过招）。软件 Vulkan 查不出，改 shader 后要看 macOS Metal 那一步。
- `audio/general/ios/session_category`：3 = Playback（静音开关打开也有声）；1 是 Multi Route，别用错。
- Windows 上 `gh` 的输出行尾带 `\r`，脚本里判断状态前先 `tr -d '\r'`。

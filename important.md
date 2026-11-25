# 长期事项

- 用户要求：移动端 120fps 以上、不限帧率、交付未签名 IPA（用户自签，不要催证书）；沟通、注释、界面用中文。
- 内容原创，不复刻任何具体游戏；素材只用原创或 CC0 / CC-BY，包内必须带 `CREDITS.txt`。
- 仓库公开（macOS 构建免费），代码和素材别人都能看到，不要放任何密钥。
- `preferredFrameRate=120` 需要 `display/window/ios/allow_high_refresh_rate=true` 且 Info.plist `CADisableMinimumFrameDurationOnPhone=true`，CI 会检查；60Hz 机型和低电量模式上限就是 60。
- glTF 顶点色被 Godot 导入时编码成 sRGB，shader 里用网格 `COLOR` 要先 `pow(2.2)`；SurfaceTool 自建网格不用。
- 天空 HDR（`sky/*.hdr`）和 JPG 的经度差 90°，`SKY` shader 的 cubemap 分支里已补偿。

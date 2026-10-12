<div align="center">
  <img src="assets/icon.png" width="112" alt="录映 LuYing 图标" />
  <h1>录映 · LuYing</h1>
  <p>免费的 macOS 录屏与视频美化工具。</p>
  <p>本地录制 · 点击自动缩放 · 字幕 · 无水印导出</p>
  <p><a href="https://github.com/zlbigger/luying/releases/latest">下载安装包</a> · <a href="docs/USAGE.md">使用说明</a> · <a href="https://github.com/zlbigger/luying/issues">反馈问题</a></p>
</div>

录映是一个独立实现、采用 MIT 协议开源的 macOS 应用。无需账号、订阅或付费 API，所有已实现功能均免费开放。录制和媒体处理在本机完成。

**当前为早期版本 v0.1.1**，适合试用和反馈。它不是 Screen Studio 的官方版本，也没有与原版完整功能及质量等价的承诺。

## 功能

| 功能 | 支持情况 |
| --- | --- |
| 显示器、窗口录制 | 使用 macOS 系统选择器选择内容；显示具体所选名称 |
| 区域录制 | 选择显示器后设置区域坐标与尺寸 |
| 系统声音、麦克风 | 系统声音录制；macOS 15+ 支持独立麦克风音轨，导出时混音 |
| 摄像头 | 录制独立摄像头视频，导出时叠加在画面右下角 |
| 暂停与继续 | 屏幕及音频统一扣除暂停时长；摄像头开启时暂不支持暂停 |
| 点击自动缩放 | 根据录制鼠标轨迹和点击位置生成缩放效果 |
| 鼠标与点击提示 | 可隐藏原始鼠标，使用合成大圆点和点击提示环 |
| 裁剪与变速 | 设置单个起止区间；界面支持 0.5×、1×、1.5×、2× |
| 画布与背景 | 横屏、竖屏、方形、4:3；渐变或图片背景、边距、圆角、阴影 |
| 音频处理 | 普通 FFT 降噪、背景音乐循环与混音 |
| 字幕 | 导入 SRT；Apple 本机语音识别生成字幕，取决于系统语言资源 |
| 效果预览 | 本地生成最多 8 秒的效果预览；默认播放器显示原素材 |
| 项目保存 | 保存／恢复素材路径与编辑参数，不复制素材 |
| 导出 | 无水印 MP4／GIF；导出宽度可选 1280～3840 px |

真实显示器、窗口录制和暂停／继续已在开发机器验证；视频合成、双音轨混音、摄像头叠加与中英文字幕烧录用合成样本验证。实际摄像头、各麦克风设备和语音识别质量仍需更多设备测试。

## 安装

**支持：Apple Silicon（M1 或更新），macOS 14+。麦克风录制需要 macOS 15+。Intel 暂无安装包。**

1. 在 [Releases](https://github.com/zlbigger/luying/releases/latest) 下载 `LuYing-v0.1.1-macos-arm64.zip`。
2. 解压，将 `录映.app` 拖入「应用程序」。只保留这一份应用，避免 Spotlight 出现重复项。
3. 安装导出所需依赖：Apple Command Line Tools（提供 Python 3 / Swift）及 FFmpeg / FFprobe：

   ```bash
   xcode-select --install
   brew install ffmpeg
   ```

   `brew` 需要先按 [Homebrew 官方说明](https://brew.sh/) 安装。已有这些依赖可跳过。

4. 打开「录映」，选择「显示器／窗口／区域」，点击「选择显示器…」或「选择窗口…」，在系统选择器确认共享，再开始录制。

**安装包未捆绑 Python、Swift 或 FFmpeg，也没有 Apple Developer ID 签名与公证**，使用本地临时签名。若 Gatekeeper 阻止首次打开，请在「系统设置 → 隐私与安全性」使用系统提供的「仍要打开」流程。无需关闭系统安全保护。

麦克风、摄像头与语音识别在启用相应功能时分别请求授权。系统选择器授权的录制内容直接用于录屏，不在启动时反复请求全屏权限。

## 开始使用

- 录制文件与同名鼠标轨迹 JSON 保存到 `~/Movies/OpenScreenStudio/`。
- 修改裁剪、画幅、背景等参数，点击「效果预览」检查，或直接导出。
- 选择背景图片、音乐或字幕时，请使用你有权使用的素材。
- GIF 不支持音频。本机字幕识别不会回退到云端，语言资源不可用时会显示原因。
- `.ossproject` 只保存路径和参数，移动／删除原素材会使项目无法恢复。

详细操作见 [使用说明](docs/USAGE.md)。

## 从源码构建

```bash
git clone https://github.com/zlbigger/luying.git
cd luying
./build.sh
```

需要 Apple Silicon Mac 与 Command Line Tools。构建脚本会在临时目录编译、签名，并生成 `LuYing.zip`，不会在仓库里留下第二份可被 Spotlight 搜索到的 `.app`。

运行合成媒体回归检查：`./scripts/smoke-test.sh`。

本地导出也可以直接运行：

```bash
python3 exporter.py input.mov output.mp4 \
  --mouse input.json --width 1920 --aspect 16:9 \
  --padding 80 --zoom 1.65 --cursor-size 0 --denoise
```

所有选项：`python3 exporter.py --help`。

## 当前限制

- 尚未实现 iPhone/iPad 直接录制、按键可视化、静音自动删除、多段可视化时间线和云端分享。
- 普通 FFT 音频降噪不等于 AI 降噪；尚无 AI 摄像头增强与完整色彩调整。
- 合成鼠标是圆点；原始鼠标已烘焙到视频中，无法在后期无损移除。
- 自动缩放依赖同名 JSON 轨迹；普通导入视频没有轨迹时不生成该效果。当前最多使用 80 个点击，轨迹会抽样至不超过 800 条。
- 尚未做跨设备／长时间录制的完整兼容性测试。欢迎带系统版本与复现步骤提交 Issue，避免上传敏感录屏。

## 技术与许可

SwiftUI + AppKit、ScreenCaptureKit、AVFoundation、Apple Speech、本机 Python 与 FFmpeg。源代码及自绘图标采用 [MIT](LICENSE)；FFmpeg 由用户独立安装，其许可依具体构建而定。

本仓库不包含其他商业应用的代码、二进制、模型、资源或用户录制文件。

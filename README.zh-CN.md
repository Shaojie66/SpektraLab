<!-- README_SYNC: source=f2aa1b9; updated=2026-11-02 -->
<p align="center">
  <a href="./README.md">English</a> · 简体中文
</p>

# SpektraLab AI（非官方 fork）

macOS 上的光谱级胶片与相纸模拟器，外加一套由 AI 帮你**选胶片、挑构图、做人像磨皮、微调成片**的工作流。打开一张 RAW，约一秒得到一张按物理过程冲印出来的照片。

> 这是 [JamesQiu2005/SpektraLab](https://github.com/JamesQiu2005/SpektraLab) 的个人 fork，并非官方版本。胶片模拟本身来自上游；本 fork 新增的是 [AI 功能](#本-fork-新增ai-选片构图磨皮与精修)。

如果它对你有用，欢迎点一个 [⭐ Star](https://github.com/Shaojie66/spektralab-ai/stargazers)，方便以后回来找，也让更多玩胶片模拟的人看到它。

[![Stars](https://img.shields.io/github/stars/Shaojie66/spektralab-ai?style=flat)](https://github.com/Shaojie66/spektralab-ai/stargazers)
[![基于上游](https://img.shields.io/badge/upstream-SpektraLab%201.3.5-blue)](https://github.com/JamesQiu2005/SpektraLab)
[![平台](https://img.shields.io/badge/macOS-15%2B%20%C2%B7%20Apple%20silicon-lightgrey)](#从源码构建)
[![License](https://img.shields.io/badge/license-GPL--3.0--or--later-green)](LICENSE.txt)
[![Last commit](https://img.shields.io/github/last-commit/Shaojie66/spektralab-ai)](https://github.com/Shaojie66/spektralab-ai/commits/main)

![SpektraLab：秋天的树，Kodak Portra 400 胶片，Kodak Professional Supra Endura 相纸](screenshots/Screenshot_ZH_HANS.png)

## 为什么用它

一般的“胶片滤镜”是一张 LUT：把颜色映射一遍，颗粒贴一层噪点。SpektraLab 走的是暗房的路：

- **光谱计算，不是 LUT。** 光线以 81 个波长穿过胶片与相纸各自的染料层。
- **物理尺度。** 告诉它底片是 120 还是 135，颗粒、光晕和成色剂扩散按画幅以微米为单位缩放。
- **快。** C++ Metal 引擎直接编译进应用：4500 万像素在预览尺寸下重印约 0.01 秒，全分辨率渲染不到一秒。
- **一条色彩管线。** 全程 ProPhoto RGB；每次导出只做一次色域映射，写入前可先软打样。
- **胶片本身。** “片边”按真实胶片实测，印出片基、齿孔、片边字与格号，支持 135、半格、XPan、645 至 6×9、6×12 与 6×17；“日期后背”把日期曝在底片上；“半格拼接”把两张照片放进一格 135。
- **可脚本化。** `spektralab` 命令行与 MCP 服务器驱动的是与窗口同一个会话，默认关闭，在设置中开启。

| RAW 解码 ⟷ 胶片与相纸（⌥\\） | 1:1 颗粒 |
|---|---|
| ![前后对比](screenshots/natural_halation.png) | ![1:1 颗粒](screenshots/physically_accurate_grain.png) |

多选同步、片边、日期后背和半格拼接的完整操作见 [使用说明](docs/USAGE.zh-CN.md)。

## 本 fork 新增：AI 选片、构图、磨皮与精修

胶片和相纸组合有几百种，一张张试很慢。本 fork 在右侧参数栏加了 **AI** 标签页，让视觉模型替你先看一轮，但**只动已有的控件，不改成片像素**。

![AI 标签页：AI 选片、AI 构图、AI 精修](screenshots/Screenshot_AI_ZH_HANS.png)

| 功能 | 它做什么 | 需要 API Key 吗 |
|---|---|---|
| **AI 选片** | 用每款彩色胶片配它的相纸各冲一张小样，连同削波、亮度、反差、色偏等测量交给模型，返回 3–5 个带评分和理由的选择。M 系列 Mac 上 19 款胶片、768 px 约 3 秒 | 需要 |
| **AI 构图** | 先用本机 Vision 框架测地平线、视觉重心和人脸，按规则生成 8–12 个裁切候选，模型只负责挑出最好的三个；不切脸，倾斜超过 0.5° 自动拉直 | 需要（测量在本机） |
| **人像磨皮** | 显影前栏 **人像** 下的 0–100 滑块。只处理脸部，避开眼、眉、唇；在胶片之前进行，所以颗粒和光晕照常落在皮肤上 | 不需要，全在本机 |
| **AI 精修** | 模型看 1024 px 成片，最多三轮调整测光、曝光、滤色、颗粒、光晕和调色；不能改胶片、相纸、裁剪和片边，越界修改会被拒绝 | 需要 |

所有 AI 修改都能用 **撤销 AI 修改** 一步恢复。暂不支持半格拼接。

**怎么开启：** 设置 ▸ AI，选服务商并填 API Key。支持 Anthropic Claude（默认 `claude-opus-5-5`）、任何 OpenAI 兼容的 `/chat/completions` 服务，以及无需 Key 的本地 Ollama（`http://localhost:11434/v1`）。

**数据去向：** 只有点击 **推荐胶片**、**推荐构图** 或 **开始精修** 时才会发送照片，同时发送拍摄参数和调整数值；费用计入你自己的 API 账户。Key 存在 macOS 钥匙串中，不写入设置、sidecar 或日志。

每项功能的规则、阈值和实测数据见 [AI 功能详细说明](docs/AI.zh-CN.md)。

## 从源码构建

AI 功能只在本 fork 的源码里。上游在 [spektralab.app](https://spektralab.app) 和 [Releases](https://github.com/JamesQiu2005/SpektraLab/releases) 提供的 DMG 是官方版本，**不含** AI 标签页；本 fork 目前没有发布构建，需要自己编译。

需要 Apple 芯片、macOS 15 或更高版本、Xcode 26.6。

```bash
engine/build.sh bundle                 # 引擎、着色器、预烘焙资源
cd modern_UI/Spektrafilm
xcodebuild -project Spektrafilm.xcodeproj -scheme Spektrafilm \
           -derivedDataPath build/DerivedData build
```

`engine/resources/` 有改动时请重新运行 `engine/build.sh bundle`。若 Xcode 突然找不到 `metal`，清理构建文件夹（⇧⌘K）即可：Metal 工具链的挂载路径变了，而旧构建缓存了原路径。

### 测试

```bash
xcodebuild -project Spektrafilm.xcodeproj -scheme SpektrafilmTests \
           -derivedDataPath build/DerivedData test       # 约 550 个用例，约 6 分钟
```

相机测试样片来自上游 `spektrafilm` 仓库，通过 `tests` 软链接接入（`ln -s ../spektrafilm/tests tests`）。缺少样片时有 25 个用例会被跳过，运行结果依然显示 0 失败，只需约 20 秒——请以耗时判断，而非失败数。

## 项目结构

| | |
|---|---|
| `modern_UI/Spektrafilm/` | 应用本体：SwiftUI、AppKit、Metal |
| `modern_UI/Spektrafilm/Spektrafilm/AI/` | 本 fork 的 AI 功能 |
| `engine/` | C++20 渲染引擎、MSL 着色器与 C ABI |
| `engine/resources/` | 预烘焙常量、28 款胶片与相纸配置、放大 LUT |
| `ARCHITECTURE.md` | 整体结构——从这里开始读 |
| `AGENTS.md` | 约定，以及真正耗过时间的坑 |

### Windows 开发版

仓库还包含 C++/Vulkan 后端、原生 LibRaw 解码、RGB16 TIFF 导出和 Windows 桌面界面。见 [Windows 说明](engine/WINDOWS.md)、[功能覆盖表](engine/WINDOWS_FEATURE_COVERAGE.md)、[Qt Quick 前端](windows_UI/README.md) 和 [最小 Win32 窗口](engine/WINDOWS_DESKTOP.md)。上文介绍的 macOS 版还有尚未迁移到 Windows 的功能。

## 参与贡献

和胶片模拟本身有关的改动，请直接提交到 [上游仓库](https://github.com/JamesQiu2005/SpektraLab)，并遵守它的规则：

- **Windows 与 Linux 相关的工作只提交到 `Windows_Linux` 分支，不要提交到 `main`。**
- **把工作拆成可审阅的多个提交。** 每个提交只做一件事，提交信息写清做了什么、为什么。
- **尊重开源社区。** 保留许可与致谢，注明你所依赖的他人工作，在 issue 与评审中保持礼貌。

AI 功能相关的改进，欢迎向本仓库提 Pull Request。

## 致谢与许可

胶片过程模型、28 款实测配置与放大 LUT 来自 Andrea Volpato 的 [spektrafilm](https://github.com/andreavolpato/spektrafilm)；4 款黑白胶片配置来自 Hanze Qiu；SpektraLab 是该引擎的原生 C++/Metal 移植，以及围绕它构建的应用。

| | |
|---|---|
| 应用与引擎 | GPL-3.0-or-later |
| 胶片与相纸配置、放大 LUT | CC BY-SA 4.0 |
| metal-cpp | Apache-2.0 |

全部许可文本随应用附带，见 **SpektraLab → 关于 SpektraLab**。

## 商标

SpektraLab™ 名称及其图标由广州松子智能科技服务有限公司管理，相关商标注册申请正在办理中。本仓库是个人 fork，不是官方版本，也不代表官方认可。

上游的说明：欢迎 Fork。你可以依照开源许可研究、修改、移植和再分发代码；这些许可涵盖代码与数据，但不包括名称与图标。在个人 fork 中保留它们没有问题。如果要向他人发布构建版本，即使是免费的，也请换用自己的名称和图标。

---

觉得有用的话，点个 [⭐ Star](https://github.com/Shaojie66/spektralab-ai/stargazers)；想跟进上游的新版本，可以 [Watch 上游 Releases](https://github.com/JamesQiu2005/SpektraLab/releases)。

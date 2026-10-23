<p align="center">
  <img src="Serial%20Debug%20Tool/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="112" height="112" alt="Serial Debug Tool 应用图标">
</p>

<h1 align="center">Serial Debug Tool</h1>

<p align="center">
  <a href="README.md">English</a> · 简体中文
</p>

> 本项目完全由 Codex 完成，人类主要负责点击“继续”，以及偶尔指出：“这个按钮怎么又歪了？”

使用 Swift、SwiftUI 和 AppKit 开发的 macOS 原生串口调试工具。

## 下载使用

可以直接在本仓库的 [Releases](https://github.com/txgde-space/serial_debug_tool/releases) 页面下载 macOS 应用。解压 ZIP，将 **Serial Debug Tool.app** 拖入“应用程序”即可使用，无需安装 Xcode。

## 主要功能

- **多窗口**：按 **⌘N（Command + N）** 新建串口窗口，每个窗口拥有独立的连接、日志和发送草稿。
- **多命令预设**：保存多条常用命令、直接行内编辑，支持“单次发送”和可调间隔的“定时发送”。

## 从源码运行

在 Xcode 中打开 `Serial Debug Tool.xcodeproj`，选择 **Serial Debug Tool** Scheme 和 **My Mac** 后运行。选择串口、配置参数，点击“连接串口”即可开始。

支持 macOS 14 及以上版本。

> Built entirely by Codex. The human mostly clicked “Continue” — and occasionally asked, “Why is that button over there?”

# Serial Debug Tool

English · [简体中文](README.zh-CN.md)

A native macOS serial debugging app built with Swift, SwiftUI, and AppKit. A clean workspace for connecting devices, reading serial output, and sending commands.

## Download

Download the macOS app directly from [Releases](https://github.com/txgde-space/serial_debug_tool/releases). Extract the ZIP and move **Serial Debug Tool.app** to **Applications** — no Xcode required.

## Features

- **Serial connections** — Device discovery, manual port paths, custom baud rates, and configurable data bits, stop bits, parity, and flow control.
- **Text and HEX** — Send and view data in text or hexadecimal, with multiple character encodings and line endings.
- **Command presets** — Save commands, edit them inline, and choose between **Send Once** and **Repeat** with an adjustable interval.
- **Live output** — Search, timestamps, line wrapping, automatic scrolling, pause display, and independent RX/TX/SYS visibility.
- **Logs and counters** — Export logs and track received and transmitted bytes.
- **Multiple windows** — Work with separate devices in independent serial sessions.
- **Appearance and language** — Light, dark, or system appearance; English and Simplified Chinese, with a follow-system option.
- **Dock indicator** — A small green dot shows when a serial connection is active.

## Build from Source

Open `Serial Debug Tool.xcodeproj` in Xcode, select the **Serial Debug Tool** scheme and **My Mac**, then run. Choose a serial port, configure the connection, and click **Connect**.

Requires macOS 14 or later.

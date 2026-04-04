# audiobridge

**[English →](README_en.md)**

macOS 命令行小工具：把**采集端**实时音频接到**默认或指定输出**，或把 **s16le 交错 PCM** 写到 **stdout**（AVAudioEngine + Core Audio）。最低系统 **macOS 12**。

## 获取

- [Releases](https://github.com/ZhuzhuNo3/audiobridge/releases)：按芯片下载 `audiobridge-darwin-arm64` 或 `audiobridge-darwin-x86_64`，`chmod +x` 后放入 `PATH`。
- 源码编译：需 **Xcode Command Line Tools**。

```bash
git clone https://github.com/ZhuzhuNo3/audiobridge.git && cd audiobridge
make
./build/audiobridge --help
```

## 用法摘要

| 场景 | 命令 |
|------|------|
| 默认输入 → 默认输出（需显式 `-f`） | `audiobridge -f` |
| 设备列表 | `audiobridge --list-all` |
|  stdout PCM | `audiobridge -i "设备名" -o -`（可选 `-r 48000`） |

完整选项见 `./build/audiobridge --help`。

## 许可

[MIT](LICENSE)

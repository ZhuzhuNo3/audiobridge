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
| Speaker DEBUG 事件流 | `audiobridge -d -f`（`-q` 会覆盖 `-d`，全静默） |

完整选项见 `./build/audiobridge --help`。

## 运行期语义

- 启动阶段采用严格退出语义：首次管线启动失败时，进程直接退出，不进入重试循环。
- 仅在首次启动成功后才启用运行期补偿，此后遇到意外中断才会触发重建重试。
- Speaker 指定设备通过 Aggregate / 同双工 `CurrentDevice` 绑定；**不为跑通改写系统默认**。Aggregate 或绑定失败时以可观察错误退出。
- 指定端暂时不可用时进入配置等待态（引擎已停），等待期内不因 inactive 走 recovery 换源；恢复后由 `main` 再接入。
- 未指定端跟随系统默认变化时，由 `main` 重建 Aggregate/绑定（不是仅 endpoint rebuild）。
- 默认设备监听事件采用 80 ms 静默窗口防抖，突发路由抖动会被合并。
- 运行日志统一为 `YYYY-MM-DD HH:MM:SS.mmm  FILE:LINE  LEVEL  message`；`-d` 打开 DEBUG 事件流；`-q` / `--quiet` **覆盖** `-d`，有 `-q` 时无任何运行日志。无 30s 周期快照。

## 验证

- `sh tests/run_all.sh` 始终执行 `make -s test-unit`；仅在 `xcodebuild` 存在且可用时执行 `xcodebuild test -scheme audiobridge-tests` 并要求通过，否则输出确定性的 skip 原因并继续以 `make/test-unit` 路径作为证据。

## 许可

[MIT](LICENSE)

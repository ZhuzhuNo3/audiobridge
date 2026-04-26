# audiobridge

**[简体中文 →](README.md)**

Small **macOS CLI**: stream **live capture** to the **default or chosen output**, or write **interleaved s16le PCM** to **stdout** (AVAudioEngine + Core Audio). Requires **macOS 12+**.

## Get it

- [Releases](https://github.com/ZhuzhuNo3/audiobridge/releases): download `audiobridge-darwin-arm64` or `audiobridge-darwin-x86_64`, `chmod +x`, put on your `PATH`.
- Build from source: **Xcode Command Line Tools** required.

```bash
git clone https://github.com/ZhuzhuNo3/audiobridge.git && cd audiobridge
make
./build/audiobridge --help
```

## Quick reference

| Goal | Command |
|------|---------|
| Default input → default output (needs `-f`) | `audiobridge -f` |
| List devices | `audiobridge --list-all` |
| PCM to stdout | `audiobridge -i "name" -o -` (optional `-r 48000`) |

Run `./build/audiobridge --help` for all flags.

## Runtime semantics

- Startup uses strict-exit semantics: if the first pipeline start fails, the process exits without retry loops.
- Runtime compensation is enabled only after the first successful startup, and then unexpected stops can trigger rebuild retries.
- Default-device listener notifications are debounced with an 80 ms quiet window, so bursty route flips are coalesced into one recovery trigger.

## Verification

- `sh tests/run_all.sh` always runs `make -s test-unit`; it runs `xcodebuild test -scheme audiobridge-tests` only when `xcodebuild` is present and usable, otherwise prints a deterministic skip reason and continues.

## License

[MIT](LICENSE)

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
| Speaker DEBUG event stream | `audiobridge -d -f` (`-q` overrides `-d`; fully silent) |

Run `./build/audiobridge --help` for all flags.

## Runtime semantics

- Startup uses strict-exit semantics: if the first pipeline start fails, the process exits without retry loops.
- Runtime compensation is enabled only after the first successful startup, and then unexpected stops can trigger rebuild retries.
- Configured speaker devices bind via Aggregate / same-device duplex `CurrentDevice`; the process **does not rewrite system defaults** just to start audio. Aggregate or bind failures exit with an observable error.
- When a configured endpoint is temporarily unavailable, the process enters a config-wait state (engine stopped) and does not treat that inactive state as recovery/source switching; `main` reattaches when the endpoint returns.
- When an unspecified endpoint follows a system-default change, `main` rebuilds Aggregate/binding (not endpoint-only rebuild).
- Default-device listener notifications are debounced with an 80 ms quiet window so bursty route flips coalesce.
- Runtime logs use `YYYY-MM-DD HH:MM:SS.mmm  FILE:LINE  LEVEL  message`. `-d` enables the DEBUG event stream; `-q` / `--quiet` **overrides** `-d` and silences all runtime logs. There is no 30s periodic snapshot.

## Verification

- `sh tests/run_all.sh` always runs `make -s test-unit`; it runs `xcodebuild test -scheme audiobridge-tests` only when `xcodebuild` is present and usable, otherwise prints a deterministic skip reason and continues.

## License

[MIT](LICENSE)

# Rig + Swift PoC

A proof that [Rig](https://github.com/0xPlaygrounds/rig) can replace the Swift `LLMProvider`
surface and `JevClient`, on macOS and iOS, through UniFFI.

```
Swift executable / iOS app
  -> generated UniFFI bindings
  -> Rust `rig_poc` staticlib/cdylib
  -> Rig OpenAI-compatible client
  -> Command Code /provider/v1
```

## Proven surface

| Swift requirement | PoC mode | Live result |
|---|---|---|
| `chatText` | `swift run RigPoC "..."` | `rig swift poc ok` |
| `chatJSON` | `swift run RigPoC --json` | `{"ok":true}` |
| `embed` (OpenRouter) | `swift run RigPoC --embed ...` | 768-dim vectors |
| `chat(tools:)` | `swift run RigPoC --tools` | forced `web_search` call |
| tool result round-trip | `swift run RigPoC --tools-loop` | final answer using tool result |
| Jev `Noul` | `swift run RigPoC --jev ...` | probability `0.98` |
| Jev `Noul` + `Choice` + `Score` | `swift run RigPoC --jev-dynamic` | typed answer JSON |
| iOS app chat | simulator launch | `RIG_IOS_REPLY=rig ios ok` |
| iOS app Jev | simulator launch | `RIG_IOS_JEV=0.98` |
| Phoenix/OTLP from macOS | `RIG_POC_OTLP_ENDPOINT=...` | `chat` and `jev` LLM spans |
| Phoenix/OTLP from iOS | simulator launch | `chat` and `jev` LLM spans |

The iOS proof links an XCFramework containing device, arm64-simulator, and x86_64-simulator
slices, runs Tokio/Rig inside the app, and reaches Command Code over TLS.

## Requirements

- Rust 1.97.1 (pinned in `rust/rust-toolchain.toml`; Rig 0.45 MSRV)
- Xcode / Swift 5.9+
- `CMD_API_KEY`
- `OPENROUTER_API_KEY` for embeddings
- `xcodegen` for the iOS project

Optional:

- `RIG_POC_BASE_URL` (default `https://api.commandcode.ai/provider/v1`)
- `RIG_POC_MODEL` (default `xiaomi/mimo-v2.6-flash`)
- `RIG_POC_MAX_TOKENS` (default `8192`)
- `RIG_POC_EMBED_BASE_URL` (default `https://openrouter.ai/api/v1`)
- `RIG_POC_EMBED_MODEL` (default `baai/bge-base-en-v1.5`)
- `RIG_POC_JEV_ENDPOINT` (default `https://api.commandcode.ai/provider/v1/systemone`)
- `RIG_POC_JEV_MODEL` (default `typesafe/jev-1.14.0`)
- `JEV_TOKEN` for direct TypeSafe Jev; falls back to `CMD_API_KEY`
- `RIG_POC_OTLP_ENDPOINT` (for Phoenix: `http://localhost:6006/v1/traces`)
- `OTEL_SERVICE_NAME` (default `rig-swift-poc`)
- `RUST_LOG=rig=debug,rig_poc=debug` for Rig tracing

## macOS build and run

```bash
cd poc/rig-swift
./scripts/build.sh
cd swift

swift run RigPoC "Reply with exactly: rig swift poc ok"
swift run RigPoC --json
swift run RigPoC --embed "whole milk" "bananas"
swift run RigPoC --tools
swift run RigPoC --tools-loop
swift run RigPoC --jev \
  "Is this product perishable and typically stored in a refrigerator?" \
  '{"name":"Whole Milk","category":"Dairy"}'
swift run RigPoC --jev-dynamic
```

Trace to Phoenix:

```bash
RIG_POC_OTLP_ENDPOINT=http://localhost:6006/v1/traces \
OTEL_SERVICE_NAME=rig-poc \
  swift run RigPoC --json
```

Phoenix receives readable payloads on every span:

- `chat` input: `{"system": "...", "user": "...", "temperature": 0}` or the full
  messages/tools/forced-tool JSON
- `chat` output: the completion text, or `{"content": ..., "tool_calls": [...]}`
- `jev` input: `{"state": ..., "questions": ...}`
- `jev` output: `{"answers": ..., "model": ...}`
- `embeddings` input: `{"texts": [...]}`
- `embeddings` output: `{"count": 2, "dimensions": 768}`

The spans also carry `openinference.span.kind` (`LLM`/`EMBEDDING`), `llm.*`, and
`gen_ai.*` fields. Jev calls use an explicit span because `rig-typesafeai` does not
instrument itself.

`--jev-dynamic` sends a runtime question set:

```json
{
  "perishable": {"type":"noul","instructions":"Is this product perishable?"},
  "storage": {"type":"choice","instructions":"Where is this stored?",
    "criteria":{"fridge":"Refrigerated","pantry":"Shelf-stable"}},
  "days": {"type":"score","instructions":"How many days does it keep?",
    "criteria":["0 days","1-2 days","3-4 days","5-7 days","8-14 days"]}
}
```

Live result:

```text
answers={"days":{"type":"score","score":3.2,...},"perishable":{"type":"noul","noul":0.98},"storage":{"type":"choice","choice":"fridge",...}}
```

## iOS build and run

```bash
cd poc/rig-swift
./scripts/build.sh          # generates the UniFFI header/Swift and macOS dylib
./scripts/build-ios.sh      # device + simulator static libs -> RigPoc.xcframework

cd ios
xcodegen generate
xcodebuild -project RigPoCiOS.xcodeproj -scheme RigPoCiOS \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Runtime check against a booted simulator:

```bash
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/RigPoCiOS.app
SIMCTL_CHILD_CMD_API_KEY="$CMD_API_KEY" \
SIMCTL_CHILD_RIG_POC_OTLP_ENDPOINT=http://127.0.0.1:6006/v1/traces \
SIMCTL_CHILD_OTEL_SERVICE_NAME=rig-ios-poc \
SIMCTL_CHILD_RIG_EXIT_AFTER_CALL=1 \
  xcrun simctl launch --console --terminate-running-process \
  booted com.example.RigPoCiOS
```

Observed:

```text
RIG_IOS_OTLP=http://127.0.0.1:6006/v1/traces
RIG_IOS_REPLY=rig ios ok
RIG_IOS_JEV=0.98 model=typesafe/jev-1.14.0
```

Phoenix query after both runs shows `chat` and `jev` spans with `span_kind=LLM`:

```text
5307  chat  LLM  ...
5308  jev   LLM  ...
```

Local spans land in Phoenix's `default` project.

## Current limits

- The PoC uses a simple span exporter (export on span end) so short-lived processes flush
  deterministically. Production should use a batch exporter with an explicit Tokio runtime.
- Tool execution still lives in Swift. The PoC proves tool calls and tool-result messages
  round-trip, not a Rust-owned agent loop.
- Rig is pre-1.0; version and `Cargo.lock` are pinned.

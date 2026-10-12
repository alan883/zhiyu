<p align="center">
  <img src="art/icon_1024.png" width="128" alt="指语 Zhiyu icon">
</p>

# 指语 Zhiyu

**Point. Speak. Done.** Voice input for macOS. Hover over any text field, speak, and the text appears there.

[中文说明](README.zh-CN.md)

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M--series-black)
![License MIT](https://img.shields.io/badge/License-MIT-green)
![100% local audio](https://img.shields.io/badge/audio-100%25%20local-brightgreen)

## Why Zhiyu

The author used three tools and none did everything:

- Handy is open source, fast, local, and private. It has little AI cleanup.
- Typeless has AI cleanup and an auto-learning dictionary. It is cloud-only and paid.
- Doubao IME shows text instantly, then corrects itself.

None of them lets you dictate into the text box under your mouse without clicking it first.

Zhiyu has three goals: fast, accurate, and fluent. It is free. All audio stays on your Mac.

## Highlights

- **Point and speak.** Hover over a field, hold the hotkey, and speak. The text goes into that field.
- **Local speech recognition.** Recognition runs on your Mac with MLX. Median time to text on screen is about 0.8 s in real use.
- **Two-pass output.** Text appears at once. The polished version replaces it in place 1 to 3 s later (native apps).
- **Pinyin-fuzzy dictionary.** Your dictionary words fix sound-alike errors. For example, 子语 and 直雨 become 指语.
- **Learns from your edits.** It learns from your manual corrections and from what you submit in Claude Code.
- **Voice edit.** Select text, hold the hotkey, and say "make it formal" or "translate to English".
- **Full offline mode.** Recognition, polishing, voice edit, and learning run only on your Mac.

## How it works

```
 hold hotkey / trackpad force-click
          │
          ▼
 capture audio (Audio.swift)
          │
          ▼
 local ASR server, MLX, 127.0.0.1:8776 (asr_server.py)
          │
          ▼
 pinyin dictionary correction (phonetic.py)
          │
          ▼
 polish: Fast (rules) | Smart (cloud LLM) | Local (Qwen3 4B)
          │
          ▼
 insert into the field under the mouse (AXTarget.swift)
          │
          ▼
 learn from corrections (learner.py)
```

## Features

### Input

- Point and speak: hover over any text field, hold the hotkey, speak, and release. The hotkey defaults to Right Option. You can choose any key or modifier. F-keys are recommended.
- Force-click the trackpad as an alternative to the hotkey.
- Hands-free: double-tap the hotkey to keep recording. Press once more to stop.
- Mic awareness: shows the current microphone (built-in, wired headset, or Bluetooth). It rebuilds the audio pipeline when you plug or unplug headphones.

### Recognition and correction

- Local speech recognition. The default model is Qwen3-ASR 0.6B 4-bit (MLX). It handles mixed Chinese and English and adds punctuation. It takes about 0.6 s per sentence on an M1.
- Pinyin-fuzzy dictionary correction. It fixes sound-alike words in your dictionary and leaves real words alone. It takes about 27 ms for 300 characters against 300 terms.
- Self-learning personal dictionary. It learns from three sources:
  - Your manual corrections. It re-reads the text field at 8 s and 45 s.
  - What you submit in Claude Code (`~/.claude/history.jsonl`).
  - Optional AI review.
- A correction must be seen twice before the app uses it.
- You can delete any entry in the Dictionary page. Deleted entries are not learned again.

### Polishing

- Three modes:
  - **极速 Fast:** local rules only. Instant.
  - **智能 Smart:** cloud LLM through any OpenAI-compatible provider.
  - **本地精修 Local:** Qwen3 4B on your Mac. About 3 s.
- Polishing removes fillers (呃, 嗯, um, uh), fixes punctuation and homophones, and keeps only the corrected version when you correct yourself mid-sentence.
- Two-pass output: text appears at once, and the polished version replaces it in place. This works in native apps only. See "How it was built".
- Per-app style: casual for chat apps (WeChat, Slack, Telegram), formal for mail, and technical for terminals and IDEs. Technical style keeps commands and file names. You can edit the style for each app.
- Auto-send: say "发送", "回车", "发出去", or "send it" at the end of a sentence to press Enter. The app ignores phrases such as "我想发送邮件".

### Editing

- Voice edit: select text, hold the hotkey, and give an instruction. The selection is replaced in place.

### App and UI

- macOS 26 and 27 Liquid Glass design.
- Landscape window with a sidebar: Overview, Settings, Models, Dictionary, History.
- Built-in history search and copy.
- The Overview page shows where each step runs.

### Safety

- Never types into password fields.
- Warns when Secure Input blocks the hotkey.
- Saves failed recordings to `~/.config/zhiyu/failed` instead of losing them.

## Privacy

- Audio never leaves your Mac.
- Only text goes to a cloud LLM. This happens only if you configure one and you do not enable offline mode.
- API keys are stored in the macOS Keychain.
- All app data lives in `~/.config/zhiyu`.

## Install

Requirements:

- Apple Silicon Mac, macOS 15 or later
- Xcode Command Line Tools (`swiftc`)
- Python 3.12
- [uv](https://docs.astral.sh/uv/)

Build from source. Clone this repository, then run:

```sh
git clone <this repository> ~/zhiyu
cd ~/zhiyu
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -r requirements.txt
./build.sh            # builds, signs, installs /Applications/指语.app
open /Applications/指语.app
```

Notes:

- The app expects the project folder at `~/zhiyu`. To use another folder, set the environment variable `ZHIYU_HOME`.
- Optional: to keep permissions across rebuilds, create a self-signed code-signing certificate named "Zhiyu Local Signing" in Keychain Access (Certificate Assistant, then Create a Certificate, then Code Signing type). `build.sh` uses it automatically. Without it, `build.sh` signs ad-hoc. macOS may then ask for permissions again after each rebuild.

## First run

1. Open the app. Grant **Accessibility** and **Microphone** permission when asked.
2. Open the **Models** page and download the default speech model (about 0.7 GB).
3. Hover over a text field, hold the hotkey, and speak.

## Models

Download and enable these tested models from the Models page with one click:

- Qwen3-ASR family (default: Qwen3-ASR 0.6B 4-bit, MLX)
- SenseVoice Small
- GLM-ASR Nano
- Local polish model: Qwen3-4B-Instruct

The Models page has an optional China mirror (hf-mirror.com).

Import your own model from a Hugging Face repo or a local folder. The model must follow these rules:

- MLX format.
- The folder must contain `config.json` and `*.safetensors`.
- GGUF, PyTorch `.bin`, and ONNX models are not supported.

A failed model never replaces the working one.

## Cloud polishing

Smart mode works with these presets:

- DeepSeek
- OpenAI
- OpenRouter
- SiliconFlow
- Alibaba Bailian
- Ollama
- Any OpenAI-compatible endpoint

Setup:

- Store the API key in the macOS Keychain.
- Use the "Test connection" button to check the endpoint.
- Add custom request headers with `llm_headers` in `config.json`, if your provider needs them.
- Reasoning models can spend the whole output budget on "thinking". DeepSeek hosts get `"thinking":{"type":"disabled"}` automatically. For other gateways that accept this field, set `"llm_disable_thinking": true` in `config.json`.

Faithfulness guard: the app rejects any polish that adds English words you did not say, drops a negation or a number, or changes too much.

## Comparison

Public information as of October 2026. Competitor facts come from vendor pages and reviews. `?` means unknown. `partial` means limited support.

| | 指语 Zhiyu | Typeless | Wispr Flow | Superwhisper | VoiceInk | Handy |
|---|---|---|---|---|---|---|
| Price | Free (MIT) | from $12/mo | from $12/mo | ~$85/yr | $25 once | Free |
| Local recognition | ✓ | ✗ | ✗ | ✓ | ✓ | ✓ |
| Type where the mouse points | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ |
| Fix text after it appears | ✓ (native apps) | ✗ | ✗ | ✗ | ✗ | ✗ |
| Pinyin fuzzy dictionary | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ |
| Learns from your edits | ✓ | partial | ? | ✗ | ? | ✗ |
| Voice edit of selection | ✓ | ✓ | ? | ? | ✓ | ✗ |
| Per-app styles | ✓ | ✓ | partial | ✓ | ✓ | ✗ |
| Mobile app | ✗ | ✓ | ✓ | ✓ | ✗ | ✗ |

## How it was built

Zhiyu was built in one long session. The author directed an AI coding assistant (Claude). The lead model planned and integrated the work. Several smaller sub-agent models wrote individual files. The lead model compiled and tested every change before install.

The design came from measurements, not guesses. Six decisions shaped the app:

1. **Noise suppression made accuracy worse.** We tested DeepFilterNet before recognition. Clean audio got 8.6% more character errors. Babble noise at 5 dB raised errors from 22% to 41%. We dropped it. An anti-hallucination guard now stops runaway repeated output in very noisy rooms.
2. **A local 4B LLM was slower than the cloud.** The median was 2.8 s locally and about 1.3 s in the cloud. Polishing now has three modes. It also shows the text first and fixes it after.
3. **A cloud LLM changed the meaning.** One model rewrote "Fable 5.1" as its own name and deleted half a sentence. The faithfulness guard now rejects those changes.
4. **Backspace edits broke in terminals.** The first "fix after it appears" version used Backspace keystrokes. In terminal apps such as Claude Code, many keystrokes were dropped and text was duplicated. The rule is now: never edit text that cannot be verified. Native apps get a verified in-place replacement through Accessibility. Terminals, browsers, and Electron apps wait up to 1.2 s for the polish, then type the text once.
5. **The built-in MacBook microphone was unreliable with Apple's voice processing.** "Noisy environment mode" is now opt-in. It falls back automatically.
6. **Only tested models are listed.** A model appears in the download list only after it loads and transcribes on the test Mac.

## Limitations and roadmap

Limitations:

- macOS and Apple Silicon only. There is no iPhone app yet.
- No dialect support beyond what the chosen model offers. SenseVoice supports Cantonese.
- Fix-after-insert works only in native apps. This is by design.

Roadmap:

- iPhone app
- File transcription
- Live word-by-word preview

## Project layout

| Path | Purpose |
|---|---|
| `Sources/main.swift` | Pipeline |
| `Sources/Trigger.swift` | Hotkey, trackpad, hands-free |
| `Sources/AXTarget.swift` | Find field, insert text, verified replace |
| `Sources/Audio.swift` | Audio capture |
| `Sources/Clients.swift` | Config, polish, guards |
| `Sources/DeviceInfo.swift` | Microphone info |
| `Sources/MainWindow.swift`, `OverviewPane`, `SettingsPane`, `ModelsPane`, `DictionaryPane`, `HistoryPane` | UI |
| `asr_server.py` | Local MLX server on 127.0.0.1:8776 |
| `phonetic.py` | Pinyin correction |
| `learner.py` | Dictionary learning |
| `build.sh` | Build, sign, install |
| `art/` | Icon generator |

## Credits

- Handy by cjpais (MIT). Inspiration for pre-roll, hold-or-toggle, and filler rules.
- CapsWriter-Offline by HaujetZhao. The pinyin hot-word matching idea.
- mlx-audio and mlx-lm, from the Apple MLX community.
- Models: Qwen3-ASR (Alibaba Qwen), SenseVoice (FunAudioLLM), GLM-ASR (Zhipu), Qwen3-4B-Instruct.

## License

MIT.

<p align="center"><img src="docs/icon.png" width="128" alt="Flow"></p>

<h1 align="center">Flow</h1>
<p align="center"><b>Talk to your Mac.</b> An on-device voice agent built on Liquid AI's LFM2.5 models.</p>

Hold a key, speak, let go. Flow transcribes you with **LFM2.5-Audio-1.5B**, understands what you meant with
**LFM2.5-2.6B**, and acts: answers questions from your own memories and the web, sets and edits reminders, writes
emails into the field you're in, opens apps, and transcribes meetings into notes and commitments. Speech
recognition, the agent and memory search all run locally through llama.cpp.

<p align="center"><img src="docs/working-card.png" width="420" alt="Flow's bottom popup, showing its research steps"></p>

## What it does

| Hold **⌃ Control** and say… | Flow |
|---|---|
| "Remember Marcus from Acme prefers email" | saves a memory (only when you say *remember*) |
| "What do I know about the Acme deal?" | searches memories, meetings, reminders and emails it wrote, reasons over what it found, answers, and shows its steps live |
| "Who won the Champions League last year?" | searches the web |
| "Remind me to send the proposal Thursday at 3pm" · "Actually make it 5" | creates the reminder, then moves it |
| "Write an email here telling Kevin my submission is in" | composes it and types it into the focused field |
| "Email Priya asking for the signed contract" | drafts it in Mail (never sends) |
| "Insert: running ten minutes late" | types exactly that |
| "Open Spotify" · "Click the send button" | acts on your Mac |
| "Update my memory about Marcus, his email changed" · "Forget where I parked" | edits or deletes memories |

- **Double-tap ⌃** to start or stop transcribing a meeting. You get a summary, decisions, and your commitments as suggested reminders.
- **Hold ⌥ Option** to dictate: plain transcription pasted where your cursor is, with no agent involved.
- **Multi-step conversation:** follow-ups like "and tomorrow?", "make it 3pm" or "just that, nothing else" are resolved against the last 15 turns.
- **Calendar** (week view) and **Feed** of everything Flow did, with editable reminders and memories.
- **System Prompt** tab: edit the personality and every instruction Flow gives the model.
- **Tools & Permissions:** set each tool to *Always*, *Ask first* or *Off*.

## Requirements

- Apple Silicon Mac, macOS 14 or later, 16 GB RAM recommended
- Xcode Command Line Tools (Swift 5.9+): `xcode-select --install`
- [Homebrew](https://brew.sh) and llama.cpp: `brew install llama.cpp`
- ~3.6 GB of disk space for the models

## Install

```bash
git clone https://github.com/james-pratama/flow-by-liquid.git
cd flow-by-liquid
scripts/download-models.sh             # LFM2.5 GGUFs from Hugging Face → ~/Library/Application Support/Flow/models
scripts/create-signing-identity.sh     # optional, recommended: keeps macOS permissions across rebuilds
scripts/build-app.sh --open            # builds, installs /Applications/Flow.app, opens it
```

On first launch Flow opens **Tools & Permissions**. Grant:

- **Microphone** and **Input Monitoring** (required; without Input Monitoring the hotkeys only work while Flow is in front)
- **Accessibility** to type and press buttons for you
- **Screen & System Audio Recording** to capture the other side of calls
- **Calendars** to see your meetings
- **Location** for "near me" answers

If a permission won't stick, make sure only one Flow.app exists, then reset it with
`tccutil reset All ai.liquid.flow` and grant again.

Optional: add a [Brave Search](https://brave.com/search/api/) API key in **Settings → Web search** for full web
results. Without one, Flow uses DuckDuckGo's HTML results and falls back to Wikipedia.

## How it works

```
hotkey ─► mic (16 kHz) ─► LFM2.5-Audio (ASR, :8182)
       ─► conversation resolver (follow-ups → self-contained request)
       ─► router: one constrained LFM2.5-2.6B call (:8181) + deterministic harness corrections
       ─► tools (policy + permission checks) ─► SQLite entry ─► bottom card
```

- **Router harness** (`Engine/Router.swift`): LFM2.5-2.6B is a reasoning model. Flow builds the ChatML prompt itself, prefills an empty `<think></think>` for speed, and constrains the output with a JSON schema. The model first picks a descriptive *kind*, and the schema then only allows that kind's tools. Deterministic rules fix known failure modes; for example, a call is dropped when its trigger words were never spoken.
- **Questions** (`Tools/QuestionTool.swift`) run a small agent loop: memory search → planner picks the next step (search again, files, web, or answer) → the model's own reasoning over the findings → answer. Each step appears live on a card.
- **Memory** (`Store/`): SQLite with FTS5 plus LFM2.5-Embedding-350M vectors, fused with reciprocal-rank fusion. `MemoryProvider` is the interface to swap in synced or OEM storage.
- **Dates** are never computed by the model. It copies the spoken phrase, and `DateResolver` does the calendar math.

### Evals

```bash
swift build
.build/debug/Flow --eval evals/router_cases.jsonl     # tuning set
.build/debug/Flow --eval evals/router_holdout.jsonl   # held out
```

On an M-series Mac with Q4_K_M: **100%** on the tuning set (57 cases) and **~92–96%** on the held-out set. Routing takes about 500 ms p50; speech recognition adds about 100–200 ms.

Other headless commands, handy for development (`FLOW_HOME` points data at a scratch folder; `FLOW_DRY_RUN=1` stops tools from touching your apps):

```bash
FLOW_DRY_RUN=1 FLOW_HOME=/tmp/flow .build/debug/Flow --handle "remind me to call Sam at 4pm"
.build/debug/Flow --route "open spotify" [--focused]
.build/debug/Flow --asr recording.wav
.build/debug/Flow --ask "where did I park?"
.build/debug/Flow --meeting transcript.txt "Acme call"     # lines like "Me: …" / "Them: …"
.build/debug/Flow --meeting-sim call.wav                   # plays audio through the real meeting recorder
```

`scripts/run-servers.sh` keeps the three model servers warm across rebuilds; Flow reuses healthy servers on ports 8181–8183.

## Project layout

| Folder | Contents |
|---|---|
| `App/` | App delegate, menu bar, settings, editable prompts |
| `Capture/` | Hotkeys (talk / dictate / double-tap), mic, system audio, focus + Accessibility helpers |
| `Engine/` | Model servers, LLM client, ASR, router + prompt, conversation resolver, dates, location, pipeline |
| `Tools/` | Memory, reminders, questions, write-here, paste, open app, press button, Mail drafts, meetings |
| `Store/` | SQLite, search index, memory provider |
| `Scheduler/` | Reminder firing, calendar watcher, meeting recorder and notes |
| `Overlay/` | Bottom pill and stacked cards with countdowns and live steps |
| `UI/` | Calendar, Feed, System Prompt, Tools & Permissions, Settings, theme, logo |

## Credits and licenses

- Code: [MIT](LICENSE).
- Models: [Liquid AI](https://www.liquid.ai) LFM2.5 family, downloaded separately from Hugging Face under the
  [LFM Open License](https://huggingface.co/LiquidAI/LFM2.5-2.6B/blob/main/LICENSE). They aren't included in this repo.
- The Liquid name and logo are trademarks of Liquid AI.
- Runs on [llama.cpp](https://github.com/ggml-org/llama.cpp).

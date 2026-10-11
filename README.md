<p align="center"><img src="docs/icon.png" width="128" alt="Smiley"></p>

<h1 align="center">Smiley</h1>
<p align="center"><b>Talk to your Mac.</b> An on-device voice agent for macOS.</p>

Hold a key, speak, let go. Smiley transcribes you with **Qwen3-ASR-1.7B**, works out what you meant with a small,
fast model (**Qwen3.5-4B**), hands answers and writing to a larger one (**Qwen3.5-9B**), and acts: answers questions from your own memories and the web, sets and edits reminders, writes
emails into the field you're in, opens apps, and transcribes meetings into notes and commitments. Speech
recognition, the agent and memory search all run locally through llama.cpp.

<p align="center"><img src="docs/working-card.png" width="420" alt="Smiley's bottom popup, showing its research steps"></p>

## What it does

| Hold **⌃ Control** and say… | Smiley |
|---|---|
| "Remember Marcus from Acme prefers email" | saves a memory (only when you say *remember*) |
| "What do I know about the Acme deal?" | searches memories, meetings, reminders and emails it wrote, reasons over what it found, answers, and shows its steps live |
| "Who won the Champions League last year?" | searches the web |
| "Remind me to send the proposal Thursday at 3pm" · "Actually make it 5" | creates the reminder, then moves it |
| "Write an email here telling Kevin my submission is in" | composes it and types it into the focused field |
| "Email Priya asking for the signed contract" | drafts it in Mail (never sends) |
| "Insert: running ten minutes late" | types exactly that |
| "Open Spotify" · "Click the send button" | acts on your Mac |
| "Play Only Time by Enya" · "Open my roadmap page in Notion" · "Ask Claude to explain DNS" | acts inside your apps (see [App control](#app-control)) |
| "Update my memory about Marcus, his email changed" · "Forget where I parked" | edits or deletes memories |

- **Double-tap ⌃** to start or stop transcribing a meeting. You get a summary, decisions, and your commitments as suggested reminders.
- **Hold ⌥ Option** to dictate: plain transcription pasted where your cursor is, with no agent involved.
- **Desktop pet:** Smiley, a pink felt cushion with red boots, lives on your desktop. Click it to talk and click again
  when you're done. Hover it and a "Type" chip appears underneath; click that and it opens into a text field, so you can
  type a request instead of saying it (Return sends, Esc closes). It watches your pointer, holds its hands out while it
  listens, gets to work while it thinks, and reacts to the result. Drag it anywhere (it runs along); hide it from its
  right-click menu, the menu bar or Settings.
- **Multi-step conversation:** follow-ups like "and tomorrow?", "make it 3pm" or "just that, nothing else" are resolved against the last 15 turns.
- **Calendar** (week view) and **Feed** of everything Smiley did, with editable reminders and memories.
- **System Prompt** tab: edit the personality and every instruction Smiley gives the model.
- **Tools & Permissions:** set each tool to *Always*, *Ask first* or *Off*.

## App control

Smiley can act inside your apps, not just open them. Say what you want (naming the app helps, e.g. "…on Spotify",
"…in Chrome") and Smiley picks the matching action.

### Built-in actions

| App | Actions | Say, for example |
|---|---|---|
| **Spotify** | play a song, album, artist, playlist or genre by name · play your own playlists or Liked Songs · resume · pause · next · previous · volume (level, up, down, mute) · shuffle on/off · repeat on/off · what's playing | "Play Only Time by Enya" · "Play my Work playlist" · "Skip this song" · "Turn it down" · "What song is this?" |
| **Notion** | open a page by name · search · new page (with title and text) · back · forward · show/hide sidebar · copy page link · new tab · light/dark mode | "Open my roadmap page in Notion" · "Make a new page called Meeting notes" · "Hide the sidebar" |
| **Claude** | ask (new chat, types and sends your message; "ask Claude about this" includes your selected text) · new chat | "Ask Claude to explain how DNS works" · "Have Claude summarize this" |
| **Mail** | check for new mail · unread summary (count and senders) · reply to the selected email (drafted, **never sent**) · search | "Do I have any unread emails in Mail?" · "Reply to this email saying I'll be there at noon" |
| **Google Chrome** | open a site in a new tab · Google search · switch to an open tab by name · new tab · close tab · reload · back · forward · incognito window · copy page link | "Go to github.com" · "Switch to my Gmail tab" · "Google flights to Tokyo" |
| **Notes** | create a note (title and text) · add to an existing note · open a note | "Create a note in Notes called packing list with passport and charger" · "Add bread to my groceries note" |
| **Whatever is playing** | play/pause · next · previous (media keys, any player) | "Pause" · "Next" |

### Discovered on your Mac

Beyond the built-in actions, Smiley finds more on its own:

- **Menu commands** of the app in front, e.g. "toggle the sidebar", "new window", "zoom in". Every Mac app has these,
  native or Electron.
- **AppleScript commands** that take no arguments, from every scriptable app installed (Music, TV, QuickTime,
  Photos, Keynote…), e.g. "next track in Music", "new screen recording".
- **Your Shortcuts**, e.g. "run my Make GIF shortcut". Anything the Shortcuts app can do, Smiley can trigger.

Run `.build/debug/Smiley --apps` to list every action available on your Mac.

### Safety

- Commands that delete, send, quit or sign out ask first.
- Mail replies and drafts are never sent.
- Smiley never launches an app you didn't name just to run one of its commands.
- AppleScript gets your words as arguments; they're never pasted into scripts.

### Limits

- **Spotify without an API key** reads Spotify's window: it presses play on Spotify's top result, which Spotify
  personalizes (name the artist when it matters), and it finds only playlists visible in your library sidebar. It
  expects Spotify's interface in English.
- **Notion and Claude** aren't scriptable, so Smiley drives them with their keyboard shortcuts; an app update that
  changes a shortcut can break an action.
- Queue, saving songs, adding to playlists and choosing a speaker need a Spotify login, which isn't built yet.

## Requirements

- Apple Silicon Mac, macOS 14 or later, 16 GB RAM recommended
- Xcode Command Line Tools (Swift 5.9+): `xcode-select --install`
- [Homebrew](https://brew.sh) and llama.cpp: `brew install llama.cpp`
- ~12 GB of disk space for the models, and about 16 GB of memory free for them while Smiley runs

## Install

```bash
git clone https://github.com/james-pratama/flow-by-liquid.git
cd flow-by-liquid
scripts/download-models.sh             # Qwen GGUFs from Hugging Face → ~/Library/Application Support/Smiley/models
scripts/create-signing-identity.sh     # optional, recommended: keeps macOS permissions across rebuilds
scripts/build-app.sh --open            # builds, installs /Applications/Smiley.app, opens it
```

On first launch Smiley opens **Tools & Permissions**. Grant:

- **Microphone** and **Input Monitoring** (required; without Input Monitoring the hotkeys only work while Smiley is in front)
- **Accessibility** to type and press buttons for you
- **Screen & System Audio Recording** to capture the other side of calls
- **Calendars** to see your meetings
- **Location** for "near me" answers

If a permission won't stick, make sure only one Smiley.app exists, then reset it with
`tccutil reset All com.jamespratama.smiley` and grant again.

Optional: add a [Brave Search](https://brave.com/search/api/) API key in **Settings → Web search** for full web
results. Without one, Smiley uses DuckDuckGo's HTML results and falls back to Wikipedia.

Optional: add a Spotify client ID and secret (create a free app at [developer.spotify.com](https://developer.spotify.com/dashboard))
in **Settings → Spotify** so "play <song>" starts the exact track. Without them, Smiley opens Spotify's search and presses
play on the top result (Spotify personalizes that ranking, so name the artist — "Only Time by Enya" — when it matters).
"Play my Work playlist" and "play my Liked Songs" play from your library sidebar either way.

The first time Smiley controls an app through AppleScript, macOS asks you to allow it (**Privacy & Security → Automation**).

## How it works

```
hotkey ─► mic (16 kHz) ─► Qwen3-ASR (speech, :8192)
       ─► conversation resolver (follow-ups → self-contained request)
       ─► router: one constrained Qwen3.5-4B call (:8191) + deterministic harness corrections
       ─► tools (policy + permission checks; answers, writing and notes use Qwen3.5-9B, :8194)
       ─► SQLite entry ─► bottom card
```

- **Router harness** (`Engine/Router.swift`): Qwen3.5 is a reasoning model. Smiley builds the ChatML prompt itself, prefills an empty think block for speed, and constrains the output with a JSON schema. The model first picks a descriptive *kind*, and the schema then only allows that kind's tools. Deterministic rules fix known failure modes; for example, a call is dropped when its trigger words were never spoken.
- **App control** (`Tools/AppCatalog.swift`, `Tools/CuratedApps.swift`): the router only decides that something should happen
  *inside* an app (`app_action(app, request)`). A catalog search narrows every action Smiley knows to 8 candidates
  (embeddings + keywords), and a second constrained call picks one and fills its arguments; the schema allows only
  those 8 or "none". The catalog has two parts:
  - **Curated** actions for Spotify, Notion, Claude, Mail, Google Chrome and Notes (plus media keys), which can
    chain steps, e.g. search Spotify → play the exact track.
  - **Discovered** actions, found on your Mac automatically: parameterless AppleScript commands from every scriptable
    app, every item in the front app's menu bar, and your Shortcuts.

  Commands that delete, send, quit or sign out ask first. AppleScript values are passed as `argv`, never spliced
  into scripts.
- **Questions** (`Tools/QuestionTool.swift`) run a small agent loop: memory search → planner picks the next step (search again, files, web, or answer) → the model's own reasoning over the findings → answer. Each step appears live on a card.
- **Memory** (`Store/`): SQLite with FTS5 plus Qwen3-Embedding-0.6B vectors (served on :8193), fused with reciprocal-rank fusion. `MemoryProvider` is the interface to swap in synced or OEM storage.
- **Dates** are never computed by the model. It copies the spoken phrase, and `DateResolver` does the calendar math.

### Evals

```bash
swift build
.build/debug/Smiley --eval evals/router_cases.jsonl     # tuning set
.build/debug/Smiley --eval evals/router_holdout.jsonl   # held out
.build/debug/Smiley --app-eval evals/app_cases.jsonl    # app control: does the request pick the right action?
```

Measured on an M5 Pro (48 GB): **100%** on the tuning set (67 cases), **93–96%** on the held-out set, and **100%**
on the 43 app-control cases (the action pick adds about 0.5 s). Routing takes about 0.65 s p50, speech recognition
0.2–0.4 s for a short command, and the larger model writes about 45 tokens a second.

Other headless commands, handy for development (`SMILEY_HOME` points data at a scratch folder; `SMILEY_DRY_RUN=1` stops tools from touching your apps):

```bash
SMILEY_DRY_RUN=1 SMILEY_HOME=/tmp/smiley .build/debug/Smiley --handle "remind me to call Sam at 4pm"
.build/debug/Smiley --route "open spotify" [--focused]
.build/debug/Smiley --apps [filter]                          # every app action Smiley knows on this Mac
SMILEY_DRY_RUN=1 .build/debug/Smiley --app "skip this song" Spotify   # which action a request picks
.build/debug/Smiley --asr recording.wav
.build/debug/Smiley --ask "where did I park?"
.build/debug/Smiley --meeting transcript.txt "Acme call"     # lines like "Me: …" / "Them: …"
.build/debug/Smiley --meeting-sim call.wav                   # plays audio through the real meeting recorder
```

`scripts/run-servers.sh` keeps the four model servers warm across rebuilds; Smiley reuses servers on ports 8191–8194 when they hold the right model.

## Project layout

| Folder | Contents |
|---|---|
| `App/` | App delegate, menu bar, settings, editable prompts |
| `Capture/` | Hotkeys (talk / dictate / double-tap), mic, system audio, focus + Accessibility helpers |
| `Engine/` | Model servers, LLM client, ASR, router + prompt, conversation resolver, dates, location, pipeline |
| `Tools/` | Memory, reminders, questions, write-here, paste, open app, press button, Mail drafts, meetings, app control (catalog, curated apps, AppleScript / keys / menus / Shortcuts) |
| `Store/` | SQLite, search index, memory provider |
| `Scheduler/` | Reminder firing, calendar watcher, meeting recorder and notes |
| `Overlay/` | Bottom pill and stacked cards with countdowns and live steps |
| `Pet/` | The desktop pet: floating panel, click / drag / hover handling, sprite animation, input bar. Its artwork is `Resources/Pet/` (sprite atlas + manifest) |
| `UI/` | Calendar, Feed, System Prompt, Tools & Permissions, Settings, theme, logo |

## Credits and licenses

- Code: [MIT](LICENSE).
- Models: [Qwen](https://huggingface.co/Qwen) (Qwen3.5-4B, Qwen3.5-9B, Qwen3-ASR-1.7B, Qwen3-Embedding-0.6B), Apache 2.0,
  downloaded separately from Hugging Face. They aren't included in this repo.
- Runs on [llama.cpp](https://github.com/ggml-org/llama.cpp).

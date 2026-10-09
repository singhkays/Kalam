<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/quill-logo-dark.png">
    <img src="assets/quill-logo.png" width="84" alt="Kalam">
  </picture>
</p>

<h1 align="center">Speak messy. Type clean <em>(privately)</em>.</h1>

<p align="center">
  A dictation app that knows &ldquo;um&rdquo; isn&rsquo;t a word and &ldquo;scratch that&rdquo; is an instruction.
</p>

<p align="center">
  <img src="assets/readme/hero-indicator.png" alt="The Kalam recording indicator moving through its states: a live waveform while listening, the meter dropping while you pause, then transcribing." width="620">
</p>

<p align="center">
  <a href="https://github.com/singhkays/Kalam/releases/latest"><img alt="macOS 14.6 or later" src="https://img.shields.io/badge/macOS-14.6%2B-000000?logo=apple&logoColor=white"></a>
  <img alt="MIT licensed" src="https://img.shields.io/badge/license-MIT-1A5C3A.svg">
  <img alt="Runs fully on device" src="https://img.shields.io/badge/audio-100%25%20on--device-1A5C3A.svg">
  <a href="https://github.com/singhkays/Kalam/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/singhkays/Kalam?label=release&color=1A5C3A"></a>
</p>

<p align="center">
  <a href="https://github.com/singhkays/Kalam/releases/latest"><strong>Download for macOS</strong></a>
  &nbsp;&middot;&nbsp;
  <a href="#install--first-run">Setup takes about two minutes</a>
  &nbsp;&middot;&nbsp;
  <a href="https://github.com/singhkays/Kalam">Source</a>
</p>

---

## Why Kalam

Most dictation apps hand you the raw transcript and make you clean it up yourself. Kalam cleans it as it transcribes, so the text that lands in your app is already written.

- **Editing.** `um` and `uh` come out, `scratch that` deletes the clause before it, and a spoken list arrives formatted.
- **Vocabulary.** A personal dictionary rewrites the words you mispronounce and the names only you use.
- **Privacy.** No network entitlement sits in the app bundle, so the app cannot open a connection.

## What it actually does

Every row below is real output from the cleanup engine.

| | You say | Kalam types |
|---|---|---|
| **Fillers** | `um I think uh we should ship it on Friday` | `I think we should ship it on Friday` |
| **Backtracks** | `send the invoice today scratch that send it next Monday` | `send it next Monday` |
| **Spoken lists** | `the plan is one gather logs two isolate the bug three ship the fix` | `the plan is`<br>`1. gather logs`<br>`2. isolate the bug`<br>`3. ship the fix` |
| **Punctuation** | `hello ,world!!this is fine` | `hello, world! this is fine` |
| **Your dictionary** | `my iphone broke` | `my iPhone broke` |

Fillers are removed as whole words, so `mum` and `aluminum` survive. Kalam checks a spoken list before formatting it, so a stray number won't scramble it.

Two more features are off by default and run on-device: converting spoken numbers and dates to written form, and a grammar pass.

## Works wherever you can type

Kalam types into whatever is focused. Slack, Notion, Xcode, Terminal, email, browsers, code editors &mdash; anywhere there's a caret.

<p align="center">
  <img src="assets/readme/settings-map.png" alt="The Kalam settings window, showing its overview: microphone, trigger, cleanup, dictionary, and engine status." width="760">
</p>

## Privacy you can verify

Privacy claims are cheap. This one is checkable.

- **No network entitlement.** `com.apple.security.network.client` is absent from `app/Kalam/Kalam.entitlements`. The app bundle cannot open a network connection. See [`app/docs/SECURITY.md`](app/docs/SECURITY.md).
- **Everything runs on device.** Speech recognition uses Parakeet CoreML models on your Mac.
- **Audio is wiped after use.** Recording buffers are securely zeroed once transcription completes.
- **Nothing is logged.** Transcript and audio content are never written to disk. Logs carry counts and timings only.
- **No accounts, no telemetry, no analytics.**

The [MIT license](LICENSE) lets you check every claim above in the source.

## Install &amp; first run

**1. Open it.** Kalam isn't on the Mac App Store, so Gatekeeper stops you the first time. Right-click (or Control-click) the Kalam app, choose **Open**, then **Open** again. You only do this once.

**2. Follow the setup.** Kalam walks you through four steps:

| Step | What it does |
|---|---|
| Microphone | Required for capture. Choose from your connected inputs. |
| Accessibility | Required for Kalam to type into other apps. |
| Hotkey | Pick your trigger. |
| Model | Point Kalam at a folder to hold the speech model. |

<p align="center">
  <img src="assets/readme/onboarding-steps.png" alt="Kalam's model setup step, showing the three numbered steps needed to place a speech model on the Mac." width="480">
</p>

**3. Download a model.** Kalam has no network access, so it can't fetch one. It shows you the command; you paste it into Terminal. The app never runs shell commands.

```bash
# install the Hugging Face CLI once
brew install hf

# then run the command Kalam shows you in Settings
hf download FluidInference/parakeet-tdt-0.6b-v2-coreml \
  --include "Preprocessor.mlmodelc/*" \
  --include "Encoder.mlmodelc/*" \
  --include "Decoder.mlmodelc/*" \
  --include "JointDecision.mlmodelc/*" \
  --include "*vocab.json" \
  --local-dir '/path/to/your/models/parakeet-tdt-0.6b-v2'
```

Pick the destination folder in **Settings &rarr; Models** first, then copy the command it generates. It always matches the model you selected.

### Models

| Model | Languages | Size | Notes |
|---|---|---|---|
| Parakeet TDT v2 | English | ~450 MB | Highest accuracy (2.1% WER) |
| Parakeet TDT v3 | 25 European languages | ~450 MB | 2.5% WER |
| Parakeet TDT-CTC 110M | English | ~220 MB | Fastest, lowest memory (3.6% WER) |

## Trigger modes

| Mode | Behavior |
|---|---|
| **Hold or Toggle** | Hold the key to record; a quick tap toggles. The default. |
| **Hold** | Record only while the key is down. |
| **Toggle** | Press once to start, press again to stop. |
| **Double Tap** | Tap twice quickly to start and stop. |

The trigger can be a right-hand modifier (Right Command, Right Option, Right Shift, Right Control) or one of six combinations: Command-Option, Control-Command, Control-Option, Shift-Command, Option-Shift, Control-Shift.

## Recording indicator

The indicator sits over your app rather than hiding in a menu.

| State | What you see |
|---|---|
| **listening** | Your app name and a live waveform |
| **pausing** | You went quiet; the mic is still open |
| **transcribing** | The engine is working |
| **held** | Your text is ready, with **Paste** and **Discard** |
| **blocked** | The microphone isn't available, with a shortcut to Settings |

<p align="center">
  <img src="assets/readme/state-whisper.png" alt="The compact whisper indicator style, showing the target app, a level meter, and a timer." width="300">
</p>

## Updates

Kalam can't check for updates, because that would need a network entitlement. For the latest version, use **View Latest Release** in the menu bar item, or open the [releases page](https://github.com/singhkays/Kalam/releases/latest).

For release notifications, watch the repository on GitHub: **Watch &rarr; Custom &rarr; Releases**.

## FAQ

**Does any of my data leave my Mac?**
No. Kalam is compiled without network entitlements. Audio is processed on-device and wiped from memory when transcription finishes. Nothing is transmitted, stored, or sent to anyone.

**Is it really free?**
Yes. MIT licensed, no subscriptions, no usage limits, no premium tier. Download it, read it, fork it.

**What happens when I go quiet?**
Nothing gets cut. While you're silent the indicator drops to a low meter so you know it's still listening. Kalam processes the whole take when you stop talking, trimming silence at the edges.

**Why won't Kalam paste into my password field?**
On purpose. It refuses secure text fields and any app with secure input active, so your transcript never lands on the pasteboard by accident.

**Does it need my password or any account?**
No. There is no account, no sign-in, and no server.

**What macOS versions are supported?**
macOS 14.6 or later. Apple Silicon is recommended.

## For developers

The architecture, runtime flow, and build/test instructions live in
[**app/docs/DEVELOPER_GUIDE.md**](app/docs/DEVELOPER_GUIDE.md).

```
app/                       macOS app (Swift 6, AppKit + SwiftUI)
app/Packages/KalamTextEngine/   cleanup engine + dictionary compiler
scripts/                   engine tests, README capture, model probes
landing-page/              Vite/React site
```

Run the engine tests without Xcode:

```bash
./scripts/test-engine.sh
```

## Contributing

Issues and pull requests are welcome. Before changing the dictation pipeline, read [`AGENTS.md`](AGENTS.md). It documents the invariants: no network code, no logging of transcript or audio content, and clipboard-restore semantics.

## License

MIT. See [LICENSE](LICENSE).
# Security Policy

## Overview

Kalam is a privacy-first local dictation application. All audio processing, transcription, and text processing happens entirely on your device. No audio data, transcriptions, or personal information is ever transmitted to external servers.

## App Sandbox, Entitlements, And Runtime Capabilities

Kalam treats App Sandbox as the intended security posture. The checked-in entitlement file enables `com.apple.security.app-sandbox`, `com.apple.security.device.audio-input`, and `com.apple.security.accessibility`, while deliberately omitting `com.apple.security.network.client`. Outgoing network access is therefore disabled for the sandboxed app.

Runtime behavior still depends on macOS permission grants and target-app support:

- **Global Hotkey Detection** uses the sandbox-compatible Carbon HotKey path where possible.
- **Text Injection** attempts CGEvent unicode insertion, then a pasteboard + Cmd+V path, then Accessibility insertion. Accessibility permission and target-app behavior must be verified at runtime.
- **System Audio Ducking** uses manual CoreAudio output-volume changes. The app now inspects runtime entitlements and logs capability status because sandboxed/manual CoreAudio behavior can vary by OS and output device. If ducking cannot be performed safely, recording continues without ducking.
- **Models** are user-provisioned from a local folder selected by the user. The app does not download models itself in the sandboxed runtime.

## Data Privacy

### Audio Data
- Recorded audio is held temporarily in memory only during transcription
- Audio sample arrays are cleared after use on best-effort Kalam-owned buffers; downstream framework/runtime copies are governed by their normal memory lifetimes
- Audio is never written to disk or transmitted over the network

### Transcription Data
- Transcribed text is processed entirely locally
- Text may be temporarily placed on the system pasteboard for injection
- Original pasteboard contents are restored only if the pasteboard still contains Kalam's inserted text and the pasteboard change count has not advanced

### Logging
- The app logs timing and performance metrics for debugging
- Transcription content is NOT logged (only character counts and processing times)

## Security Measures

- **Hardened Runtime**: Enabled to prevent code injection and tampering
- **Library Validation**: Prevents malicious dynamic library injection
- **Memory Security**: Kalam clears owned audio buffers after transcription where possible; it does not claim that every downstream framework/runtime copy is cryptographically wiped
- **Network Security**: Kalam is built with **zero network entitlements** in the Xcode project sandbox. This is a deliberate design choice; even if the app tried to make a network request, it would be blocked at the OS level. ASR models are user-provisioned and loaded from local disk only.

## Third-Party Components

| Component | Source | License |
|-----------|--------|---------|
| FluidAudio | github.com/FluidInference/FluidAudio | Apache 2.0 |
| NemoTextProcessing | github.com/FluidInference/text-processing-rs | Apache 2.0 |
| HotKey | github.com/soffes/HotKey | Public Domain |

## Verifying the Build

### NemoTextProcessing Framework

The NemoTextProcessing.xcframework is built from our open-source Rust implementation. To verify it matches the source:

```bash
# 1. Clone the source repository
git clone https://github.com/FluidInference/text-processing-rs.git
cd text-processing-rs

# 2. Build the framework
cargo build --release

# 3. Compare checksums
shasum -a 256 target/release/libnemo_text_processing.dylib
```

### ASR Models

Models are user-provisioned in your selected model library folder (Settings > Models). You can verify integrity of all compiled bundles:

```bash
find <your-model-library-folder> -name "*.mlmodelc" -exec shasum -a 256 {} \;
```

## Reporting Security Issues

If you discover a security vulnerability:

1. **DO NOT** open a public GitHub issue
2. Use GitHub's **Security Advisories** feature:
   - Go to the repository → Security → Advisories → "Report a vulnerability"
3. Include reproduction steps and impact assessment

We will acknowledge receipt within 48 hours and provide a timeline for the fix.

---

Last updated: May 9, 2026

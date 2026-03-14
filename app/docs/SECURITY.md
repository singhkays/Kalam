# Security Policy

## Overview

Kalam is a privacy-first local dictation application. All audio processing, transcription, and text processing happens entirely on your device. No audio data, transcriptions, or personal information is ever transmitted to external servers.

## App Sandbox Compatibility (Design Constraint)

Kalam currently operates outside of the App Sandbox to prioritize "brute force", hardware-precise functionality over restrictive containment. However, this is a **Fixable Implementation Detail**, and the app *can* be sandboxed for Mac App Store distribution by adopting Apple's higher-level APIs:

- **Global Hotkey Detection**: The app currently monitors system-wide modifier key combinations to detect PTT triggers. Moving fully to the older Carbon HotKey API (`RegisterEventHotkey`) makes this fully sandbox-compatible, at the cost of some custom hotkey flexibility.
- **Text Injection**: The app attempts CGEvent unicode insertion first, then writes the transcript to the system pasteboard and triggers Cmd+V via `CGEvent`, and finally falls back to the Accessibility API (`AXUIElementSetAttributeValue`) for direct insertion if needed. This requires Accessibility permission and avoids Apple Events.
- **System Audio Ducking**: The app manually modifies system output volume via low-level CoreAudio HAL properties during recording. Doing this in the sandbox is fundamentally prohibited. A sandboxed version would instead use macOS 11's `AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: [.duckOthers])`, allowing the system to perform ducking safely on the app's behalf.

Therefore, the lack of App Sandbox is currently an optimization for maximum capability and precision, not a fundamental OS limitation. Notarization-only distribution requires no additional sandbox entitlements, but documentation clarity benefits from explicitly stating intention regarding `com.apple.security.device.audio-input`.

## Data Privacy

### Audio Data
- Recorded audio is held temporarily in memory only during transcription
- Audio buffers are cryptographically zeroed after use
- Audio is never written to disk or transmitted over the network

### Transcription Data
- Transcribed text is processed entirely locally
- Text may be temporarily placed on the system pasteboard for injection
- Original pasteboard contents are preserved and restored on successful paste

### Logging
- The app logs timing and performance metrics for debugging
- Transcription content is NOT logged (only character counts and processing times)

## Security Measures

- **Hardened Runtime**: Enabled to prevent code injection and tampering
- **Library Validation**: Prevents malicious dynamic library injection
- **Memory Security**: Audio buffers are securely zeroed after transcription
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

Last updated: March 9, 2026

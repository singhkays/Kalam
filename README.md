# Kalam 🎙️

Kalam is a high-performance, premium dictation and audio processing engine for macOS. It combines state-of-the-art ASR (Automatic Speech Recognition) with advanced text cleanup and normalization.

## Core Features

-   **Deep Audio Integration**: Low-latency audio capture and normalization via `AudioRecorder`.
-   **Advanced Text Cleanup**: Intelligent filler removal, backtrack editing (e.g., "scratch that"), and grammar correction.
-   **Intelligent Lists**: Automatic detection and formatting of spoken lists with smart sequence validation.
-   **Inverse Text Normalization (ITN)**: Powered by NeMo, converting spoken numbers, dates, and currency to written form.
-   **Custom Dictionary**: User-definable phrase and word replacements with smart-casing and morphological matching.

## Installation & Guided Onboarding

Kalam is a high-performance system utility. To ensure a premium experience, it features a **4-step guided onboarding flow** that helps you configure the app correctly.

### 1. Security & Gatekeeper
Kalam is signed with an "ad-hoc" signature. When running it for the first time:
- **Right-click** (or Control-click) the Kalam app and select **Open**.
- Click **Open** again in the confirmation dialog.
- If you see a warning that it's from an "unidentified developer," you can also go to **System Settings > Privacy & Security** and click **"Open Anyway"** at the bottom.

### 2. Guided Setup (4 Steps)
The app will automatically guide you through these essential steps:
- **Microphone**: Required for capturing audio. Kalam supports priority-ordered microphone selection.
- **Accessibility**: Required to type text into your active applications.
- **Hotkey**: Choose your preferred global shortcut (Hold, Toggle, or Double-Tap).
- **AI Model**: Guided setup for downloading and locating the ASR models.

## Privacy-First Architecture

Kalam runs **entirely on your Mac** with zero external dependencies during operation.
- **No Network Entitlements**: The application bundle explicitly excludes network access, ensuring your data never leaves your device.
- **On-Device Only**: Audio processing and text transcription are 100% local.
- **Secure Memory**: Audio buffers are securely zeroed immediately after processing.
- **Zero Logging**: Dictation content is never written to disk or recorded.

## Model Setup

While most users will use the guided onboarding, you can manually manage models:

1.  **Download the Model** (~600 MB):
    ```bash
    # install hf cli if needed: curl -LsSf https://hf.co/cli/install.sh | bash
    hf download FluidInference/parakeet-tdt-0.6b-v2-coreml \
      --include "Preprocessor.mlmodelc/*" "Encoder.mlmodelc/*" \
      "Decoder.mlmodelc/*" "JointDecision.mlmodelc/*" "parakeet_vocab.json" \
      --local-dir ~/Models/FluidAudio/parakeet-tdt-0.6b-v2-coreml
    ```
2.  **Configuring Kalam**: Launch Kalam settings, navigate to the **Models** tab, and select the folder.

Kalam features a robust automated testing harness designed for reliability and rapid iteration.

### Key Testing Components

-   **`KalamTestRunner`**: A unified entry point to exercise the entire pipeline (ASR -> Cleanup -> ITN -> Dictionary) without launching the full app.
-   **Golden Test Suite**: A comprehensive collection of complex edge cases in `engine_golden_tests.json`, covering everything from nested backtracks to aggressive punctuation handling.
-   **Integration Tests**: XCTest-based verify-on-commit suite (`KalamEngineIntegrationTests.swift`) ensuring zero regressions in core engine logic.

## Quick Start (Build & Test)

### Prerequisites

-   macOS 14.6 or later
-   Xcode 16.0 or later

### Running the Tests

To run the automated engine integration tests:

```bash
xcodebuild test -project Kalam.xcodeproj -scheme Kalam -destination 'platform=macOS' -only-testing KalamTests/KalamEngineIntegrationTests
```

### CLI Prototyping

Use the included `run_engine_test.swift` for quick experimentation with the text processing stack:

```bash
swift run_engine_test.swift "um I think we should scratch that we must ship one logs two bugs"
```

## Project Structure

-   `app/`: Core macOS application and engine source code (Swift 6+).
-   `landing-page/`: Modern React/Vite-based landing page and assets.
-   `assets/`: Shared visual assets, icons, and logo vectors.
-   `docs/`: Detailed technical specifications and [Engine Architectures](app/docs/DEVELOPER_GUIDE.md).
-   `SECURITY.md`: Detailed [Security Policies](app/docs/SECURITY.md) and privacy proofs.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---
Built with 🥃 and focus for the Apple Ecosystem.

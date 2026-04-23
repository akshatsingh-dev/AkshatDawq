# DAWQ

DAWQ is a privacy-first iOS health copilot that combines Apple Health data, voice logs, and uploaded medical documents into one conversational experience.

The goal: make your health data actually useful day-to-day, while keeping sensitive data on your device by default.

## Why This Matters

Most health apps either:
- collect data but do not help you reason about it, or
- provide AI chat but require cloud upload of personal health information.

DAWQ is designed to bridge that gap:
- **on-device inference first** for privacy and control
- **structured local storage** for reliability and auditability
- **grounded answers** from your data, not generic model guesswork
- **extensible architecture** for future hybrid routing (Cactus) and long-term memory summarization (Honcho-style integration)

## Core Capabilities

- **Apple Health import**
  - one-tap historical import
  - progress tracking in UI
  - daily/background sync support

- **Medical document ingestion (PDF)**
  - import files directly in-app
  - chunk + keyword retrieval pipeline for grounded context
  - document-aware Q&A in Ask tab

- **Personal health chat**
  - conversational Ask UI with message history in SQLite
  - model-powered responses when available
  - useful fallback behavior while model is preparing

- **On-device model lifecycle**
  - GGUF integrity checks (magic bytes validation)
  - download/install state tracking
  - truthful UI state (only shows active when model is truly valid and loaded)

## Tech Stack

- **SwiftUI** (app UI)
- **GRDB** (SQLite layer)
- **llama.cpp (SwiftPM)** pinned to compatible revision
- **HealthKit** integration
- **PDFKit** for document text extraction

## Project Structure

- `App/` app entrypoints and tab shell
- `Views/` user-facing screens (`Home`, `Ask`, `Data`, `Profile`, onboarding)
- `Inference/` model runtime, routing, retrieval, transcription helpers
- `HealthKit/` authorization and import pipelines
- `Database/` schema + migrations + DB manager
- `Models/` app/domain models
- `Background/` background processing orchestration

## Privacy and Safety

- Raw health data stays on device unless a future cloud path is explicitly enabled.
- Document and chat context is stored locally in SQLite.
- App guidance is informational and **not** medical diagnosis or treatment.

> **Medical Disclaimer**: DAWQ is not a medical device and does not replace professional care. Always consult licensed clinicians for diagnosis and treatment decisions.

## Getting Started

### Requirements

- macOS with Xcode 16+
- iOS 17+ simulator/device target
- Homebrew (auto-installed by setup script if missing)

### Setup

```bash
./setup.sh
```

This script installs XcodeGen, ensures required files exist, and generates `DAWQ.xcodeproj`.

### Open and Run

```bash
open DAWQ.xcodeproj
```

Then run the `DAWQ` scheme in Xcode.

### CLI Build Check

```bash
xcodebuild -project DAWQ.xcodeproj -scheme DAWQ -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build
```

## Product Flow (Current)

1. Onboard and connect Apple Health
2. Download/prepare on-device model
3. Import historical health data from Data tab
4. Optionally upload PDFs (labs/reports)
5. Ask natural language questions in Ask tab

## Roadmap

- Better longitudinal memory and user timeline abstraction
- Optional hybrid routing policy layer (on-device vs. cloud)
- More robust evaluation harness for medical factuality and safety
- Model benchmarking and swap-ready configuration
- Expanded ingestion connectors beyond HealthKit/PDF

## Contributing

For now, this repository is moving fast and optimized for product iteration.  
If you want to contribute, open an issue describing:
- what you want to improve
- why it matters
- expected UX/behavior changes

See also:
- `CONTRIBUTING.md` for workflow and quality bar
- `SECURITY.md` for responsible vulnerability reporting
- `.github/` templates for consistent issues/PRs

## License

No license file is currently included. All rights reserved until a license is added.

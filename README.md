# Viska

A macOS menu bar app for global voice dictation. Press a hotkey anywhere, speak, and transcribed text is inserted at the cursor — no window switching required.

Transcription is powered by ChatGPT via the [Codex CLI](https://github.com/openai/codex), which handles authentication.

## Features

- **Global hotkey** — trigger dictation from any app (default: `⌃⌥Space`)
- **Two recording modes** — hold-to-record or toggle-to-record
- **Live waveform overlay** — floating capsule with real-time audio visualization while recording
- **Smart text insertion** — inserts directly via Accessibility APIs, falls back to paste, then clipboard
- **Cancel with Escape** — discard a recording at any time
- **Menu bar status** — color-coded badge shows state (ready, recording, transcribing, unavailable)
- **Auth-aware** — detects Codex sign-in status and shows setup guidance when needed

## Requirements

- macOS 15.0 (Sequoia) or later
- [Codex CLI](https://github.com/openai/codex) installed and signed in (requires a ChatGPT Plus/Pro/Team subscription)
- Xcode 16+ (Swift 6.0) for building
- [Tuist](https://tuist.io) for project generation

## Setup

```bash
# Install Tuist if you haven't already
curl -Ls https://install.tuist.io | bash

# Clone and build
git clone https://github.com/martinj/viska.git
cd viska
./run-menubar.sh
```

On first launch, the app will request:

1. **Microphone access** — required for audio capture
2. **Accessibility access** — required for inserting text into other apps

## Usage

1. The app appears as an icon in the menu bar
2. Press the hotkey (default `⌃⌥Space`) to start recording
3. Speak your text
4. Release the hotkey (hold mode) or press it again (toggle mode) to stop
5. The transcription is inserted at your cursor

Press **Escape** at any time to cancel a recording.

Click the menu bar icon to change the recording mode, customize the hotkey, or check status.

## How it works

```
Hotkey pressed → Microphone capture starts → Waveform overlay appears
    → Hotkey released → Audio encoded as WAV → Sent to ChatGPT for transcription
    → Text inserted at cursor (Accessibility API → paste fallback → clipboard)
```

The app communicates with a local Codex app-server process to obtain ChatGPT authentication tokens. The Codex binary is located automatically from common install paths or `$PATH`.

## Project structure

```
Sources/
├── App/            # Entry point and dependency injection
├── Audio/          # AVAudioEngine capture, WAV encoding, level analysis
├── Codex/          # Codex process management and JSON-RPC client
├── Hotkey/         # Global hotkey via Carbon Events API
├── Insertion/      # Text insertion strategies (Accessibility, paste, clipboard)
├── MenuBar/        # Status item, popover UI
├── Overlay/        # Floating recording overlay with waveform
├── Permissions/    # Microphone and Accessibility permission handling
├── Settings/       # UserDefaults-backed preferences
├── State/          # Dictation state machine and store
└── Transcription/  # ChatGPT transcription client
Tests/              # Unit tests mirroring source structure
```

Built with **SwiftUI** + **AppKit**, managed by **Tuist** (`Project.swift`).

## Development

```bash
# Build and launch
./run-menubar.sh

# Stop the running app
./stop-menubar.sh

# Generate Xcode project without building
tuist generate
```

## License

This project is not yet licensed. All rights reserved.

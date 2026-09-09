# Edge Eloquent

> **Minimalist dictation powered by Google AI Edge LiteRT-LM on iOS.**
> Transcribes locally on-device using multi-model support, performs deterministic local filler cleanup, and optionally enhances text via secure text-only Cloudflare processing. **Audio never leaves the device.**

[![iOS 17.0+](https://img.shields.io/badge/iOS-17.0%2B-blue.svg)](https://developer.apple.com/ios/)
[![Feather Ready](https://img.shields.io/badge/Feather-Community%20Source-purple.svg)](feather-source.json)
[![AltStore Compatible](https://img.shields.io/badge/AltStore-Compatible-orange.svg)](feather-source.json)
[![Privacy First](https://img.shields.io/badge/Privacy-Zero%20Audio%20Leakage-success.svg)](docs/ARCHITECTURE.md)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-lightgrey.svg)](LICENSE)

---

## 📱 Sideload via Feather (Recommended)

Edge Eloquent distributes signed and sign-ready `.ipa` builds directly through **Feather** and **AltStore** community sources.

### 🚀 Direct Import Links

| Client | One-Tap Direct Import Link |
| :--- | :--- |
| **Feather** | [📲 Add Source to Feather](feather://source/https://raw.githubusercontent.com/fuckmmw-afk/edge-eloquent/refs/heads/main/feather-source.json) |
| **AltStore** | [📲 Add Source to AltStore](altstore://source?url=https://raw.githubusercontent.com/fuckmmw-afk/edge-eloquent/refs/heads/main/feather-source.json) |

---

### 📋 Manual Source Addition in Feather

1. Copy the raw source URL:
   ```text
   https://raw.githubusercontent.com/fuckmmw-afk/edge-eloquent/refs/heads/main/feather-source.json
   ```
2. Open **Feather** on your iOS device.
3. Tap **Sources** in the navigation bar.
4. Tap **Add Source** (or the **+** button).
5. Paste the URL into the input field and confirm.
6. Select **Edge Eloquent** and tap **Install**. Feather will download the IPA from GitHub Releases and sign it with your certificate.

For comprehensive details on repository schema, version tracking, and deep linking, see the [Feather Integration Guide](docs/FEATHER.md).

---

## 🔒 The Audio Air-Gap Invariant

1. **Local-Only Inference:** Microphone audio is captured via `AVAudioEngine` and fed directly to the official Google AI Edge **LiteRT-LM 0.16.1** package running on Apple Silicon.
2. **Zero Audio Transmission:** Raw PCM buffers, WAV files, and audio spectrograms **never touch the network**.
3. **Optional Text Enhancement:** Cloud enhancement is disabled by default. When explicitly configured, only post-transcription text is forwarded via TLS 1.3. Web search is a separate opt-in because it sends a derived query to the configured search provider.
4. **No Bundled Weights:** The IPA includes the LiteRT-LM runtime but no model weights. Compatible audio-capable `.litertlm` models are discovered on Hugging Face, downloaded from immutable revisions, and verified with SHA-256.

---

## 📂 Repository Structure

```
edge-eloquent/
├── feather-source.json           # Feather & AltStore repository index
├── Package.swift                 # Swift package manifest
├── Sources/
│   └── EdgeEloquent/             # Core application source code
│       ├── Audio/                # Real-time microphone capture & ring buffers
│       ├── Cloudflare/           # Text-only Cloudflare post-processing client
│       ├── History/              # Local iOS Data Protection storage
│       ├── Models/               # Engine abstractions & model metadata
│       └── Transcription/        # Audio transcript coordinators
├── Tests/
│   ├── EdgeEloquentTests/        # Swift unit tests
│   └── validate_feather.py       # Strict Feather/AltStore source schema validator
├── cloudflare-worker/            # Privacy-isolated text enhancement worker
└── docs/
    ├── ARCHITECTURE.md           # Detailed system architecture specification
    ├── BUILD.md                  # Local build, test, IPA packaging & release guide
    ├── FEATHER.md                # Feather source documentation & schema guide
    ├── MODELS.md                 # Supported models & download orchestration
    └── RESEARCH.md               # Technical research & benchmarks
```

---

## 🛠️ Validation & Development

### Validating `feather-source.json`

Ensure your source repository metadata adheres strictly to Feather and AltStore schemas:

```bash
python3 Tests/validate_feather.py
```

Expected output:
```text
=== Validating Feather Source: /root/edge-eloquent/feather-source.json ===

[PASS] Source JSON schema is 100% valid!
  - Repository Name: Edge Eloquent Source
  - Identifier:      com.edgeeloquent.source
  - Apps Registered: 1
  - Total Releases:  7
    * Edge Eloquent (com.edgeeloquent.app) - v1.0.7 (21039422 bytes)
      IPA URL: https://github.com/fuckmmw-afk/edge-eloquent/releases/download/v1.0.7/EdgeEloquent.ipa
```

---

## 📄 License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.

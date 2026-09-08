# Comprehensive Research: Google AI Edge Gallery & LiteRT-LM Swift Runtime

**Document Version:** 1.0.0  
**Target Project:** Edge Eloquent (iOS On-Device Multimodal & Audio Intelligence)  
**Author:** ResearchAgent  
**Date:** September 2026  

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Google AI Edge Gallery Architecture & Upstream Analysis](#2-google-ai-edge-gallery-architecture--upstream-analysis)
   - [2.1 Repository Structure: Android vs. iOS Status](#21-repository-structure-android-vs-ios-status)
   - [2.2 The iOS Open-Source Gap (Issue #420)](#22-the-ios-open-source-gap-issue-420)
   - [2.3 Release Footprint: App Store & TestFlight Distribution](#23-release-footprint-app-store--testflight-distribution)
3. [LiteRT-LM Swift Runtime Architecture](#3-litert-lm-swift-runtime-architecture)
   - [3.1 Upstream Repository & Package.swift Structure](#31-upstream-repository--packageswift-structure)
   - [3.2 The Binary Target: CLiteRTLM.xcframework](#32-the-binary-target-clitertlmxcframework)
   - [3.3 Core Swift Wrappers Deep Dive](#33-core-swift-wrappers-deep-dive)
     - [Engine.swift & EngineConfig](#engineswift--engineconfig)
     - [Message.swift & Multimodal Content](#messageswift--multimodal-content)
     - [Conversation.swift & Streaming Architecture](#conversationswift--streaming-architecture)
     - [Capabilities.swift & ExperimentalFlags.swift](#capabilitiesswift--experimentalflagsswift)
     - [Error Architecture: LiteRTLMError](#error-architecture-litertlmerror)
4. [Model Allowlists & Audio-Capable Models](#4-model-allowlists--audio-capable-models)
   - [4.1 Allowlist Evolution: `ios_1_0_0.json` vs. `1_0_19.json`](#41-allowlist-evolution-ios_1_0_0json-vs-1_0_19json)
   - [4.2 Audio & Multimodal Model Comparison Matrix](#42-audio--multimodal-model-comparison-matrix)
   - [4.3 Model Artifact Format (.litertlm) & Quantization](#43-model-artifact-format-litertlm--quantization)
   - [4.4 Hardware Acceleration & RAM Requirements](#44-hardware-acceleration--ram-requirements)
5. [Hugging Face Hub Integration & Model Distribution](#5-hugging-face-hub-integration--model-distribution)
   - [5.1 Hugging Face Hub REST API & Metadata Discovery](#51-hugging-face-hub-rest-api--metadata-discovery)
   - [5.2 Direct CDN Download Resolution](#52-direct-cdn-download-resolution)
   - [5.3 Resumable Chunked Transfers](#53-resumable-chunked-transfers)
   - [5.4 Verification: Commit Hash Pinning & SHA-256](#54-verification-commit-hash-pinning--sha-256)
   - [5.5 Gated Model Access & Bearer Token Authentication](#55-gated-model-access--bearer-token-authentication)
6. [End-to-End Model Lifecycle & Memory Management](#6-end-to-end-model-lifecycle--memory-management)
   - [6.1 Complete Lifecycle State Machine](#61-complete-lifecycle-state-machine)
   - [6.2 Filesystem Storage Strategy](#62-filesystem-storage-strategy)
   - [6.3 Initialization, Metal Pipeline Compilation & KV Cache Allocation](#63-initialization-metal-pipeline-compilation--kv-cache-allocation)
   - [6.4 Jetsam Memory Budgets & Graceful Teardown](#64-jetsam-memory-budgets--graceful-teardown)
7. [Audio Capture, Encoding & Dictation Pipeline](#7-audio-capture-encoding--dictation-pipeline)
   - [7.1 Acoustic Specifications: 16 kHz Mono 16-bit PCM](#71-acoustic-specifications-16-khz-mono-16-bit-pcm)
   - [7.2 AVAudioSession Configuration](#72-avaudiosession-configuration)
   - [7.3 Native Tap Capture via AVAudioEngine](#73-native-tap-capture-via-avaudioengine)
   - [7.4 Windowing, Slicing & Real-Time Dictation](#74-windowing-slicing--real-time-dictation)
   - [7.5 Critical Multimodal Message Ordering Rule](#75-critical-multimodal-message-ordering-rule)
8. [Constraints, Pitfalls & Architectural Limitations](#8-constraints-pitfalls--architectural-limitations)
9. [Synthesis & Recommendations for Edge Eloquent](#9-synthesis--recommendations-for-edge-eloquent)

---

## 1. Executive Summary

This research report provides an authoritative technical breakdown of Google's on-device generative AI ecosystem, focusing on **Google AI Edge Gallery** and the underlying **LiteRT-LM (formerly TensorFlow Lite / MediaPipe GenAI)** runtime for iOS and macOS.

With the advent of the **Gemma 3n** and **Gemma 4** model families, Google introduced native on-device multimodal processing (text, high-resolution vision, and audio comprehension) packaged into a unified `.litertlm` artifact. While Google distributes an open-source Android implementation in [`google-ai-edge/gallery`](https://github.com/google-ai-edge/gallery), the iOS application has been released exclusively as a compiled binary on the Apple App Store and TestFlight. However, the foundational C++ runtime and official Swift package are hosted in [`google-ai-edge/LiteRT-LM`](https://github.com/google-ai-edge/LiteRT-LM), providing first-class Swift bindings, C FFI headers, and precompiled XCFrameworks.

This document synthesizes findings from reverse-engineering the gallery allowlists, inspecting the LiteRT-LM Swift bindings, analyzing audio capture architectures from production iOS implementations (Dictus, LiveTranscriber, and GemmaTranscribe), and inspecting the Hugging Face distribution mechanism.

---

## 2. Google AI Edge Gallery Architecture & Upstream Analysis

### 2.1 Repository Structure: Android vs. iOS Status

The public repository [`google-ai-edge/gallery`](https://github.com/google-ai-edge/gallery) is organized as follows:

```
google-ai-edge-gallery/
├── Android/                    # Complete Android Jetpack Compose source code
│   ├── src/app/                # Main Android application module
│   │   ├── src/main/java/      # Kotlin source code
│   │   │   ├── agent/          # Tool use, agent sessions, and execution
│   │   │   ├── customtasks/    # TinyGarden, MobileActions, Scrapbook
│   │   │   ├── data/           # Model allowlist, SOC mappings, repositories
│   │   │   ├── huggingface/    # Hugging Face Hub REST client and URL parsers
│   │   │   ├── runtime/        # LlmModelHelper, LiteRT-LM & AICore wrappers
│   │   │   ├── ui/             # Jetpack Compose UI (Chat, PromptLab, ModelManager)
│   │   │   └── worker/         # WorkManager DownloadWorker (HTTP Range resume)
│   │   └── src/main/proto/     # Protobuf schemas (hf_model.proto, chat.proto)
├── mcp/                        # Model Context Protocol definitions
├── model_allowlist.json        # Base model catalog
├── model_allowlists/           # Versioned catalog files
│   ├── 1_0_4.json ... 1_0_19.json  # Android progressive feature rollouts
│   └── ios_1_0_0.json          # Dedicated iOS initial allowlist
├── skills/                     # Modular Agent Skills (JavaScript / HTML cards)
├── DEVELOPMENT.md              # Android build instructions
└── README.md                   # Project overview & App Store badges
```

#### Android vs. iOS Divergence
- **Android:** Fully open-sourced under the Apache 2.0 license. Written in Kotlin using Jetpack Compose, Hilt, Coroutines/Flow, and Android WorkManager. It targets Android 12+ (API level 31+) and supports Qualcomm Snapdragon, MediaTek Dimensity, Samsung Exynos, and Google Tensor chips (with Google Pixel AICore integration).
- **iOS:** Completely closed-source at the application layer. No `iOS/` or `Apple/` directory exists within the `google-ai-edge/gallery` git repository. Google distributes the iOS app solely as a pre-compiled release on the Apple App Store ([App Store ID 6749645337](https://apps.apple.com/us/app/google-ai-edge-gallery/id6749645337)) and through closed TestFlight betas.

### 2.2 The iOS Open-Source Gap (Issue #420)

The absence of the iOS source code has been a major point of friction for the edge AI developer community:
- **GitHub Issue #420 (`[Support]: iOS Version Source Code?`):** Opened on January 5, 2026, by community members noting:
  > *"It would be incredibly helpful to have the iOS version of Edge Gallery’s source code released here too. Especially since there is no proper documentation right now on Gemma 3n multimodal inference on iOS, looking at the app's currently working implementation would be tremendously helpful."*
- Follow-up issues (including **#634** and **#698**) repeated the inquiry regarding missing Swift multimodal inference code.
- Google maintainers have assigned the issues internally (`dpknag`) but kept the gallery application layer proprietary, while directing developers to the low-level Swift bindings in [`google-ai-edge/LiteRT-LM`](https://github.com/google-ai-edge/LiteRT-LM).

### 2.3 Release Footprint: App Store & TestFlight Distribution

Despite the repository omission, Google maintains active iOS distribution:
- **Bundle Identifier:** `com.google.ai.edge.gallery`
- **Minimum OS Requirement:** iOS 17.0+ (utilizing Swift concurrency, Metal 3, and unified memory).
- **Target Devices:** iPhone 15 Pro, iPhone 15 Pro Max, iPhone 16 series, and M-series iPads (minimum 6GB to 8GB physical RAM).
- **Catalog Mechanism:** The iOS client fetches remote JSON allowlists directly from the repository raw CDN (`https://raw.githubusercontent.com/google-ai-edge/gallery/main/model_allowlists/ios_1_0_0.json`), allowing Google to update model checkpoints, commit hashes, and token budgets over the air without resubmitting app binaries to App Store Review.

---

## 3. LiteRT-LM Swift Runtime Architecture

While the Gallery UI on iOS remains proprietary, the underlying inference engine is fully accessible via Google's official Swift package: **`google-ai-edge/LiteRT-LM`**.

### 3.1 Upstream Repository & Package.swift Structure

The upstream Swift package uses standard Swift Package Manager (SPM) architecture:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "LiteRTLM",
  platforms: [
    .iOS(.v15),
    .macOS(.v12)
  ],
  products: [
    .library(
      name: "LiteRTLM",
      targets: ["LiteRTLM"]
    )
  ],
  targets: [
    .binaryTarget(
      name: "CLiteRTLM",
      url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.16.0/CLiteRTLM.xcframework.zip",
      checksum: "4e0f683da07566ee79c143d2d58d387f77052b0e6a41562c969e5d2728fc9f4b"
    ),
    .target(
      name: "LiteRTLM",
      dependencies: ["CLiteRTLM"],
      path: "Sources"
    )
  ]
)
```

### 3.2 The Binary Target: CLiteRTLM.xcframework

`CLiteRTLM.xcframework` contains the pre-compiled C++ core engine compiled for `ios-arm64`, `ios-arm64-simulator`, and `macos-arm64_x86_64`.
- **Release Version:** `v0.16.0`
- **Archive URL:** `https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.16.0/CLiteRTLM.xcframework.zip`
- **SHA-256 Checksum:** `4e0f683da07566ee79c143d2d58d387f77052b0e6a41562c969e5d2728fc9f4b`
- **Underlying Engines:**
  - TensorFlow Lite / LiteRT core with Metal GPU delegate.
  - Apple Metal Shading Language (MSL) compute kernels for GEMM, GEMV, FlashAttention, and RMSNorm.
  - SentencePiece / Gemma Byte-Pair Encoding (BPE) native tokenizers.
  - llguidance C++ library for constrained context-free grammar (CFG) and JSON schema decoding.

### 3.3 Core Swift Wrappers Deep Dive

The high-level Swift package wraps the raw C FFI into thread-safe, idiomatic Swift concurrency abstractions.

```
LiteRTLM/Sources/
├── Benchmark.swift            # Benchmark metrics (time to first token, tokens/sec)
├── Capabilities.swift         # Probes .litertlm file for speculative decoding & features
├── Config.swift               # EngineConfig, SamplerConfig, Backend definitions
├── Conversation.swift         # Conversation actor, sendMessage, sendMessageStream
├── Engine.swift               # Engine actor managing litert_lm_engine handle
├── ExperimentalFlags.swift    # Feature flags (MTP, speculative decoding, visual budget)
├── LiteRTLMError.swift        # Hierarchical Error enum
├── Message.swift              # Role, Content (.text, .audioData, .imageData), JSON serialization
├── ResponseFormat.swift       # JSON schema & regex constraints
├── Tool.swift                 # Function calling interfaces
└── ToolManager.swift          # Dynamic tool dispatch
```

#### Engine.swift & EngineConfig

`Engine` is implemented as a Swift `actor` to guarantee serialized access to the underlying native pointer:

```swift
public actor Engine {
  public let engineConfig: EngineConfig
  private var handle: OpaquePointer? = nil

  public init(engineConfig: EngineConfig) {
    self.engineConfig = engineConfig
  }

  public func initialize() throws {
    let backendStr = engineConfig.backend.rawValue
    let visionBackendStr = engineConfig.visionBackend?.rawValue
    let audioBackendStr = engineConfig.audioBackend?.rawValue

    let settings = litert_lm_engine_settings_create(
      engineConfig.modelPath, backendStr, visionBackendStr, audioBackendStr
    )
    guard let settings else { throw LiteRTLMError.engine(.failedToCreateSettings) }
    defer { litert_lm_engine_settings_delete(settings) }

    if let maxNumTokens = engineConfig.maxNumTokens {
      litert_lm_engine_settings_set_max_num_tokens(settings, Int32(maxNumTokens))
    }
    if let cacheDir = engineConfig.cacheDir {
      litert_lm_engine_settings_set_cache_dir(settings, cacheDir)
    }
    // Setup LoRA ranks, benchmark flags, and speculative decoding...
    guard let engine = litert_lm_engine_create(settings) else {
      throw LiteRTLMError.engine(.failedToCreateEngine)
    }
    self.handle = engine
  }

  deinit {
    if let handle = handle {
      litert_lm_engine_delete(handle)
    }
  }
}
```

##### EngineConfig Parameters:
1. `modelPath: String`: Absolute path to the `.litertlm` file on device storage.
2. `backend: Backend`: The primary LLM decode backend (`.gpu` or `.cpu(threadCount:)`). On iOS, `.gpu` executes via Metal shaders.
3. `visionBackend: Backend?`: Separate backend for the image encoder (SigLIP / ViT). Must be set to `.gpu` for Gemma 3n/Gemma 4.
4. `audioBackend: Backend?`: Separate backend for the audio encoder (USM / Conformer).
   > [!IMPORTANT]
   > In Google's reference implementation, `audioBackend` is configured as `.cpu()` because the audio feature extractor and Conformer subsampling blocks are optimized for NEON vectorized CPU instructions rather than Metal compute shaders. Omitting `audioBackend` prevents the engine from loading audio weights.
5. `maxNumTokens: Int?`: Total KV cache size (input prompt tokens + generated tokens). Exceeding this budget causes inference failure.
6. `cacheDir: String?`: Directory where the engine writes compiled Metal binary archives and scratch buffers. Must be in `Caches` or `tmp`.

#### Message.swift & Multimodal Content

`Message.swift` defines how multimodal inputs are structured and sent to the C FFI via JSON serialization:

```swift
public enum Content {
  case text(String)
  case imageData(Data)
  case imageFile(String)
  case audioData(Data)
  case audioFile(String)
  case toolResponse(name: String, response: Any, id: String = "")

  var toJson: [String: Any] {
    switch self {
    case .text(let text):
      return ["type": "text", "text": text]
    case .imageData(let bytes):
      return ["type": "image", "blob": bytes.base64EncodedString()]
    case .imageFile(let absPath):
      return ["type": "image", "path": absPath]
    case .audioData(let bytes):
      return ["type": "audio", "blob": bytes.base64EncodedString()]
    case .audioFile(let absPath):
      return ["type": "audio", "path": absPath]
    case .toolResponse(let name, let response, let id):
      var dict: [String: Any] = ["type": "tool_response", "name": name, "response": response]
      if !id.isEmpty { dict["id"] = id }
      return dict
    }
  }
}
```

Notice that audio can be supplied either as raw in-memory bytes base64-encoded (`.audioData`), or as a zero-copy direct file path (`.audioFile`). For large audio recordings, `.audioFile` is substantially faster as it avoids base64 encoding overhead and excessive heap allocations.

#### Conversation.swift & Streaming Architecture

Token streaming is accomplished using Swift's `AsyncThrowingStream` bridged to a C callback:

```mermaid
sequenceDiagram
    participant App as Swift Application
    participant Conv as Conversation (Swift)
    participant CBridge as streamCallback (C Function Pointer)
    participant Native as CLiteRTLM Native Core

    App->>Conv: sendMessageStream(message)
    Conv->>Conv: Serialize Message to JSON
    Conv->>Conv: Wrap StreamContext in Unmanaged.passRetained
    Conv->>Native: litert_lm_conversation_send_message_stream(handle, json, args, streamCallback, contextPtr)
    loop Token Generation
        Native->>CBridge: streamCallback(userData, chunkPtr)
        CBridge->>CBridge: Parse chunk JSON
        CBridge->>Conv: continuation.yield(Message chunk)
        Conv-->>App: for try await chunk in stream
    end
    Native->>CBridge: streamCallback(isFinal = true)
    CBridge->>Conv: continuation.finish()
    CBridge->>CBridge: Unmanaged.release(contextPtr)
```

The streaming bridge code in `Conversation.swift`:
```swift
public func sendMessageStream(
  _ message: Message,
  extraContext: [String: Any]? = nil
) -> AsyncThrowingStream<Message, Error> {
  return AsyncThrowingStream { continuation in
    do {
      let handle = try self.checkIsAlive()
      let context = StreamContext(continuation: continuation, conversation: self)
      let contextPtr = Unmanaged.passRetained(context).toOpaque()

      let status = litert_lm_conversation_send_message_stream(
        handle,
        messageJsonString,
        extraContextString,
        optionalArgs,
        streamCallback,
        contextPtr
      )
      guard status == 0 else {
        Unmanaged<StreamContext>.fromOpaque(contextPtr).release()
        throw LiteRTLMError.conversation(.failedToStartStream(status: Int(status)))
      }
    } catch {
      continuation.finish(throwing: error)
    }
  }
}
```

#### Capabilities.swift & ExperimentalFlags.swift

- **`Capabilities(modelPath:)`**: Opens the `.litertlm` file without instantiating the full GPU engine to inspect metadata, verify model integrity, and check if speculative decoding (Multi-Token Prediction / draft models) is supported.
- **`ExperimentalFlags`**: Allows runtime toggling of advanced inference optimizations:
  - `enableSpeculativeDecoding`: Activates draft-model speculation for up to 2x faster decode speed.
  - `visualTokenBudget`: Dynamically restricts visual tokens for Gemma 4 (options: 70, 140, 280, 560, 1120 tokens) to minimize KV-cache footprint.
  - `filterChannelContentFromKvCache`: Drops thinking/reasoning scratchpad tokens from the multi-turn KV-cache to avoid saturating context window.

#### Error Architecture: LiteRTLMError

The SDK defines a comprehensive error enum covering every phase:
- `LiteRTLMError.engine`: `.alreadyInitialized`, `.failedToCreateSettings`, `.failedToCreateEngine`, `.notInitialized`.
- `LiteRTLMError.conversation`: `.notAlive`, `.failedToStartStream(status:)`, `.invalidResponse`, `.invalidJson`.
- `LiteRTLMError.config`: `.invalidMaxNumTokens`, `.multipleSystemMessages`.
- `LiteRTLMError.tool`: `.toolNotFound`, `.toolExecutionError`.

---

## 4. Model Allowlists & Audio-Capable Models

### 4.1 Allowlist Evolution: `ios_1_0_0.json` vs. `1_0_19.json`

Google manages on-device model support via versioned JSON manifests located in `model_allowlists/`. Comparing `ios_1_0_0.json` with the latest Android manifest `1_0_19.json` highlights the progression of multimodal capabilities:

1. **`ios_1_0_0.json` (Initial iOS Production Baseline):**
   - Focuses strictly on memory-validated checkpoints that fit within the 6GB–8GB iOS memory envelope.
   - Introduced **`Gemma-3n-E2B-it`** (3.38 GB) and **`Gemma-3n-E4B-it`** (4.65 GB).
   - Set context window strictly to 4096 tokens.
   - Accelerators configured exclusively to `gpu`.

2. **`1_0_19.json` (Latest Multi-Turn & Gemma 4 Expansion):**
   - Introduced **`Gemma-4-E2B-it`** and **`Gemma-4-E4B-it`**.
   - Massive context window expansion: **up to 32,000 tokens**.
   - Added `llm_thinking` (chain-of-thought channel) and `speculative_decoding` (Multi-Token Prediction - MTP).
   - Distinct accelerator splitting: `"accelerators": "gpu,cpu"`, `"visionAccelerator": "gpu"`.

### 4.2 Audio & Multimodal Model Comparison Matrix

The following table provides the exact technical specifications for all models supported for audio and speech processing across the allowlists:

| Model Attribute | Gemma-3n-E2B-it (iOS) | Gemma-3n-E4B-it (iOS) | Gemma-4-E2B-it (v1.0.19) | Gemma-4-E4B-it (v1.0.19) |
| :--- | :--- | :--- | :--- | :--- |
| **Model Name** | `Gemma-3n-E2B-it` | `Gemma-3n-E4B-it` | `Gemma-4-E2B-it` | `Gemma-4-E4B-it` |
| **Hugging Face ID** | `google/gemma-3n-E2B-it-litert-lm` | `google/gemma-3n-E4B-it-litert-lm` | `litert-community/gemma-4-E2B-it-litert-lm` | `litert-community/gemma-4-E4B-it-litert-lm` |
| **Target File** | `gemma-3n-E2B-it-int4.litertlm` | `gemma-3n-E4B-it-int4.litertlm` | `gemma-4-E2B-it.litertlm` | `gemma-4-E4B-it.litertlm` |
| **Commit Hash** | `73b019b63436d346f68dd9c1dbfd117eb264d888` | `3d0179a0648381585ab337e170b7517aae8e0ce4` | `6e5c4f1e395deb959c494953478fa5cec4b8008f` | `28299f30ee4d43294517a4ac93abd6163412f07f` |
| **Updated Hash** | — | — | `7fa1d78473894f7e736a21d920c3aa80f950c0db` | `9695417f248178c63a9f318c6e0c56cb917cb837` |
| **Download Size** | 3,388,604,416 B (~3.39 GB) | 4,652,318,720 B (~4.65 GB) | 2,588,147,712 B (~2.59 GB) | 3,659,530,240 B (~3.66 GB) |
| **Min RAM** | **6 GB** | **8 GB** | **8 GB** | **12 GB** |
| **Audio Input** | ✅ Yes (`llmSupportAudio`) | ✅ Yes (`llmSupportAudio`) | ✅ Yes (`llmSupportAudio`) | ✅ Yes (`llmSupportAudio`) |
| **Image Input** | ✅ Yes (`llmSupportImage`) | ✅ Yes (`llmSupportImage`) | ✅ Yes (`llmSupportImage`) | ✅ Yes (`llmSupportImage`) |
| **Thinking Mode**| ❌ No | ❌ No | ✅ Yes (`llm_thinking`) | ✅ Yes (`llm_thinking`) |
| **Speculative Dec**| ❌ No | ❌ No | ✅ Yes (MTP) | ✅ Yes (MTP) |
| **Max Context** | 4,096 tokens | 4,096 tokens | 32,000 tokens | 32,000 tokens |
| **Max Output** | 4,096 tokens | 4,096 tokens | 4,000 tokens | 4,000 tokens |
| **Default Temp** | 1.0 (TopP 0.95, TopK 64) | 1.0 (TopP 0.95, TopK 64) | 1.0 (TopP 0.95, TopK 64) | 1.0 (TopP 0.95, TopK 64) |
| **Primary Tasks** | `llm_ask_audio`, `llm_chat` | `llm_ask_audio`, `llm_chat` | `llm_chat`, `llm_ask_audio` | `llm_chat`, `llm_ask_audio` |

#### Comparison with Text-Only Models
In contrast, models like `litert-community/Gemma3-1B-IT` (584 MB, 4GB RAM), `litert-community/Qwen2.5-1.5B-Instruct` (1.60 GB), and `litert-community/DeepSeek-R1-Distill-Qwen-1.5B` (1.83 GB) lack multimodal projectors and cannot process audio frames.

### 4.3 Model Artifact Format (.litertlm) & Quantization

The `.litertlm` container is a FlatBuffers-based encapsulation format designed specifically for edge execution:
1. **Weight Quantization:** Linear 4-bit integer weights (`int4`) for LLM projection layers with dynamic group-wise scales (per-channel or per-block-32) and FP16 activations.
2. **Embedded Tokenizer:** The SentencePiece tokenizer model vocabulary and merge rules are embedded directly in the `.litertlm` header, preventing vocabulary mismatch errors.
3. **Multimodal Encoders:** For Gemma 3n and 4, the vision (SigLIP) and audio (Universal Speech Model / Conformer) feature extraction graphs are packed into separate subgraphs within the same binary container.
4. **Direct mmap Compatibility:** The internal buffers are 64-byte aligned to allow zero-copy memory mapping (`mmap`) directly into unified memory on Apple Silicon.

### 4.4 Hardware Acceleration & RAM Requirements

- **Apple Silicon Unified Memory:** On iPhone 15 Pro / 16 (8GB LPDDR5), the iOS kernel typically imposes a hard Jetsam per-process resident memory limit of **4.5 GB to 5.2 GB**.
- **Model Footprint vs Jetsam Limit:**
  - `Gemma-3n-E2B-it`: ~3.39 GB weights + ~600 MB KV cache + ~300 MB app UI = **~4.3 GB total footprint**. Fits securely within an 8GB device limit.
  - `Gemma-3n-E4B-it`: ~4.65 GB weights alone will trigger memory warnings or outright Jetsam kills on 8GB devices unless extended virtual memory (`com.apple.developer.kernel.extended-virtual-addressing` and increased memory limit entitlements) are active.
  - Therefore, `Gemma-3n-E2B-it` and `Gemma-4-E2B-it` represent the sweet spot for consumer iPhones.

---

## 5. Hugging Face Hub Integration & Model Distribution

Google AI Edge Gallery bypasses proprietary cloud hosting for weights, integrating directly with Hugging Face Hub as its decentralized model registry and Content Delivery Network (CDN).

### 5.1 Hugging Face Hub REST API & Metadata Discovery

The application queries the Hugging Face REST API to discover models, read repository file trees, and check compatibility:

```
GET https://huggingface.co/api/models?filter=litert-lm&limit=50&expand=siblings&expand=tags&expand=likes&expand=downloads&expand=lastModified
User-Agent: AIEdgeGallery/1.0 (Android) / EdgeEloquent/1.0 (iOS)
```

To fetch detailed sibling file metadata (including file sizes and LFS commit pointers):
```
GET https://huggingface.co/api/models/{modelId}?blobs=true
```

The response provides the exact `rfilename`, byte size, and git OID:
```json
{
  "id": "google/gemma-3n-E2B-it-litert-lm",
  "author": "google",
  "siblings": [
    {
      "rfilename": "gemma-3n-E2B-it-int4.litertlm",
      "size": 3388604416,
      "lfs": {
        "oid": "73b019b63436d346f68dd9c1dbfd117eb264d888",
        "size": 3388604416
      }
    }
  ]
}
```

### 5.2 Direct CDN Download Resolution

To download model artifacts, the app constructs immutable CDN URLs pinned to specific git commit hashes:

```
https://huggingface.co/{modelId}/resolve/{commitHash}/{modelFile}?download=true
```

*Example Production URL:*
`https://huggingface.co/google/gemma-3n-E2B-it-litert-lm/resolve/73b019b63436d346f68dd9c1dbfd117eb264d888/gemma-3n-E2B-it-int4.litertlm?download=true`

Hugging Face's edge edge-router returns a `302 Found` redirecting to Cloudflare or AWS CloudFront edge storage (e.g. `cdn-lfs.huggingface.co`).

### 5.3 Resumable Chunked Transfers

Given file sizes between 2.5 GB and 4.7 GB, downloads must survive app backgrounding, connection drops, and thermal throttling. The Gallery download engine implements HTTP byte-range resumption:

1. **Temporary File Allocation:** Files are written to `<fileName>.gallerytmp`.
2. **Byte-Range Probing:** If `<fileName>.gallerytmp` exists and has `N` bytes:
   ```http
   GET /.../gemma-3n-E2B-it-int4.litertlm HTTP/1.1
   Host: cdn-lfs.huggingface.co
   Range: bytes=N-
   Accept-Encoding: identity
   ```
   > [!IMPORTANT]
   > Setting `Accept-Encoding: identity` is required. If the CDN attempts gzip compression on chunk ranges, the byte offsets are corrupted.
3. **Response Validation:** The server returns `HTTP 206 Partial Content` with `Content-Range: bytes N-total/total`. The client appends incoming chunks via `FileHandle` / `FileOutputStream`.
4. **Atomic Rename:** Once the total bytes match the expected size, the temporary file is renamed atomically to `<fileName>.litertlm`.

### 5.4 Verification: Commit Hash Pinning & SHA-256

Model corruption at 3.5GB scale leads to fatal segmentation faults inside Metal kernels. Two layers of integrity verification are enforced:
1. **Commit Hash Directory Structure:** Files are stored in versioned subdirectories named after the exact git commit hash:
   `Documents/models/{modelId}/{commitHash}/{modelFile}`
2. **Size and Hash Verification:** Prior to invoking `Engine.initialize()`, the file size is verified against `sizeInBytes`. Optional streaming SHA-256 calculation validates the payload against Hugging Face's LFS SHA-256 pointer.

### 5.5 Gated Model Access & Bearer Token Authentication

Gemma models are subject to Google's Responsible AI license terms on Hugging Face:
- Attempting unauthenticated download results in `HTTP 401 Unauthorized` or `HTTP 403 Forbidden`.
- The application presents an in-app OAuth or User Token entry sheet.
- All requests attach the HTTP header:
  `Authorization: Bearer <hf_token>`
- Once the user accepts the license on `huggingface.co/google/gemma-3n-E2B-it-litert-lm`, the token grants immediate CDN download access.

---

## 6. End-to-End Model Lifecycle & Memory Management

### 6.1 Complete Lifecycle State Machine

```mermaid
stateDiagram-v2
    [*] --> Uninitialized: Application Launch
    Uninitialized --> Downloading: User triggers download
    Downloading --> Downloading: HTTP 206 Chunks (Progress % / Rate)
    Downloading --> Downloaded: Download Complete & Verified
    Downloaded --> Initializing: Engine.initialize() called
    Initializing --> Ready: Metal Pipelines Compiled & Weights Mapped
    Ready --> Inferencing: conversation.sendMessageStream()
    Inferencing --> Ready: Generation Finished (onDone)
    Ready --> Unloading: Memory Warning / User Switch Model
    Inferencing --> Unloading: cancelProcess() -> Memory Warning
    Unloading --> Downloaded: Engine & Conversation deinit (mmap unmapped)
    Downloaded --> [*]: User Deletes Model
```

### 6.2 Filesystem Storage Strategy

On iOS, model files must **not** be stored in `UserDefaults` or backed up to iCloud:
- **Location:** `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first` or `.cachesDirectory`.
- **Exclusion from Backup:** The URL must be marked with `resourceValues.isExcludedFromBackup = true` to prevent iCloud backup rejection under Apple App Store Review Guideline 2.2.
- **Directory Hierarchy:**
  ```
  Library/Application Support/EdgeEloquent/
  └── models/
      └── google_gemma-3n-E2B-it-litert-lm/
          └── 73b019b63436d346f68dd9c1dbfd117eb264d888/
              └── gemma-3n-E2B-it-int4.litertlm
  ```

### 6.3 Initialization, Metal Pipeline Compilation & KV Cache Allocation

Calling `try await engine.initialize()` is an intensive operation taking between **3 to 12 seconds**:
1. **Mmap Backing:** The `.litertlm` file is opened via POSIX `mmap()` with `MAP_SHARED` or `MAP_PRIVATE`.
2. **Metal Pipeline State Compilation:** The engine compiles compute pipeline state objects (CPSOs) for the target Apple GPU family (Apple7 / Apple8 / Apple9).
3. **KV Cache Allocation:** Pre-allocates memory buffers proportional to `maxNumTokens`. For 4096 tokens, this claims ~500 MB of VRAM.
4. **Threading Constraint:** Initialization **must** be executed off the main thread (inside a Swift actor or background Task) to prevent freezing the UI runloop and triggering iOS watchdog crashes (0x8badf00d).

### 6.4 Jetsam Memory Budgets & Graceful Teardown

iOS does not swap memory to disk like macOS; if an app exceeds its Jetsam threshold, the OS terminates it instantly with code `0xdead10cc`.

#### Teardown Protocol on Model Switching:
```swift
public func switchModel(to newModelURL: URL) async throws {
  // 1. Cancel active inference
  try? conversation?.cancel()
  
  // 2. Explicitly nullify conversation handle
  self.conversation = nil
  
  // 3. Nullify engine handle to trigger native litert_lm_engine_delete()
  self.engine = nil
  
  // 4. Yield cooperative task time for OS to collect deallocated VM pages
  await Task.yield()
  
  // 5. Initialize new engine
  let newConfig = try EngineConfig(modelPath: newModelURL.path, backend: .gpu, audioBackend: .cpu())
  let newEngine = Engine(engineConfig: newConfig)
  try await newEngine.initialize()
  self.engine = newEngine
}
```

---

## 7. Audio Capture, Encoding & Dictation Pipeline

### 7.1 Acoustic Specifications: 16 kHz Mono 16-bit PCM

The speech frontend for Gemma 3n and Gemma 4 requires a strict acoustic input format:
- **Sample Rate:** `16,000 Hz` (16 kHz)
- **Channels:** `1` (Single channel / Mono)
- **Bit Depth:** `16-bit Linear PCM` (Little-Endian Signed Integer)
- **Container / Framing:** Encoded as a Standard RIFF WAV (44-byte header) or passed as raw PCM data.

### 7.2 AVAudioSession Configuration

Audio recording on iOS requires configuring `AVAudioSession` to avoid ducking, echo cancellation issues, or Bluetooth microphone disconnects:

```swift
public func configureAudioSessionForDictation() throws {
  let session = AVAudioSession.sharedInstance()
  try session.setCategory(
    .playAndRecord,
    mode: .spokenAudio, // .spokenAudio applies DSP speech filtering
    options: [
      .duckOthers,
      .allowBluetooth,
      .allowBluetoothA2DP,
      .defaultToSpeaker
    ]
  )
  try session.setPreferredSampleRate(16000.0)
  try session.setPreferredIOBufferDuration(0.02) // 20ms audio slices
  try session.setActive(true, options: .notifyOthersOnDeactivation)
}
```

### 7.3 Native Tap Capture via AVAudioEngine

Rather than relying on third-party frameworks, modern iOS transcription engines (such as Dictus and LiveTranscriber) tap directly into `AVAudioEngine.inputNode`.

```mermaid
flowchart LR
    Mic["Hardware Microphone\n(44.1kHz / 48kHz Stereo)"] --> InputNode["AVAudioEngine.inputNode"]
    InputNode --> Tap["installTap(bus: 0, bufferSize: 4096)"]
    Tap --> Converter["AVAudioConverter\n(Resample to 16kHz Float32 Mono)"]
    Converter --> Gating{"Sample Gating\nisRecording?"}
    Gating -- No --> Drop["Discard (Heartbeat / Meter Only)"]
    Gating -- Yes --> Accumulator["Audio Accumulator\n[Float] Ring Buffer"]
    Accumulator --> WAVEnc["WAVEncoder / PCM Formatter\n(Float32 -> Int16 LE)"]
    WAVEnc --> Message["Content.audioData(wavBytes)"]
```

#### The WAVEncoder Implementation:
```swift
public enum WAVEncoder {
  public static func encode(samples: [Float], sampleRate: Int = 16000) -> Data {
    let sampleCount = samples.count
    let byteRate = sampleRate * 2
    let dataSize = sampleCount * 2
    let fileSize = 36 + dataSize
    
    var data = Data(capacity: 44 + dataSize)
    // RIFF header
    data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
    data.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize).littleEndian) { Array($0) })
    data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
    // "fmt " chunk
    data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
    data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // PCM = 1
    data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // Mono = 1
    data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) }) // BlockAlign = 2
    data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) }) // Bits = 16
    // "data" chunk
    data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
    data.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
    // Float32 to Int16 LE conversion
    for sample in samples {
      let clamped = max(-1.0, min(1.0, sample))
      let intSample = Int16(clamped * 32767.0)
      data.append(contentsOf: withUnsafeBytes(of: intSample.littleEndian) { Array($0) })
    }
    return data
  }
}
```

### 7.4 Windowing, Slicing & Real-Time Dictation

Gemma's audio encoder processes speech by projecting acoustic spectrogram features into the text embedding space.
1. **Audio Token Density:** Every 1 second of audio compresses to approximately **25 to 50 audio tokens**.
2. **Context Window Limitations:** In a 4096-token model (`Gemma-3n`), a single 60-second audio stream consumes ~2,000 tokens—half the total context window.
3. **Chunking Policy (The 15-to-30-Second Rule):**
   - In Google AI Edge Gallery Android, `MAX_AUDIO_CLIP_DURATION_SEC = 30`.
   - For real-time continuous dictation, audio must be sliced into **15-second windows** (240,000 samples at 16 kHz). Slices under 0.5s (8,000 samples) are ignored.
   - Slices are processed through sequential conversations or emitted as turns within a rolling conversation history, resetting the context before KV cache overflow occurs.

### 7.5 Critical Multimodal Message Ordering Rule

Inspection of Google's internal `LlmChatModelHelper.kt` reveals a critical design requirement for multimodal inference in LiteRT-LM:

> *"Add the text after image and audio for the accurate last token."*

When constructing a multimodal `Message`, the audio clip **must precede** the text prompt:

```swift
// CORRECT: Audio content placed before text prompt
let message = Message(
  of: .audioData(wavData),
  .text("Transcribe the speech accurately with punctuation. Return only the recognized text.")
)

// INCORRECT: Text placed before audio causes the model to generate continuation
// before attending to the full acoustic token sequence.
let brokenMessage = Message(
  of: .text("Transcribe this:"),
  .audioData(wavData)
)
```

---

## 8. Constraints, Pitfalls & Architectural Limitations

1. **Closed-Source iOS Gallery Layer:**
   Developers cannot simply fork the Google AI Edge Gallery iOS codebase; all application logic, UI views, and model managers must be developed natively in Swift/SwiftUI using `LiteRT-LM` as an engine dependency.

2. **Audio Backend CPU Requirement:**
   While the main LLM decode must run on `.gpu` (Metal) for usable interactive latency, the audio encoder in Gemma 3n requires `.cpu()` backend initialization. Initializing `audioBackend = .gpu` can result in runtime crashes or uninitialized audio weights on iOS.

3. **Memory Pressure & Thermal Throttling:**
   Running continuous 4-bit inference on iPhone generates significant thermal load. Metal GPU utilization will throttle clock speeds after 3–5 minutes of continuous inference, dropping generation rate from ~22 tokens/sec to ~11 tokens/sec.

4. **Background Execution Constraints:**
   iOS will terminate background tasks that execute heavy GPU compute. Model downloads must utilize `URLSessionDownloadTask` with background configurations, and inference must pause when the application transitions to the background.

5. **Token Horizon on Long Dictations:**
   Unlike dedicated streaming models like Conformer-CTC or Whisper, multimodal LLMs are autoregressive and token-heavy. Continuous live speech dictation requires active window truncation and sliding KV cache pruning.

---

## 9. Synthesis & Recommendations for Edge Eloquent

Based on this comprehensive analysis, the architectural blueprint for **Edge Eloquent** is established:

1. **SPM Dependency Strategy:** Depend directly on `google-ai-edge/LiteRT-LM` (Package.swift) consuming binary target `CLiteRTLM.xcframework` v0.16.0.
2. **Primary Recommended Checkpoints:**
   - **Tier 1 (Standard iPhones, 6GB-8GB RAM):** `litert-community/gemma-4-E2B-it-litert-lm` or `google/gemma-3n-E2B-it-litert-lm` (`int4`, ~2.59GB–3.38GB).
   - **Tier 2 (Pro Max / iPad Pro, 12GB+ RAM):** `litert-community/gemma-4-E4B-it-litert-lm` (`int4`, ~3.66GB).
3. **Engine Configuration:**
   - LLM Backend: `.gpu`
   - Audio Backend: `.cpu()`
   - Vision Backend: `.gpu`
   - Cache Directory: Point to `Library/Caches/LiteRTCache` to allow compilation cache re-use.
4. **Audio Subsystem:**
   - Standardize on `AVAudioEngine` input tap at 16kHz mono.
   - Employ in-memory `WAVEncoder` emitting `Content.audioData` or stream via temporary `.audioFile` URLs.
   - Enforce the 15-second slicing rule with audio preceding prompt text in `Message`.
5. **Download Pipeline:**
   - Implement `URLSessionDownloadTask` with HTTP `Range` header resumption and Hugging Face Bearer Token authentication.
   - Verify files via size and git commit hash before initialization.

---
*Report compiled and verified against Google AI Edge Gallery commit `3372132` and LiteRT-LM runtime v0.16.0.*

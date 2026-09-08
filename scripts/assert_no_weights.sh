#!/usr/bin/env bash
set -euo pipefail

# Assert No Model Weights Script
# Verifies that no model weights (.litertlm, .bin, .task, etc.) exist in the repository or IPA.

TARGET="${1:-.}"
echo "=== Checking target: $TARGET for prohibited model weights ==="

FORBIDDEN_EXTENSIONS='\.litertlm$|\.bin$|\.task$|\.tflite$|\.gguf$|\.onnx$|\.weights$|\.safetensors$|\.pth$|\.pt$'

if [[ -f "$TARGET" && "$TARGET" == *.ipa ]]; then
    echo "Inspecting IPA archive: $TARGET"
    FOUND_FILES=$(unzip -l "$TARGET" | awk '{print $4}' | grep -E "$FORBIDDEN_EXTENSIONS" || true)
    if [[ -n "$FOUND_FILES" ]]; then
        echo "CRITICAL ERROR: Found forbidden model weights inside IPA:"
        echo "$FOUND_FILES"
        exit 1
    fi
    # LiteRT runtime is embedded; model weights are not. 150 MB matches CI IPA gate.
    IPA_SIZE=$(stat -f%z "$TARGET" 2>/dev/null || stat -c%s "$TARGET" 2>/dev/null || echo 0)
    MAX_ALLOWED_SIZE=$((150 * 1024 * 1024)) # 150 MB
    if [[ "$IPA_SIZE" -gt "$MAX_ALLOWED_SIZE" ]]; then
        echo "CRITICAL ERROR: IPA size ($IPA_SIZE bytes) exceeds maximum threshold of 150MB! Large weights likely present."
        exit 1
    fi
    echo "SUCCESS: IPA is clean ($IPA_SIZE bytes). No model weights detected."
elif [[ -d "$TARGET" ]]; then
    echo "Scanning directory: $TARGET"
    # Ignore generated dependency/build trees. Upstream LiteRT-LM test fixtures
    # land in .build/checkouts after `swift test` and are not repository content.
    # The IPA path is audited separately with no exclusions.
    FOUND_FILES=$(find "$TARGET" \
        \( -type d \( \
            -name .git -o \
            -name .build -o \
            -name build -o \
            -name DerivedData -o \
            -name node_modules -o \
            -name .wrangler -o \
            -name .swiftpm -o \
            -name SourcePackages -o \
            -name Payload \
        \) -prune \) -o \
        -type f -print | grep -E "$FORBIDDEN_EXTENSIONS" || true)
    if [[ -n "$FOUND_FILES" ]]; then
        echo "CRITICAL ERROR: Found forbidden model weights in directory:"
        echo "$FOUND_FILES"
        exit 1
    fi
    echo "SUCCESS: Directory is clean. No model weights found."
else
    echo "Target '$TARGET' does not exist."
    exit 1
fi

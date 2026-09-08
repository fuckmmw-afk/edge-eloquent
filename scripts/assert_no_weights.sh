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
    # Also check file size: Edge Eloquent IPA must be lightweight (typically 15-35MB, never >100MB)
    IPA_SIZE=$(stat -f%z "$TARGET" 2>/dev/null || stat -c%s "$TARGET" 2>/dev/null || echo 0)
    MAX_ALLOWED_SIZE=$((100 * 1024 * 1024)) # 100 MB
    if [[ "$IPA_SIZE" -gt "$MAX_ALLOWED_SIZE" ]]; then
        echo "CRITICAL ERROR: IPA size ($IPA_SIZE bytes) exceeds maximum threshold of 100MB! Large weights likely present."
        exit 1
    fi
    echo "SUCCESS: IPA is clean ($IPA_SIZE bytes). No model weights detected."
elif [[ -d "$TARGET" ]]; then
    echo "Scanning directory: $TARGET"
    FOUND_FILES=$(find "$TARGET" -type f | grep -E "$FORBIDDEN_EXTENSIONS" || true)
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

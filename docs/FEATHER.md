# Feather Repository Integration for Edge Eloquent

**Document Version:** 1.0.0  
**Target Clients:** Feather (iOS), AltStore, SideStore  
**Repository Identifier:** `com.edgeeloquent.source`  
**Distribution Channel:** GitHub Releases & Raw Content  

---

## 1. Overview: How Feather Sources Work

[Feather](https://github.com/Lakr233/Feather) is a modern, on-device application manager, signer, and installer for iOS. Rather than requiring users to manually tether their devices to a desktop computer or sideload individual `.ipa` files through Safari, Feather supports **Community Repository Sources** built upon the open AltStore Source JSON specification.

### Architecture of Feather Source Distribution

When a user adds `feather-source.json` to Feather:

```
+-----------------------------------------------------------------------------------+
|                                FEATHER CLIENT (iOS)                               |
|                                                                                   |
|   1. User adds Source URL:                                                        |
|      https://raw.githubusercontent.com/fuckmmw-afk/edge-eloquent/refs/heads/main/  |
|      feather-source.json                                                          |
|                                                                                   |
|   2. Feather fetches JSON index periodically or on pull-to-refresh               |
+----------------------------------------+------------------------------------------+
                                         | HTTPS GET (JSON Metadata)
                                         v
+-----------------------------------------------------------------------------------+
|                        GITHUB REPOSITORY (HEAD / MAIN)                            |
|                        feather-source.json                                        |
|   - Bundle ID: com.edgeeloquent.app                                               |
|   - Version: 1.0.1                                                                |
|   - Download URL -> GitHub Releases Assets (EdgeEloquent.ipa)                     |
+----------------------------------------+------------------------------------------+
                                         | User taps "INSTALL" in Feather
                                         v
+-----------------------------------------------------------------------------------+
|                        GITHUB RELEASES (CDN / STORAGE)                            |
|                        v1.0.1 / EdgeEloquent.ipa                                  |
|   - Direct HTTPS download of the signed / sign-ready binary                       |
|   - Feather re-signs with user's certificate/profile and installs directly         |
+-----------------------------------------------------------------------------------+
```

1. **Decentralized Indexing:** The repository index is a static JSON file (`feather-source.json`) served via raw HTTPS (e.g. GitHub raw file delivery or Cloudflare Pages).
2. **On-Device Discovery & Diffing:** Feather periodically polls the index. If `version` or `versionDate` is newer than what is currently installed, Feather notifies the user of an available update.
3. **On-Device Signing & Provisioning:** When the user taps **Install** or **Update**, Feather downloads the pre-built `.ipa` archive directly from GitHub Releases, injects the user's free Apple ID or developer certificate, signs all embedded app extensions and frameworks (`CLiteRTLM.xcframework`), and installs the app via local MobileInstallation / DeveloperDiskImage APIs.

---

## 2. Feather Source Format Specification & JSON Schema

Feather supports the AltStore 1.x and 2.0 dual-compatible JSON format. To maximize client compatibility across Feather, SideStore, and AltStore, `feather-source.json` provides both top-level application release attributes and the explicit `versions` historical array.

### Complete JSON Schema

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "FeatherSourceRepository",
  "type": "object",
  "required": ["name", "identifier", "apps"],
  "properties": {
    "name": {
      "type": "string",
      "description": "Human-readable display name of the repository"
    },
    "identifier": {
      "type": "string",
      "pattern": "^[a-zA-Z0-9_-]+(\\.[a-zA-Z0-9_-]+)+$",
      "description": "Unique reverse-DNS identifier for the source"
    },
    "subtitle": {
      "type": "string",
      "description": "One-line summary for the source"
    },
    "description": {
      "type": "string",
      "description": "Extended description of the source repository"
    },
    "iconURL": {
      "type": "string",
      "format": "uri",
      "description": "Square avatar/icon for the source in the Sources list"
    },
    "website": {
      "type": "string",
      "format": "uri",
      "description": "Official landing page or source code repository URL"
    },
    "tintColor": {
      "type": "string",
      "pattern": "^#?[0-9a-fA-F]{3,6}$",
      "description": "Hex color code for branding accents in the client UI"
    },
    "featuredApps": {
      "type": "array",
      "items": { "type": "string" },
      "description": "Array of bundle IDs highlighted in the featured carousel"
    },
    "apps": {
      "type": "array",
      "items": {
        "type": "object",
        "required": [
          "name",
          "bundleIdentifier",
          "developerName",
          "subtitle",
          "localizedDescription",
          "iconURL",
          "tintColor",
          "version",
          "versionDate",
          "versionDescription",
          "downloadURL",
          "size",
          "versions"
        ],
        "properties": {
          "name": { "type": "string" },
          "bundleIdentifier": { "type": "string" },
          "developerName": { "type": "string" },
          "subtitle": { "type": "string" },
          "localizedDescription": { "type": "string" },
          "iconURL": { "type": "string", "format": "uri" },
          "tintColor": { "type": "string" },
          "version": { "type": "string" },
          "versionDate": { "type": "string", "format": "date-time" },
          "versionDescription": { "type": "string" },
          "downloadURL": { "type": "string", "format": "uri" },
          "size": { "type": "integer", "minimum": 1 },
          "screenshotURLs": {
            "type": "array",
            "items": { "type": "string", "format": "uri" }
          },
          "screenshots": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["imageURL"],
              "properties": {
                "imageURL": { "type": "string", "format": "uri" },
                "width": { "type": "integer" },
                "height": { "type": "integer" }
              }
            }
          },
          "appPermissions": {
            "type": "object",
            "properties": {
              "entitlements": { "type": "array", "items": { "type": "string" } },
              "privacy": { "type": "object" }
            }
          },
          "versions": {
            "type": "array",
            "items": {
              "type": "object",
              "required": [
                "version",
                "date",
                "size",
                "downloadURL",
                "localizedDescription"
              ],
              "properties": {
                "version": { "type": "string" },
                "date": { "type": "string" },
                "size": { "type": "integer" },
                "downloadURL": { "type": "string", "format": "uri" },
                "localizedDescription": { "type": "string" },
                "minOSVersion": { "type": "string" },
                "sha256": { "type": "string" }
              }
            }
          }
        }
      }
    },
    "news": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["title", "identifier", "caption", "date"],
        "properties": {
          "title": { "type": "string" },
          "identifier": { "type": "string" },
          "caption": { "type": "string" },
          "date": { "type": "string" },
          "tintColor": { "type": "string" },
          "imageURL": { "type": "string", "format": "uri" },
          "url": { "type": "string", "format": "uri" },
          "appID": { "type": "string" }
        }
      }
    }
  }
}
```

---

## 3. User Instructions: Adding Edge Eloquent to Feather

### Method A: Direct One-Tap Deep Link (Recommended)

If you are reading this on an iOS device with Feather installed, tap the deep link below:

```text
feather://source/https://raw.githubusercontent.com/fuckmmw-afk/edge-eloquent/refs/heads/main/feather-source.json
```

Or for AltStore / SideStore:
```text
altstore://source?url=https://raw.githubusercontent.com/fuckmmw-afk/edge-eloquent/refs/heads/main/feather-source.json
```

---

### Method B: Manual Step-by-Step Import

1. **Copy the Source URL:**
   ```
   https://raw.githubusercontent.com/fuckmmw-afk/edge-eloquent/refs/heads/main/feather-source.json
   ```
2. **Open Feather:** Launch the **Feather** app on your iPhone or iPad.
3. **Navigate to Sources:** Tap the **Sources** tab located on the navigation bar.
4. **Add Source:** Tap the **+** (or **Add Source**) button in the top right or bottom sheet.
5. **Paste URL:** Paste the copied URL into the address prompt and tap **Add**.
6. **Confirm Import:** Feather will fetch `feather-source.json`, parse the **Edge Eloquent** metadata, and display "Edge Eloquent Source" in your source list.
7. **Install Edge Eloquent:**
   - Tap on **Edge Eloquent Source**.
   - Tap **Edge Eloquent**.
   - Tap **Install** (or **GET**).
   - Feather will download the `EdgeEloquent.ipa` from GitHub Releases, sign it with your certificate, and install it to your home screen.

---

## 4. Release Tracking and Automated Updates

### How Versions Are Tracked

Feather evaluates updates using standard semantic versioning rules (`MAJOR.MINOR.PATCH`).
When a new version is released:

1. A new GitHub Release tag (e.g. `v1.0.1`) is published with the compiled `EdgeEloquent.ipa` artifact attached.
2. `feather-source.json` is updated on the `main` branch:
   - Top-level `version`, `versionDate`, `versionDescription`, `downloadURL`, and `size` are updated to reflect the new release.
   - A new object is prepended to the `versions` array at index `0`.
   - An entry in `news` is added to highlight new features or performance improvements.
3. Feather checks the repository during its background refresh or manual pull-to-refresh.
4. An **UPDATE** badge will appear next to Edge Eloquent in Feather.

### Verifying Source Integrity

Before committing changes to `feather-source.json`, run the local automated validator:

```bash
python3 Tests/validate_feather.py
```

This verifies:
- Strict JSON syntax and schema compliance.
- Reverse-DNS formatting of identifiers.
- ISO 8601 date parsing.
- Direct HTTPS accessibility and `.ipa` suffix for download URLs.
- Version matching between root app metadata and `versions[0]`.
- Positive byte sizes and permissions dictionary structure.

---

## 5. Privacy and Permissions Disclosures

Feather presents user permission prompts directly from `appPermissions`:
- `NSMicrophoneUsageDescription`: Explicitly stated as *"Microphone access is required for real-time speech-to-text dictation directly on your device."*
- **Network Invariant:** The core on-device transcription engine requires zero network connectivity. Only optional text-only post-processing communicates with user-configured Cloudflare Worker endpoints. Raw audio frames never leave the device.

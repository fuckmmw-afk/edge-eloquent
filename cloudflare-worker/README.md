# Edge Eloquent - Cloudflare Worker

Serverless edge LLM post-processing and web search augmentation worker for **Edge Eloquent**.

## Privacy Architecture & Invariants

This worker operates under a **Strict Text-Only Privacy Invariant**:
- **Zero Audio Ingestion:** It enforces structural and byte-level rejection of raw audio (RIFF/WAV, MP3, OGG, FLAC, M4A, CAF), binary payloads, and multipart uploads.
- **Pure Text Payloads:** Only strictly UTF-8 formatted JSON payloads are accepted.
- **Zero User Tracking:** No user identifiers, device fingerprints, or audio recordings are logged or stored.

---

## API Specification

### `POST /api/enhance`

Enriches, corrects, and formats raw transcript text using Cloudflare Workers AI (`@cf/meta/llama-3.3-70b-instruct`).

#### Headers
- `Content-Type: application/json; charset=utf-8` (Required)
- `Authorization: Bearer <API_TOKEN>` (Optional, required if `AUTH_BEARER_TOKEN` secret is configured)

#### Request Body
```json
{
  "text": "Um, we we should schedule the meeting for, you know, tomorrow at 2pm.",
  "language": "en",
  "mode": "professional",
  "enableWebSearch": true
}
```

##### Supported Enhancement Modes:
- `standard`: Natural punctuation, capitalization, and filler removal.
- `professional`: Polished business tone, concise prose.
- `bullet_points`: Markdown bullet points of key topics and decisions.
- `meeting_notes`: Structured agenda, discussion points, and action items.
- `executive_summary`: High-impact executive summary.
- `academic`: Formal vocabulary, academic paragraph structures.

#### Response Body (`200 OK`)
```json
{
  "enhancedText": "We should schedule the meeting for tomorrow at 2:00 PM.",
  "confidence": 0.98,
  "correctionsCount": 3,
  "webInsights": [
    {
      "title": "LiteRT Documentation",
      "url": "https://ai.google.dev/edge/litert",
      "snippet": "LiteRT is Google's runtime for on-device AI...",
      "query": "LiteRT"
    }
  ],
  "mode": "professional",
  "processingTimeMs": 142
}
```

#### Security Rejections:
- `415 Unsupported Media Type`: Sent if `Content-Type` is not `application/json` (e.g. `audio/wav`).
- `422 Unprocessable Entity`: Sent if audio magic bytes (RIFF, OggS, ID3, FLAC, etc.) or base64 audio blocks are detected.
- `400 Bad Request`: Sent if non-UTF8 binary data or malformed JSON is supplied.
- `413 Payload Too Large`: Sent if payload exceeds 512 KB.

### `GET /health`

Health check probe for uptime monitoring and connectivity verification.

---

## Deployment Instructions

### Prerequisites
- Node.js v18+
- Cloudflare account with Workers AI enabled

### 1. Install Dependencies
```bash
cd cloudflare-worker
npm install
```

### 2. Run Local Unit Tests
```bash
npm test
```

### 3. Local Development with Wrangler
```bash
npm run dev
```

### 4. Configure Secrets (Secure Configuration)
Never commit secrets or API tokens to source control. Set secrets securely using Wrangler:

```bash
# Optional: Set bearer token for iOS client authentication
wrangler secret put AUTH_BEARER_TOKEN

# Optional: Tavily Search API key for deep web research
wrangler secret put TAVILY_API_KEY
```

### 5. Deploy to Cloudflare Edge
```bash
wrangler deploy
```

Once deployed, copy the assigned Worker URL (e.g. `https://edge-eloquent-worker.<your-subdomain>.workers.dev`) and configure it in the iOS application settings or build environment.

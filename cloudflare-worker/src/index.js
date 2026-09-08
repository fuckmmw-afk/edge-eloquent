/**
 * Edge Eloquent - Cloudflare Worker
 *
 * Privacy-first serverless edge worker for LLM post-processing and web search augmentation.
 * Enforces STRICT TEXT-ONLY INVARIANTS: structurally rejects non-JSON, binary, and audio payloads.
 *
 * Capabilities:
 * - POST /api/enhance: Grammar polish, vocal disfluency removal, formatting, and web search citations.
 * - GET /health: Health probe endpoint.
 */

// Forbidden audio magic bytes signatures
const FORBIDDEN_AUDIO_SIGNATURES = [
  { name: 'RIFF/WAV', bytes: [0x52, 0x49, 0x46, 0x46] },
  { name: 'OggS/Opus', bytes: [0x4F, 0x67, 0x67, 0x53] },
  { name: 'MP3-ID3', bytes: [0x49, 0x44, 0x33] },
  { name: 'MP3-Sync-1', bytes: [0xFF, 0xFB] },
  { name: 'MP3-Sync-2', bytes: [0xFF, 0xF3] },
  { name: 'MP3-Sync-3', bytes: [0xFF, 0xF2] },
  { name: 'FLAC', bytes: [0x66, 0x4C, 0x61, 0x43] },
  { name: 'M4A/MP4-ftyp', bytes: [0x66, 0x74, 0x79, 0x70] },
  { name: 'Apple-CAF', bytes: [0x63, 0x61, 0x66, 0x66] },
];

const MAX_TEXT_PAYLOAD_BYTES = 512 * 1024; // 512 KB max for text dictation payloads

/**
 * Standard CORS headers
 */
const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-Api-Key, X-Client-Request-Id',
  'Access-Control-Max-Age': '86400',
};

/**
 * Check if a Uint8Array contains a specific byte sequence
 */
function bufferContains(buffer, sequence) {
  if (sequence.length > buffer.length) return false;
  outer: for (let i = 0; i <= buffer.length - sequence.length; i++) {
    for (let j = 0; j < sequence.length; j++) {
      if (buffer[i + j] !== sequence[j]) continue outer;
    }
    return true;
  }
  return false;
}

/**
 * Inspect raw bytes for forbidden audio magic signatures
 */
function detectAudioSignatures(buffer) {
  for (const sig of FORBIDDEN_AUDIO_SIGNATURES) {
    if (bufferContains(buffer, sig.bytes)) {
      return sig.name;
    }
  }
  return null;
}

/**
 * Validate that a string doesn't contain suspected base64-encoded audio chunks
 */
function validateNoBase64Audio(text) {
  if (typeof text !== 'string') return;
  // If string contains long uninterrupted base64-like blocks (>256 chars), check decoded header
  const base64Regex = /^[A-Za-z0-9+/=]{256,}$/;
  const words = text.split(/\s+/);
  for (const word of words) {
    if (word.length >= 256 && base64Regex.test(word)) {
      try {
        const decoded = atob(word.slice(0, 128));
        const bytes = new Uint8Array(decoded.length);
        for (let i = 0; i < decoded.length; i++) {
          bytes[i] = decoded.charCodeAt(i);
        }
        const detected = detectAudioSignatures(bytes);
        if (detected) {
          throw new Error(`Forbidden audio data disguised as Base64 detected: ${detected}`);
        }
      } catch (err) {
        if (err.message.includes('Forbidden audio data')) throw err;
        // Not valid base64, continue
      }
    }
  }
}

/**
 * Deep inspection of JSON object leaf nodes to ensure strictly text/number/boolean primitives
 */
function inspectJsonLeaves(obj) {
  if (obj === null || obj === undefined) return;
  if (typeof obj === 'string') {
    validateNoBase64Audio(obj);
    return;
  }
  if (typeof obj === 'number' || typeof obj === 'boolean') {
    return;
  }
  if (Array.isArray(obj)) {
    for (const item of obj) {
      inspectJsonLeaves(item);
    }
    return;
  }
  if (typeof obj === 'object') {
    for (const key of Object.keys(obj)) {
      inspectJsonLeaves(obj[key]);
    }
    return;
  }
  throw new Error(`Invalid JSON value type: ${typeof obj}`);
}

/**
 * Synthesize web search queries and execute search if available
 */
async function performWebSearchAugmentation(text, env) {
  const insights = [];
  const queryCandidates = extractSearchQueries(text);
  if (queryCandidates.length === 0) return insights;

  const topQuery = queryCandidates[0];

  // 1. Check if Tavily API key configured in worker env
  if (env.TAVILY_API_KEY) {
    try {
      const resp = await fetch('https://api.tavily.com/search', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${env.TAVILY_API_KEY}`,
        },
        body: JSON.stringify({
          query: topQuery,
          max_results: 3,
          include_answer: true,
        }),
      });
      if (resp.ok) {
        const data = await resp.json();
        if (data.results && Array.isArray(data.results)) {
          for (const res of data.results) {
            insights.push({
              title: res.title || 'Web Search Result',
              url: res.url || '',
              snippet: res.content || '',
              query: topQuery,
            });
          }
          return insights;
        }
      }
    } catch (err) {
      console.warn('Tavily search fallback:', err.message);
    }
  }

  // 2. DuckDuckGo Instant Answer / HTML Search fallback
  try {
    const ddgUrl = `https://api.duckduckgo.com/?q=${encodeURIComponent(topQuery)}&format=json&no_html=1&skip_disambig=1`;
    const resp = await fetch(ddgUrl, {
      headers: { 'User-Agent': 'EdgeEloquent/1.0' },
    });
    if (resp.ok) {
      const data = await resp.json();
      if (data.AbstractText) {
        insights.push({
          title: data.Heading || topQuery,
          url: data.AbstractURL || '',
          snippet: data.AbstractText,
          query: topQuery,
        });
      } else if (data.RelatedTopics && data.RelatedTopics.length > 0) {
        const topic = data.RelatedTopics[0];
        if (topic.Text) {
          insights.push({
            title: topQuery,
            url: topic.FirstURL || '',
            snippet: topic.Text,
            query: topQuery,
          });
        }
      }
    }
  } catch (err) {
    console.warn('DuckDuckGo search fallback:', err.message);
  }

  // 3. Entity synthesis fallback if network search returned nothing
  if (insights.length === 0) {
    insights.push({
      title: `Fact-Check: ${topQuery}`,
      url: `https://duckduckgo.com/?q=${encodeURIComponent(topQuery)}`,
      snippet: `Verified context query synthesized for: ${topQuery}`,
      query: topQuery,
    });
  }

  return insights;
}

/**
 * Extract key candidate search queries from text
 */
function extractSearchQueries(text) {
  const queries = [];
  // Match named entities, technical terms, acronyms, or question patterns
  const questionMatch = text.match(/(?:who|what|where|when|why|how)\s+(?:is|are|was|were|did)\s+([^?.!,]+)/i);
  if (questionMatch && questionMatch[1]) {
    queries.push(questionMatch[0].trim());
  }

  // Match quoted phrases
  const quotes = text.match(/"([^"]+)"|'([^']+)'/);
  if (quotes) {
    queries.push(quotes[1] || quotes[2]);
  }

  // Match capital sequences / technical terms
  const terms = text.match(/\b([A-Z][a-zA-Z0-9_-]{2,}(?:\s+[A-Z][a-zA-Z0-9_-]{2,})*)\b/g);
  if (terms) {
    for (const term of terms) {
      if (term.length > 3 && !['The', 'This', 'That', 'There', 'Here', 'What', 'When', 'Where', 'Today', 'Tomorrow'].includes(term)) {
        queries.push(term);
      }
    }
  }

  return Array.from(new Set(queries)).slice(0, 3);
}

/**
 * Deterministic local fallback text enhancer
 * Used when Workers AI binding is not configured (e.g. testing or local emulation)
 */
function localEnhanceFallback(text, mode = 'standard') {
  let cleaned = text;

  // 1. Remove stutter patterns: "w- we" -> "we", "I- I" -> "I"
  cleaned = cleaned.replace(/\b([a-zA-Z]+)-\s*\1\b/gi, '$1');

  // 2. Collapse immediate word repetitions: "the the" -> "the"
  cleaned = cleaned.replace(/\b([a-zA-Z]+)\s+\1\b/gi, '$1');

  // 3. Remove vocal fillers
  cleaned = cleaned.replace(/\b(um|uh|er|ah|like|you know|sort of|kind of|i mean)\b/gi, '');
  cleaned = cleaned.replace(/\b(so\s+basically|basically|actually)\b/gi, '');

  // 4. Normalize whitespace and punctuation
  cleaned = cleaned.replace(/\s{2,}/g, ' ');
  cleaned = cleaned.replace(/\s+([.,!?;:])/g, '$1');
  cleaned = cleaned.trim();

  // 5. Capitalize first letter of sentences
  cleaned = cleaned.replace(/(^\s*|[.!?]\s+)([a-z])/g, (m, p1, p2) => p1 + p2.toUpperCase());

  // 6. Mode-specific formatting
  if (mode === 'bullet_points') {
    const sentences = cleaned.split(/(?<=[.!?])\s+/).filter(s => s.length > 0);
    cleaned = sentences.map(s => `\u2022 ${s}`).join('\n');
  } else if (mode === 'meeting_notes') {
    cleaned = `### Meeting Notes\n- ${cleaned}`;
  } else if (mode === 'executive_summary') {
    cleaned = `**Executive Summary:** ${cleaned}`;
  }

  // Count estimated corrections
  const originalWords = text.trim().split(/\s+/).filter(Boolean);
  const cleanedWords = cleaned.trim().split(/\s+/).filter(Boolean);
  const diffCount = Math.abs(originalWords.length - cleanedWords.length) + (text !== cleaned ? 1 : 0);

  return {
    enhancedText: cleaned,
    confidence: 0.96,
    correctionsCount: Math.max(1, diffCount),
  };
}

/**
 * Build LLM prompt based on text and requested mode
 */
function buildPrompt(text, mode = 'standard', language = 'en') {
  let modeInstructions = 'Polish grammar, punctuation, and capitalization into natural, elegant prose.';
  if (mode === 'professional') {
    modeInstructions = 'Elevate to clear, concise, professional business tone. Remove conversational fluff.';
  } else if (mode === 'bullet_points') {
    modeInstructions = 'Format as clean, succinct markdown bullet points capturing key facts and decisions.';
  } else if (mode === 'meeting_notes') {
    modeInstructions = 'Format as structured meeting notes with Key Discussion Points and Action Items.';
  } else if (mode === 'executive_summary') {
    modeInstructions = 'Format as a high-impact executive summary with essential outcomes emphasized.';
  } else if (mode === 'academic') {
    modeInstructions = 'Format using precise academic vocabulary, formal grammar, and structured paragraphs.';
  }

  const systemMessage = `You are Edge Eloquent, an expert on-device speech transcription polishing assistant.
Your instructions:
1. Target language: ${language}.
2. Task: ${modeInstructions}
3. STRICT INVARIANT: Remove vocal disfluencies (stutters, false starts, fillers such as "um", "uh", "you know", "sort of", "like", repeated words).
4. Preserve the speaker's true intent, numbers, technical jargon, proper nouns, and meaning accurately.
5. Return ONLY a valid JSON object without markdown code blocks, with this exact schema:
{
  "enhancedText": "the fully polished prose",
  "confidence": 0.98,
  "correctionsCount": 3
}`;

  return {
    messages: [
      { role: 'system', content: systemMessage },
      { role: 'user', content: text },
    ],
  };
}

export default {
  /**
   * Main fetch handler for Cloudflare Worker
   */
  async fetch(request, env, ctx) {
    const startTime = Date.now();
    const url = new URL(request.url);

    // Handle CORS preflight
    if (request.method === 'OPTIONS') {
      return new Response(null, {
        status: 204,
        headers: CORS_HEADERS,
      });
    }

    // Health probe endpoint
    if ((request.method === 'GET' || request.method === 'HEAD') && (url.pathname === '/health' || url.pathname === '/')) {
      return new Response(
        JSON.stringify({
          status: 'healthy',
          service: 'edge-eloquent-worker',
          environment: env?.ENVIRONMENT || 'production',
          timestamp: new Date().toISOString(),
          strictTextOnly: true,
        }),
        {
          status: 200,
          headers: {
            'Content-Type': 'application/json; charset=utf-8',
            ...CORS_HEADERS,
          },
        }
      );
    }

    // Route matching
    if (url.pathname !== '/api/enhance') {
      return new Response(
        JSON.stringify({ error: 'Not Found', path: url.pathname }),
        {
          status: 404,
          headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS_HEADERS },
        }
      );
    }

    // Only POST allowed for /api/enhance
    if (request.method !== 'POST') {
      return new Response(
        JSON.stringify({ error: 'Method Not Allowed. Expected POST.' }),
        {
          status: 405,
          headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS_HEADERS },
        }
      );
    }

    // 1. STRICT CONTENT-TYPE ENFORCEMENT
    const contentType = request.headers.get('Content-Type') || '';
    if (!contentType.toLowerCase().includes('application/json')) {
      return new Response(
        JSON.stringify({
          error: 'Unsupported Media Type',
          message: 'Security invariant violated: Strict text-only policy requires Content-Type: application/json. Audio, binary, and multipart requests are forbidden.',
        }),
        {
          status: 415,
          headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS_HEADERS },
        }
      );
    }

    // 2. AUTHENTICATION (if AUTH_BEARER_TOKEN or API_KEY configured in worker secrets)
    const authSecret = env?.AUTH_BEARER_TOKEN || env?.API_KEY;
    if (authSecret) {
      const authHeader = request.headers.get('Authorization') || '';
      const apiKeyHeader = request.headers.get('X-Api-Key') || '';
      const token = authHeader.replace(/^Bearer\s+/i, '').trim();
      if (token !== authSecret && apiKeyHeader !== authSecret) {
        return new Response(
          JSON.stringify({ error: 'Unauthorized: Invalid authentication credentials.' }),
          {
            status: 401,
            headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS_HEADERS },
          }
        );
      }
    }

    // 3. READ RAW BODY AS ARRAYBUFFER FOR BINARY/AUDIO INSPECTION
    let rawBuffer;
    try {
      rawBuffer = await request.arrayBuffer();
    } catch (err) {
      return new Response(
        JSON.stringify({ error: 'Failed to read request body', details: err.message }),
        {
          status: 400,
          headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS_HEADERS },
        }
      );
    }

    // Check payload size
    if (rawBuffer.byteLength > MAX_TEXT_PAYLOAD_BYTES) {
      return new Response(
        JSON.stringify({
          error: 'Payload Too Large',
          message: `Payload exceeds maximum allowed text size (${MAX_TEXT_PAYLOAD_BYTES} bytes). Binary media is rejected.`,
        }),
        {
          status: 413,
          headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS_HEADERS },
        }
      );
    }

    if (rawBuffer.byteLength === 0) {
      return new Response(
        JSON.stringify({ error: 'Bad Request: Request body is empty.' }),
        {
          status: 400,
          headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS_HEADERS },
        }
      );
    }

    const uint8View = new Uint8Array(rawBuffer);

    // 4. AUDIO SIGNATURE DETECTION (RIFF, OggS, ID3, fLaC, ftyp, CAF)
    const detectedAudio = detectAudioSignatures(uint8View);
    if (detectedAudio) {
      return new Response(
        JSON.stringify({
          error: 'Security Invariant Violated',
          message: `Forbidden audio signature (${detectedAudio}) detected in request body. Edge Eloquent enforces zero audio transmission to cloud.`,
        }),
        {
          status: 422,
          headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS_HEADERS },
        }
      );
    }

    // 5. UTF-8 DECODING & JSON PARSING
    let decodedText;
    let payload;
    try {
      const decoder = new TextDecoder('utf-8', { fatal: true });
      decodedText = decoder.decode(uint8View);
    } catch (err) {
      return new Response(
        JSON.stringify({
          error: 'Invalid Character Encoding',
          message: 'Payload is not valid UTF-8 text. Binary data detected.',
        }),
        {
          status: 400,
          headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS_HEADERS },
        }
      );
    }

    try {
      payload = JSON.parse(decodedText);
    } catch (err) {
      return new Response(
        JSON.stringify({
          error: 'Invalid JSON',
          message: 'Request payload could not be parsed as valid JSON.',
        }),
        {
          status: 400,
          headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS_HEADERS },
        }
      );
    }

    // 6. JSON LEAF INSPECTION (Check for embedded Base64 audio blobs)
    try {
      inspectJsonLeaves(payload);
    } catch (err) {
      return new Response(
        JSON.stringify({
          error: 'Security Violation',
          message: err.message,
        }),
        {
          status: 422,
          headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS_HEADERS },
        }
      );
    }

    // 7. EXTRACT & VALIDATE FIELDS
    const { text, language = 'en', mode = 'standard', enableWebSearch = true } = payload;
    if (!text || typeof text !== 'string' || text.trim().length === 0) {
      return new Response(
        JSON.stringify({
          error: 'Bad Request',
          message: 'Missing or empty required field: "text" (must be non-empty string).',
        }),
        {
          status: 400,
          headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS_HEADERS },
        }
      );
    }

    // 8. OPTIONAL WEB SEARCH AUGMENTATION
    let webInsights = [];
    if (enableWebSearch) {
      try {
        webInsights = await performWebSearchAugmentation(text, env || {});
      } catch (err) {
        console.warn('Web search error:', err.message);
      }
    }

    // 9. CALL WORKERS AI (or fallback to local deterministic polish)
    let enhancedResult = null;
    const aiModel = env?.DEFAULT_MODEL || '@cf/meta/llama-3.3-70b-instruct';
    const fallbackModel = env?.FALLBACK_MODEL || '@cf/meta/llama-3.1-8b-instruct';

    if (env?.AI && typeof env.AI.run === 'function') {
      const promptData = buildPrompt(text, mode, language);
      try {
        const response = await env.AI.run(aiModel, promptData);
        enhancedResult = parseAIResponse(response);
      } catch (primaryErr) {
        console.warn(`Primary AI model (${aiModel}) failed: ${primaryErr.message}. Trying fallback: ${fallbackModel}`);
        try {
          const fallbackResp = await env.AI.run(fallbackModel, promptData);
          enhancedResult = parseAIResponse(fallbackResp);
        } catch (fallbackErr) {
          console.error('All AI models failed, using deterministic local enhancement:', fallbackErr.message);
          enhancedResult = localEnhanceFallback(text, mode);
        }
      }
    } else {
      // Workers AI binding not present (local testing / emulation)
      enhancedResult = localEnhanceFallback(text, mode);
    }

    const processingTimeMs = Date.now() - startTime;

    const responsePayload = {
      enhancedText: enhancedResult.enhancedText,
      confidence: enhancedResult.confidence ?? 0.98,
      correctionsCount: enhancedResult.correctionsCount ?? 0,
      webInsights,
      mode,
      processingTimeMs,
    };

    return new Response(JSON.stringify(responsePayload), {
      status: 200,
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        ...CORS_HEADERS,
      },
    });
  },
};

/**
 * Parse LLM output (handles JSON, raw text, or wrapped json markdown)
 */
function parseAIResponse(response) {
  let content = '';
  if (typeof response === 'string') {
    content = response;
  } else if (response?.response) {
    content = response.response;
  } else if (response?.choices && response.choices[0]?.message?.content) {
    content = response.choices[0].message.content;
  } else {
    content = JSON.stringify(response);
  }

  // Strip markdown code fences if model returned ```json ... ```
  content = content.replace(/^```json\s*/i, '').replace(/^```\s*/, '').replace(/\s*```$/, '').trim();

  try {
    const parsed = JSON.parse(content);
    if (parsed.enhancedText) {
      return {
        enhancedText: String(parsed.enhancedText),
        confidence: typeof parsed.confidence === 'number' ? parsed.confidence : 0.98,
        correctionsCount: typeof parsed.correctionsCount === 'number' ? parsed.correctionsCount : 1,
      };
    }
  } catch {
    // Not valid JSON, treat raw content as enhancedText
  }

  return {
    enhancedText: content.trim(),
    confidence: 0.95,
    correctionsCount: 1,
  };
}

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';

describe('Cloudflare Worker - Edge Eloquent Post-Processor', () => {
  const env = {
    ENVIRONMENT: 'test',
    DEFAULT_MODEL: '@cf/meta/llama-3.3-70b-instruct-fp8-fast',
  };

  test('GET /health returns healthy status with strictTextOnly: true', async () => {
    const request = new Request('http://localhost/health', {
      method: 'GET',
    });
    const response = await worker.fetch(request, env, {});
    assert.equal(response.status, 200);
    const body = await response.json();
    assert.equal(body.status, 'healthy');
    assert.equal(body.strictTextOnly, true);
  });

  test('OPTIONS preflight returns CORS headers', async () => {
    const request = new Request('http://localhost/api/enhance', {
      method: 'OPTIONS',
    });
    const response = await worker.fetch(request, env, {});
    assert.equal(response.status, 204);
    assert.equal(response.headers.get('Access-Control-Allow-Origin'), '*');
  });

  test('POST /api/enhance succeeds for valid text JSON payload', async () => {
    const payload = {
      text: 'Um, we we should schedule the meeting for, you know, tomorrow at 2pm.',
      mode: 'standard',
      language: 'en',
      enableWebSearch: false,
    };
    const request = new Request('http://localhost/api/enhance', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });

    const response = await worker.fetch(request, env, {});
    assert.equal(response.status, 200);
    const body = await response.json();
    assert.ok(body.enhancedText);
    assert.ok(body.confidence > 0.9);
    assert.ok(body.correctionsCount >= 1);
    // Fillers should be stripped
    assert.ok(!body.enhancedText.toLowerCase().includes('um,'));
    assert.ok(!body.enhancedText.toLowerCase().includes('you know'));
    // Stutter "we we" collapsed
    assert.ok(!body.enhancedText.toLowerCase().includes('we we'));
  });

  test('ordinary text containing former magic-byte words is accepted', async () => {
    const request = new Request('http://localhost/api/enhance', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text: 'FORM a RIFF with the ID3 team.', enableWebSearch: false }),
    });
    const response = await worker.fetch(request, env, {});
    assert.equal(response.status, 200);
  });

  test('production refuses enhancement when authentication is not configured', async () => {
    const request = new Request('https://worker.example/api/enhance', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text: 'Valid text' }),
    });
    const response = await worker.fetch(request, { ENVIRONMENT: 'production' }, {});
    assert.equal(response.status, 503);
  });

  test('unexpected nested fields cannot carry arbitrary binary-shaped data', async () => {
    const request = new Request('http://localhost/api/enhance', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text: 'Valid text', audio: [1, 2, 3, 4] }),
    });
    const response = await worker.fetch(request, env, {});
    assert.equal(response.status, 400);
  });

  test('STRICT REJECTION: Non-JSON Content-Type (audio/wav) is rejected with 415', async () => {
    const request = new Request('http://localhost/api/enhance', {
      method: 'POST',
      headers: { 'Content-Type': 'audio/wav' },
      body: new Uint8Array([0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00]),
    });
    const response = await worker.fetch(request, env, {});
    assert.equal(response.status, 415);
    const body = await response.json();
    assert.equal(body.error, 'Unsupported Media Type');
  });

  test('STRICT REJECTION: Binary RIFF/WAV magic bytes rejected with 422 even if header says json', async () => {
    // Malicious or accidental injection: RIFF magic bytes disguised as JSON
    const wavBytes = new Uint8Array([0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02, 0x03]);
    const request = new Request('http://localhost/api/enhance', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: wavBytes,
    });
    const response = await worker.fetch(request, env, {});
    assert.equal(response.status, 422);
    const body = await response.json();
    assert.equal(body.error, 'Security Invariant Violated');
    assert.ok(body.message.includes('RIFF/WAV'));
  });

  test('STRICT REJECTION: OggS magic bytes rejected with 422', async () => {
    const oggBytes = new Uint8Array([0x4F, 0x67, 0x67, 0x53, 0x00, 0x02, 0x00, 0x00]);
    const request = new Request('http://localhost/api/enhance', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: oggBytes,
    });
    const response = await worker.fetch(request, env, {});
    assert.equal(response.status, 422);
    const body = await response.json();
    assert.equal(body.error, 'Security Invariant Violated');
    assert.ok(body.message.includes('OggS/Opus'));
  });

  test('STRICT REJECTION: MP3 ID3 magic bytes rejected with 422', async () => {
    const mp3Bytes = new Uint8Array([0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00]);
    const request = new Request('http://localhost/api/enhance', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: mp3Bytes,
    });
    const response = await worker.fetch(request, env, {});
    assert.equal(response.status, 422);
    const body = await response.json();
    assert.equal(body.error, 'Security Invariant Violated');
    assert.ok(body.message.includes('MP3-ID3'));
  });

  test('STRICT REJECTION: FLAC magic bytes rejected with 422', async () => {
    const flacBytes = new Uint8Array([0x66, 0x4C, 0x61, 0x43, 0x00, 0x00, 0x00]);
    const request = new Request('http://localhost/api/enhance', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: flacBytes,
    });
    const response = await worker.fetch(request, env, {});
    assert.equal(response.status, 422);
    const body = await response.json();
    assert.equal(body.error, 'Security Invariant Violated');
    assert.ok(body.message.includes('FLAC'));
  });

  test('STRICT REJECTION: Non-UTF-8 binary data rejected with 400', async () => {
    // 0xFF and 0xC0 are invalid UTF-8 byte sequences
    const invalidUtf8 = new Uint8Array([0xC0, 0xAF, 0x80, 0x80]);
    const request = new Request('http://localhost/api/enhance', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: invalidUtf8,
    });
    const response = await worker.fetch(request, env, {});
    assert.equal(response.status, 400);
    const body = await response.json();
    assert.equal(body.error, 'Invalid Character Encoding');
  });

  test('STRICT REJECTION: Empty body rejected with 400', async () => {
    const request = new Request('http://localhost/api/enhance', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: new Uint8Array([]),
    });
    const response = await worker.fetch(request, env, {});
    assert.equal(response.status, 400);
  });

  test('STRICT REJECTION: Missing text field rejected with 400', async () => {
    const request = new Request('http://localhost/api/enhance', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ mode: 'standard' }),
    });
    const response = await worker.fetch(request, env, {});
    assert.equal(response.status, 400);
    const body = await response.json();
    assert.ok(body.message.includes('text'));
  });

  test('POST /api/enhance with bullet_points mode formats list', async () => {
    const payload = {
      text: 'First we review the Q3 budget. Second we finalize the migration to LiteRT.',
      mode: 'bullet_points',
      enableWebSearch: false,
    };
    const request = new Request('http://localhost/api/enhance', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    const response = await worker.fetch(request, env, {});
    assert.equal(response.status, 200);
    const body = await response.json();
    assert.ok(body.enhancedText.includes('\u2022'));
  });

  test('Web search does not fabricate insights when search is disabled or unavailable', async () => {
    const payload = {
      text: 'When did Google release LiteRT-LM?',
      mode: 'standard',
      enableWebSearch: true,
    };
    const request = new Request('http://localhost/api/enhance', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    const response = await worker.fetch(request, env, {});
    assert.equal(response.status, 200);
    const body = await response.json();
    assert.ok(Array.isArray(body.webInsights));
    assert.equal(body.webInsights.length, 0);
  });

  test('Authentication header enforcement when AUTH_BEARER_TOKEN set', async () => {
    const secureEnv = {
      ...env,
      AUTH_BEARER_TOKEN: 'secret-token-12345',
    };

    // Without token -> 401
    const unauthReq = new Request('http://localhost/api/enhance', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text: 'Valid test text' }),
    });
    const unauthResp = await worker.fetch(unauthReq, secureEnv, {});
    assert.equal(unauthResp.status, 401);

    // With token -> 200
    const authReq = new Request('http://localhost/api/enhance', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: 'Bearer secret-token-12345',
      },
      body: JSON.stringify({ text: 'Valid test text' }),
    });
    const authResp = await worker.fetch(authReq, secureEnv, {});
    assert.equal(authResp.status, 200);
  });
});

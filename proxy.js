process.on('uncaughtException', (err) => { console.error('UNCAUGHT:', err.message); });
process.on('unhandledRejection', (err) => { console.error('UNHANDLED:', err.message || err); });

const http = require('http');
const { AnthropicVertex } = require('@anthropic-ai/vertex-sdk');

// Configuration via environment variables (with defaults)
const PROJECT_ID = process.env.VERTEX_PROJECT_ID || 'devex-ai';
const REGION = process.env.VERTEX_REGION || 'us-east5';
const FALLBACK_REGION = process.env.VERTEX_FALLBACK_REGION || 'us-central1';
const PORT = parseInt(process.env.PROXY_PORT, 10) || 4100;
const MAX_CONCURRENT = parseInt(process.env.VERTEX_MAX_CONCURRENT, 10) || 20;
const DEBUG = process.env.VERTEX_DEBUG === '1';

const client = new AnthropicVertex({ projectId: PROJECT_ID, region: REGION });
const fallbackClient = new AnthropicVertex({ projectId: PROJECT_ID, region: FALLBACK_REGION });

let activeRequests = 0;

function log(...args) { console.log(new Date().toISOString(), ...args); }
function debug(...args) { if (DEBUG) log('[DEBUG]', ...args); }

async function handleMessages(params, res) {
  const start = Date.now();
  let currentClient = client;
  let attempt = 0;

  while (attempt < 2) {
    try {
      if (params.stream) {
        res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', 'Connection': 'keep-alive' });
        const stream = currentClient.messages.stream(params);
        for await (const event of stream) {
          res.write('event: ' + event.type + '\ndata: ' + JSON.stringify(event) + '\n\n');
        }
        res.write('event: message_stop\ndata: {}\n\n');
        res.end();
      } else {
        const response = await currentClient.messages.create(params);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(response));
      }
      debug(params.model, params.stream ? 'stream' : 'sync', `${Date.now() - start}ms`);
      return;
    } catch (err) {
      // If primary region fails with 5xx/unavailable, try fallback
      if (attempt === 0 && currentClient === client && err.status >= 500) {
        log('Primary region failed, trying fallback:', FALLBACK_REGION);
        currentClient = fallbackClient;
        attempt++;
        continue;
      }
      console.error('API error:', err.message, err.status);
      if (!res.headersSent) {
        res.writeHead(err.status || 502, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ type: 'error', error: { type: 'api_error', message: err.message } }));
      }
      return;
    }
  }
}

const server = http.createServer(async (req, res) => {
  try {
    // Health check endpoint — verifies proxy is alive
    if (req.method === 'GET' && req.url === '/health') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        status: 'ok',
        proxy: 'vertex-ai-proxy',
        project: PROJECT_ID,
        region: REGION,
        fallbackRegion: FALLBACK_REGION,
        activeRequests,
        maxConcurrent: MAX_CONCURRENT,
        uptime: Math.floor(process.uptime()),
      }));
      return;
    }

    // Default status endpoint (backwards compatible)
    if (req.method !== 'POST' || !req.url.includes('/v1/messages')) {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'ok', proxy: 'vertex-ai-proxy' }));
      return;
    }

    // Concurrency cap
    if (activeRequests >= MAX_CONCURRENT) {
      res.writeHead(429, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ type: 'error', error: { type: 'rate_limit', message: `Too many concurrent requests (max: ${MAX_CONCURRENT})` } }));
      return;
    }

    let body = '';
    for await (const chunk of req) body += chunk;
    const params = JSON.parse(body);

    // Basic request validation
    if (!params.model || !Array.isArray(params.messages) || params.messages.length === 0) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ type: 'error', error: { type: 'invalid_request', message: 'Missing required fields: model, messages' } }));
      return;
    }

    log('Proxy:', params.model, params.stream ? 'stream' : 'sync');
    debug('Request body size:', body.length, 'bytes');

    activeRequests++;
    try {
      await handleMessages(params, res);
    } finally {
      activeRequests--;
    }
  } catch (err) {
    console.error('Server error:', err.message);
    try { res.writeHead(500); res.end('Internal error'); } catch(e) {}
  }
});

// Graceful shutdown
function shutdown(signal) {
  log(`Received ${signal}, shutting down gracefully...`);
  server.close(() => {
    log('All connections drained, exiting.');
    process.exit(0);
  });
  // Force exit after 10 seconds if connections don't drain
  setTimeout(() => {
    console.error('Forced shutdown after 10s timeout.');
    process.exit(1);
  }, 10000).unref();
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

server.listen(PORT, () => log(`Vertex AI proxy on port ${PORT} (project: ${PROJECT_ID}, region: ${REGION})`));

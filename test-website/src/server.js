// Infrastructure validation endpoint. Deliberately boring: zero dependencies,
// no framework, no database. Its job is to be the component that is definitely
// not the problem when something else breaks.
//
// Also the reference implementation of the canonical log event
// (.claude/rules/10-logging-audit.md) for every service we write ourselves.

const http = require('http');

const START = Date.now();
const PORT = Number(process.env.PORT || 3000);
const ENV = process.env.APP_ENV || 'vps-prod';
const HOST = process.env.HOSTNAME || 'unknown';

function log(event, fields = {}) {
  process.stdout.write(JSON.stringify({
    ts: new Date().toISOString(),
    level: 'info',
    service: 'test-website',
    env: ENV,
    host: HOST,
    event,
    outcome: 'success',
    ...fields,
  }) + '\n');
}

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => (
  { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
));

function page(requestId) {
  const up = Math.floor((Date.now() - START) / 1000);
  // request_id is echoed back deliberately: it proves end-to-end propagation
  // nginx -> app, which is otherwise annoying to verify.
  return `<!doctype html><meta charset="utf-8"><title>Server Infrastructure Test</title>
<style>
 :root{color-scheme:light dark}
 body{font:16px/1.6 system-ui,sans-serif;margin:3rem auto;max-width:44rem;padding:0 1.2rem}
 h1{font-size:1.5rem;margin-bottom:.2rem}
 .sub{opacity:.7;margin-top:0}
 table{border-collapse:collapse;width:100%;margin:1.5rem 0}
 td{padding:.45rem .6rem;border-bottom:1px solid rgba(128,128,128,.25)}
 td:first-child{opacity:.75;width:14rem}
 .ok{color:#1a7f37;font-weight:600}
 code{background:rgba(128,128,128,.15);padding:.1rem .35rem;border-radius:3px;font-size:.9em}
</style>
<h1>Server Infrastructure Test</h1>
<p class="sub">Validating the delivery chain, not the application.</p>
<table>
 <tr><td>Nginx reverse proxy</td><td class="ok">OK</td></tr>
 <tr><td>HTTPS / TLS termination</td><td class="ok">OK</td></tr>
 <tr><td>Docker networking</td><td class="ok">OK</td></tr>
 <tr><td>Website container</td><td class="ok">OK</td></tr>
 <tr><td>Request-ID propagation</td><td>${requestId === '-' ? '<span style="color:#b35">not received</span>' : '<span class="ok">OK</span>'}</td></tr>
</table>
<table>
 <tr><td>Environment</td><td><code>${esc(ENV)}</code></td></tr>
 <tr><td>Container host</td><td><code>${esc(HOST)}</code></td></tr>
 <tr><td>Node</td><td><code>${esc(process.version)}</code></td></tr>
 <tr><td>Platform</td><td><code>${esc(process.platform)}/${esc(process.arch)}</code></td></tr>
 <tr><td>Uptime</td><td><code>${up}s</code></td></tr>
 <tr><td>X-Request-Id</td><td><code>${esc(requestId)}</code></td></tr>
</table>
`;
}

const server = http.createServer((req, res) => {
  const t0 = process.hrtime.bigint();
  const requestId = req.headers['x-request-id'] || '-';
  let status = 200;

  if (req.url === '/healthz') {
    const body = JSON.stringify({
      status: 'ok',
      service: 'test-website',
      uptime_s: Math.floor((Date.now() - START) / 1000),
    });
    res.writeHead(200, { 'Content-Type': 'application/json', 'X-Request-Id': requestId });
    res.end(body + '\n');
  } else if (req.url === '/' || req.url.startsWith('/?')) {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'X-Request-Id': requestId });
    res.end(page(requestId));
  } else {
    status = 404;
    res.writeHead(404, { 'Content-Type': 'text/plain', 'X-Request-Id': requestId });
    res.end('not found\n');
  }

  log('http.request', {
    request_id: requestId,
    source_ip: req.headers['x-real-ip'] || req.socket.remoteAddress,
    method: req.method,
    target: req.url,
    status,
    duration_ms: Number((process.hrtime.bigint() - t0) / 1000000n),
    outcome: status < 400 ? 'success' : 'failure',
    msg: 'served',
  });
});

server.listen(PORT, () => log('service.start', { msg: `listening on ${PORT}` }));

// Without this, SIGTERM is ignored and Docker waits the full 10s grace period
// on every single deploy.
for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => {
    log('service.stop', { msg: `received ${sig}, closing` });
    server.close(() => process.exit(0));
  });
}

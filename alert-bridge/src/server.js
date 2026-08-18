// Alertmanager webhook -> Brevo v3 API.
//
// WHY THIS EXISTS: docs/PLAN.md §14 chose Alertmanager's native SMTP precisely
// to keep bespoke code out of the alerting path. Brevo's SMTP relay needs an
// "SMTP key", which is a different credential from the v3 API key we have.
// With only the API key available the choice is this bridge or no alerting at
// all, and no alerting is worse.
//
// Consequences accepted, and mitigated:
//   - It is a new failure point. Kept to one file, zero dependencies.
//   - A failure here is NOT silent: it returns non-2xx, which increments
//     alertmanager_notifications_failed_total, which AlertDeliveryFailing
//     already watches (verified in Phase 6).
//   - It never logs the API key.
//
// Replace with native SMTP the moment a Brevo SMTP key is available.

const http = require('http');

const PORT = Number(process.env.PORT || 9095);
const API_KEY = process.env.BREVO_API_KEY || '';
const SENDER = process.env.ALERT_SENDER || '';
const RECIPIENT = process.env.ALERT_RECIPIENT || '';
const HOST = process.env.HOSTNAME || 'unknown';
// Linked from every alert. The one place a human goes next.
const GRAFANA_URL = process.env.GRAFANA_URL || 'https://yourdomain.com/monitoring/';

const log = (event, fields = {}) => process.stdout.write(JSON.stringify({
  ts: new Date().toISOString(), level: fields.level || 'info', service: 'alert-bridge',
  env: 'vps-prod', host: HOST, event, outcome: fields.outcome || 'success', ...fields,
}) + '\n');

// ---------------------------------------------------------------------------
// Rendering
//
// GMAIL/HTML-EMAIL CONSTRAINTS, and why this looks like 2005 HTML on purpose:
//
//   - ALL styling is inline. Gmail strips <style> blocks when a non-Gmail
//     account is viewed in the Gmail mobile app, so anything that matters
//     cannot live in a stylesheet.
//   - Layout is <table>, not flex or grid. Neither is reliable in Outlook or
//     the Gmail app, and there is no fallback when they fail — the layout just
//     collapses into a single unreadable column.
//   - 600px max width with width="100%" so it degrades to fluid on a phone
//     without needing media queries (which Gmail also strips in some clients).
//   - Explicit light color-scheme. Gmail's dark mode auto-inverts colours it
//     considers "light"; declaring the scheme and avoiding pure #fff/#000
//     stops severity colours flipping to something meaningless.
//   - No images. An alert must be readable with images blocked, which is the
//     default for most clients on a first email from a new sender.
//   - A plain-text alternative is ALWAYS sent alongside. It is what a text
//     client, a screen reader, and a phone notification preview actually use,
//     and it materially helps deliverability.
// ---------------------------------------------------------------------------

const esc = (s) => String(s ?? '')
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;').replace(/'/g, '&#39;');

// "for 3 minutes" is more actionable than an ISO timestamp nobody subtracts in
// their head at 3am.
function since(startsAt, endsAt) {
  const t0 = Date.parse(startsAt || '');
  if (!t0) return null;
  const t1 = (endsAt && Date.parse(endsAt) > 0 && !endsAt.startsWith('0001')) ? Date.parse(endsAt) : Date.now();
  const s = Math.max(0, Math.round((t1 - t0) / 1000));
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.round(s / 60)}m`;
  if (s < 86400) return `${(s / 3600).toFixed(1)}h`;
  return `${(s / 86400).toFixed(1)}d`;
}

const THEME = {
  critical: { accent: '#b42318', bg: '#fef3f2', border: '#fecdca', label: 'CRITICAL' },
  warning:  { accent: '#b54708', bg: '#fffaeb', border: '#fedf89', label: 'WARNING'  },
  info:     { accent: '#175cd3', bg: '#eff8ff', border: '#b2ddff', label: 'INFO'     },
  resolved: { accent: '#067647', bg: '#ecfdf3', border: '#abefc6', label: 'RESOLVED' },
};
const themeFor = (sev, allResolved) =>
  allResolved ? THEME.resolved : (THEME[sev] || THEME.info);

// The single most useful field, and the one the old template threw away: the
// value that actually tripped the rule. Prometheus puts it in the annotation
// after templating, so pull a number out of the summary when present.
function headline(a) {
  const ann = a.annotations || {};
  return ann.summary || ann.description || a.labels?.alertname || 'alert';
}

function render(payload) {
  const alerts = payload.alerts || [];
  const firing = alerts.filter((a) => a.status === 'firing');
  const resolved = alerts.filter((a) => a.status === 'resolved');
  const allResolved = firing.length === 0 && resolved.length > 0;
  const name = payload.commonLabels?.alertname || 'alert';
  const sev = (payload.commonLabels?.severity || 'info').toLowerCase();
  const t = themeFor(sev, allResolved);
  const sent = new Date().toISOString().replace('T', ' ').slice(0, 16) + ' UTC';

  // ---- subject: triage without opening the mail --------------------------
  // Old: "[CRITICAL] FIRING: DiskSpaceLow on onebox-prod" — says nothing about
  // what is actually wrong. New: lead with the summary, which carries the
  // measured value, so the inbox list alone is enough to decide urgency.
  const lead = alerts.length ? headline(alerts[0]) : name;
  const subject = allResolved
    ? `[RESOLVED] ${name} — cleared${since(alerts[0]?.startsAt, alerts[0]?.endsAt) ? ` after ${since(alerts[0].startsAt, alerts[0].endsAt)}` : ''} · ${HOST}`
    : `[${t.label}] ${lead}${alerts.length > 1 ? ` (+${alerts.length - 1} more)` : ''} · ${HOST}`;

  // ---- plain text --------------------------------------------------------
  const textLine = (a) => {
    const l = a.labels || {}, ann = a.annotations || {};
    const dur = since(a.startsAt, a.status === 'resolved' ? a.endsAt : null);
    return [
      `${a.status === 'resolved' ? '[RESOLVED]' : '[' + (l.severity || '?').toUpperCase() + ']'} ${l.alertname || '?'}`,
      ann.summary ? `  ${ann.summary}` : null,
      ann.description ? `  ${String(ann.description).replace(/\s+/g, ' ').trim()}` : null,
      l.instance ? `  instance: ${l.instance}` : null,
      dur ? `  ${a.status === 'resolved' ? 'lasted' : 'firing for'}: ${dur}` : null,
      ann.runbook_url ? `  runbook: ${ann.runbook_url}` : null,
    ].filter(Boolean).join('\n');
  };
  const body = [
    allResolved ? `RESOLVED: ${name} on ${HOST}` : `${t.label}: ${name} on ${HOST}`,
    '',
    firing.length ? `FIRING (${firing.length})\n\n${firing.map(textLine).join('\n\n')}` : '',
    resolved.length ? `${firing.length ? '\n' : ''}RESOLVED (${resolved.length})\n\n${resolved.map(textLine).join('\n\n')}` : '',
    '',
    `Grafana: ${GRAFANA_URL}`,
    `Sent ${sent} by alert-bridge on ${HOST} (receiver: ${payload.receiver || '?'}).`,
  ].filter(Boolean).join('\n');

  // ---- HTML --------------------------------------------------------------
  const card = (a) => {
    const l = a.labels || {}, ann = a.annotations || {};
    const isRes = a.status === 'resolved';
    const ct = isRes ? THEME.resolved : (THEME[(l.severity || '').toLowerCase()] || THEME.info);
    const dur = since(a.startsAt, isRes ? a.endsAt : null);

    const facts = [
      l.instance ? ['Instance', l.instance] : null,
      l.job ? ['Job', l.job] : null,
      l.mountpoint ? ['Mount', l.mountpoint] : null,
      dur ? [isRes ? 'Lasted' : 'Firing for', dur] : null,
      a.startsAt ? ['Started', String(a.startsAt).replace('T', ' ').slice(0, 19) + ' UTC'] : null,
    ].filter(Boolean);

    return `
<tr><td style="padding:0 24px 16px;">
  <table width="100%" cellpadding="0" cellspacing="0" border="0" role="presentation"
         style="background:${ct.bg};border:1px solid ${ct.border};border-radius:6px;">
    <tr><td style="padding:14px 16px;">
      <table width="100%" cellpadding="0" cellspacing="0" border="0" role="presentation"><tr>
        <td style="font:600 11px/1.2 -apple-system,'Segoe UI',Helvetica,Arial,sans-serif;
                   letter-spacing:.06em;color:${ct.accent};text-transform:uppercase;">
          ${esc(ct.label)}
        </td>
        <td align="right" style="font:400 11px/1.2 -apple-system,'Segoe UI',Helvetica,Arial,sans-serif;color:#667085;">
          ${esc(l.alertname || '')}
        </td>
      </tr></table>

      <div style="font:600 15px/1.45 -apple-system,'Segoe UI',Helvetica,Arial,sans-serif;
                  color:#101828;margin:8px 0 0;">${esc(ann.summary || l.alertname || 'Alert')}</div>

      ${ann.description ? `<div style="font:400 13px/1.6 -apple-system,'Segoe UI',Helvetica,Arial,sans-serif;
                  color:#475467;margin:6px 0 0;">${esc(String(ann.description).replace(/\s+/g, ' ').trim())}</div>` : ''}

      ${facts.length ? `<table cellpadding="0" cellspacing="0" border="0" role="presentation"
             style="margin:12px 0 0;border-top:1px solid ${ct.border};width:100%;">
        ${facts.map(([k, v]) => `<tr>
          <td style="padding:6px 12px 0 0;font:400 12px/1.5 -apple-system,'Segoe UI',Helvetica,Arial,sans-serif;color:#667085;white-space:nowrap;">${esc(k)}</td>
          <td style="padding:6px 0 0;font:500 12px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;color:#101828;">${esc(v)}</td>
        </tr>`).join('')}
      </table>` : ''}

      ${ann.runbook_url ? `<div style="margin:12px 0 0;">
        <a href="${esc(ann.runbook_url)}" style="font:600 12px/1.4 -apple-system,'Segoe UI',Helvetica,Arial,sans-serif;color:${ct.accent};text-decoration:underline;">Runbook &rarr;</a>
      </div>` : ''}
    </td></tr>
  </table>
</td></tr>`;
  };

  const counts = [
    firing.length ? `${firing.length} firing` : null,
    resolved.length ? `${resolved.length} resolved` : null,
  ].filter(Boolean).join(' · ');

  const html = `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light">
<meta name="supported-color-schemes" content="light">
<title>${esc(subject)}</title>
</head>
<body style="margin:0;padding:0;background:#f4f5f7;">
<!-- Preheader: what shows next to the subject in the inbox list. Without it,
     clients pull the first visible text, which would be the severity pill. -->
<div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;height:0;width:0;">
  ${esc(lead)} — ${esc(counts)} on ${esc(HOST)}
</div>

<table width="100%" cellpadding="0" cellspacing="0" border="0" role="presentation" style="background:#f4f5f7;">
<tr><td align="center" style="padding:24px 12px;">

  <table width="600" cellpadding="0" cellspacing="0" border="0" role="presentation"
         style="width:100%;max-width:600px;background:#ffffff;border:1px solid #e4e7ec;border-radius:8px;">

    <!-- Severity is carried by a colour bar, not by colour alone: the label
         text below repeats it for anyone who cannot distinguish the hue. -->
    <tr><td style="background:${t.accent};height:4px;line-height:4px;font-size:0;border-radius:8px 8px 0 0;">&nbsp;</td></tr>

    <tr><td style="padding:20px 24px 4px;">
      <div style="font:700 18px/1.35 -apple-system,'Segoe UI',Helvetica,Arial,sans-serif;color:#101828;">
        ${allResolved ? 'Resolved' : esc(t.label.charAt(0) + t.label.slice(1).toLowerCase())}: ${esc(name)}
      </div>
      <div style="font:400 13px/1.6 -apple-system,'Segoe UI',Helvetica,Arial,sans-serif;color:#667085;margin-top:4px;">
        ${esc(HOST)} &middot; ${esc(counts)} &middot; ${esc(sent)}
      </div>
    </td></tr>

    <tr><td style="padding:16px 24px 4px;"></td></tr>
    ${firing.map(card).join('')}
    ${resolved.map(card).join('')}

    <tr><td style="padding:4px 24px 20px;">
      <a href="${esc(GRAFANA_URL)}"
         style="display:inline-block;background:#101828;color:#ffffff;text-decoration:none;
                font:600 13px/1 -apple-system,'Segoe UI',Helvetica,Arial,sans-serif;
                padding:11px 18px;border-radius:6px;">Open Grafana</a>
    </td></tr>

    <tr><td style="padding:14px 24px 18px;border-top:1px solid #e4e7ec;
               font:400 11px/1.6 -apple-system,'Segoe UI',Helvetica,Arial,sans-serif;color:#98a2b3;">
      Sent by <strong style="color:#667085;">alert-bridge</strong> on ${esc(HOST)} &middot;
      receiver <code style="font-family:ui-monospace,Menlo,Consolas,monospace;">${esc(payload.receiver || '?')}</code><br>
      Critical alerts repeat every 4h and warnings every 12h while unresolved.
      You will get a RESOLVED email when it clears.
    </td></tr>

  </table>

</td></tr></table>
</body></html>`;

  return { subject, body, html };
}

function sendBrevo({ subject, body, html }) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify({
      sender: { email: SENDER, name: 'VPS Alerts' },
      to: [{ email: RECIPIENT }],
      subject,
      // BOTH parts, always. htmlContent alone renders as a wall of markup in a
      // text client, and textContent alone is what we had — unreadable on a
      // phone. Brevo assembles them into a multipart/alternative message.
      textContent: body,
      htmlContent: html,
    });
    const req = require('https').request({
      hostname: 'api.brevo.com', path: '/v3/smtp/email', method: 'POST',
      headers: {
        'api-key': API_KEY,
        'content-type': 'application/json',
        'accept': 'application/json',
        'content-length': Buffer.byteLength(data),
      },
      timeout: 15000,
    }, (res) => {
      let out = '';
      res.on('data', (c) => (out += c));
      res.on('end', () => (res.statusCode >= 200 && res.statusCode < 300)
        ? resolve({ status: res.statusCode, body: out })
        : reject(new Error(`brevo ${res.statusCode}: ${out.slice(0, 200)}`)));
    });
    req.on('timeout', () => { req.destroy(new Error('brevo request timed out')); });
    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

const server = http.createServer((req, res) => {
  if (req.url === '/healthz') {
    const ready = Boolean(API_KEY && SENDER && RECIPIENT);
    res.writeHead(ready ? 200 : 503, { 'Content-Type': 'application/json' });
    // Report WHICH config is missing, without ever echoing values.
    return res.end(JSON.stringify({
      status: ready ? 'ok' : 'misconfigured',
      service: 'alert-bridge',
      have: { api_key: !!API_KEY, sender: !!SENDER, recipient: !!RECIPIENT },
    }) + '\n');
  }

  if (req.method !== 'POST') { res.writeHead(405); return res.end(); }

  let raw = '';
  req.on('data', (c) => {
    raw += c;
    if (raw.length > 1e6) { req.destroy(); }   // refuse absurd payloads
  });
  req.on('end', async () => {
    const t0 = process.hrtime.bigint();
    let payload;
    try { payload = JSON.parse(raw); }
    catch {
      log('alert.receive', { level: 'error', outcome: 'failure', msg: 'invalid JSON payload' });
      res.writeHead(400); return res.end('bad json\n');
    }
    const mail = render(payload);
    try {
      const r = await sendBrevo(mail);
      log('alert.forward', {
        outcome: 'success', status: r.status,
        alerts: (payload.alerts || []).length,
        alertname: payload.commonLabels?.alertname,
        severity: payload.commonLabels?.severity,
        duration_ms: Number((process.hrtime.bigint() - t0) / 1000000n),
        msg: 'forwarded to brevo',
      });
      res.writeHead(200); res.end('ok\n');
    } catch (err) {
      // Non-2xx is deliberate: it makes Alertmanager retry AND increments
      // alertmanager_notifications_failed_total, so this failure alerts.
      log('alert.forward', {
        level: 'error', outcome: 'failure',
        error: String(err.message).replace(API_KEY, '***').slice(0, 300),
        alertname: payload.commonLabels?.alertname,
        duration_ms: Number((process.hrtime.bigint() - t0) / 1000000n),
        msg: 'brevo send failed',
      });
      res.writeHead(502); res.end('upstream failed\n');
    }
  });
});

// Only bind a port when run directly, so the renderer can be unit-tested
// without starting a server. Rendering an alert email is the part most likely
// to break silently — it must be exercisable offline.
if (require.main === module) {
server.listen(PORT, () => log('service.start', {
  msg: `listening on ${PORT}`,
  configured: Boolean(API_KEY && SENDER && RECIPIENT),
}));

for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => { log('service.stop', { msg: `received ${sig}` }); server.close(() => process.exit(0)); });
}
}

module.exports = { render };

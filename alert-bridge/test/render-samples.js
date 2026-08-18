// Render sample Alertmanager payloads to HTML/text without sending anything.
//
// Alert email is the one output nobody sees until something is already wrong,
// which is exactly when a rendering bug costs the most. This makes it
// inspectable offline:
//
//   docker run --rm -v "$PWD/alert-bridge:/app:ro" -v /tmp/out:/out \
//     --entrypoint node alert-bridge:1.0.0 /app/test/render-samples.js /out
//
// Writes <name>.html and <name>.txt per sample, and asserts the invariants that
// have actually bitten: unescaped label values, and a subject that says nothing.

const fs = require('fs');
const path = require('path');
const { render } = require('../src/server.js');

const outDir = process.argv[2] || '/tmp';

const now = new Date();
const ago = (m) => new Date(now.getTime() - m * 60000).toISOString();

const samples = {
  'critical-disk': {
    status: 'firing', receiver: 'email-critical',
    commonLabels: { alertname: 'DiskSpaceCritical', severity: 'critical' },
    alerts: [{
      status: 'firing',
      labels: { alertname: 'DiskSpaceCritical', severity: 'critical', instance: '172.19.0.1:9100', job: 'node', mountpoint: '/' },
      annotations: {
        summary: 'Root filesystem at 94% — 2.8 GiB free',
        description: 'A full root disk takes down sshd and Docker together. Free space now: check /var/lib/docker and journald first.',
        runbook_url: 'https://yourdomain.com/monitoring/',
      },
      startsAt: ago(7),
    }],
  },

  'warning-multi': {
    status: 'firing', receiver: 'email-default',
    commonLabels: { alertname: 'TLSCertExpiringSoon', severity: 'warning' },
    alerts: [
      {
        status: 'firing',
        labels: { alertname: 'TLSCertExpiringSoon', severity: 'warning', instance: 'nginx' },
        annotations: {
          summary: 'TLS certificate expires in 18 days',
          description: 'Renewal runs twice daily and starts 30 days out, so 18 days means roughly 24 attempts have already failed silently. Check: journalctl -u certbot-renew --since "7 days ago"',
        },
        startsAt: ago(65),
      },
      {
        status: 'firing',
        labels: { alertname: 'BackupOffsiteStale', severity: 'warning', instance: 'onebox-prod' },
        annotations: { summary: 'No successful off-site backup in 3 days' },
        startsAt: ago(2880),
      },
    ],
  },

  'resolved': {
    status: 'resolved', receiver: 'email-critical',
    commonLabels: { alertname: 'BlackboxOriginProbeFailed', severity: 'critical' },
    alerts: [{
      status: 'resolved',
      labels: { alertname: 'BlackboxOriginProbeFailed', severity: 'critical', instance: 'https://nginx/webrdp/', job: 'blackbox-origin' },
      annotations: { summary: 'Origin endpoint https://nginx/webrdp/ is not serving' },
      startsAt: ago(43), endsAt: new Date().toISOString(),
    }],
  },

  // Label values are attacker-influenced in the general case (a URL path ends
  // up in a label). If this renders as live markup, the email is an injection
  // vector into whatever reads it.
  'hostile-labels': {
    status: 'firing', receiver: 'email-default',
    commonLabels: { alertname: 'BlackboxOriginProbeFailed', severity: 'warning' },
    alerts: [{
      status: 'firing',
      labels: { alertname: 'Probe<script>alert(1)</script>', severity: 'warning', instance: 'https://x/"><img src=x onerror=alert(1)>' },
      annotations: { summary: 'Endpoint "quoted" & <b>bold</b> failed' },
      startsAt: ago(3),
    }],
  },
};

let fail = 0;
const check = (name, cond, msg) => {
  if (!cond) { console.log(`  FAIL  ${name}: ${msg}`); fail++; }
};

for (const [name, payload] of Object.entries(samples)) {
  const { subject, body, html } = render(payload);
  fs.writeFileSync(path.join(outDir, `${name}.html`), html);
  fs.writeFileSync(path.join(outDir, `${name}.txt`), `Subject: ${subject}\n\n${body}\n`);
  console.log(`\n[${name}]`);
  console.log(`  subject: ${subject}`);

  // The subject must carry the actual problem, not just the rule name.
  check(name, subject.length > 20, 'subject too short to triage from');
  check(name, !/^\[?\s*\]?$/.test(subject), 'empty subject');
  // Both parts present.
  check(name, html.includes('<!doctype html>'), 'no html doctype');
  check(name, body.length > 30, 'text part too short');
  // No stylesheet dependency — Gmail strips <style> in some clients.
  check(name, !/<style[\s>]/i.test(html), '<style> block present; must be inline');
  // No layout that Outlook/Gmail app will drop.
  check(name, !/display:\s*(flex|grid)/i.test(html), 'flex/grid used; unreliable in email');
  // Escaping. Assert on INJECTED TAGS, not on substrings.
  // A first version checked /onerror=alert/ and failed on correctly-escaped
  // output: escaping turns `"><img src=x onerror=alert(1)>` into
  // `&quot;&gt;&lt;img src=x onerror=alert(1)&gt;`, where the text
  // "onerror=alert(1)" survives but is inert. What matters is whether a real
  // tag was opened, so check for tags this template never emits.
  check(name, !/<script/i.test(html), 'a <script> tag reached the output');
  check(name, !/<img/i.test(html), 'an <img> tag reached the output (template emits none)');
  check(name, !/<iframe|<object|<embed/i.test(html), 'an embedding tag reached the output');
  // And confirm the escaper actually ran on hostile input.
  if (name === 'hostile-labels') {
    check(name, html.includes('&lt;b&gt;bold&lt;/b&gt;'), 'hostile markup was not escaped at all');
  }
}

console.log(fail === 0 ? '\nALL CHECKS PASSED' : `\n${fail} CHECK(S) FAILED`);
process.exit(fail === 0 ? 0 : 1);

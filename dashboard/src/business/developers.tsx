import { useState } from 'react';
import { Card, Copy, Empty, Field, Gate, Modal, PageHead, Status, Table, ago, fmtDate, useAct, useApp, useOp } from '../ui/kit.tsx';
import { can, type Biz } from './App.tsx';

// Developers > Webhooks: the business sets HTTPS endpoints and Knock sends
// signed JSON events to them (payments, deposits, payouts). Delivery runs in
// the backend worker (backend/src/business/webhooks-out.ts).
export function Developers({ biz }: { biz: Biz }) {
  const eps = useOp<any[]>('biz.webhooks', {}, { skip: !can(biz, 'settings.manage') });
  const [add, setAdd] = useState(false);
  const [secret, setSecret] = useState<string | null>(null);
  const [sel, setSel] = useState<string | null>(null);
  if (!can(biz, 'settings.manage')) return <><PageHead title="Developers" /><Empty title="No access">Only owners and admins can manage webhooks.</Empty></>;
  return <>
    <PageHead title="Developers" sub="Webhooks send your server a signed message when money moves, so your shop or app can update orders automatically."
      actions={<button className="btn primary" onClick={() => setAdd(true)}>Add endpoint</button>} />
    <div className="stack">
      <Gate q={eps}>{(rows) => rows.length === 0
        ? <Card><Empty title="No webhook endpoints yet" action={<button className="btn primary" onClick={() => setAdd(true)}>Add endpoint</button>}>Add the HTTPS URL on your server that should receive events like payment.succeeded.</Empty></Card>
        : <Card title="Endpoints" pad={false}><Table rows={rows} onRow={(r: any) => setSel(r.id)} cols={[
          { h: 'URL', c: (r: any) => <div><div className="mono small" style={{ wordBreak: 'break-all' }}>{r.url}</div>{r.description && <div className="small muted">{r.description}</div>}</div> },
          { h: 'Events', c: (r: any) => <span className="small">{r.events.join(', ')}</span> },
          { h: 'Status', c: (r: any) => <Status s={r.status} /> },
          { h: 'Deliveries', c: (r: any) => <span className="small">{r.delivered} delivered{Number(r.failing) > 0 && <span style={{ color: 'var(--red)' }}> · {r.failing} failing</span>}{Number(r.queued) > 0 && ` · ${r.queued} queued`}</span> },
          { h: 'Secret', c: (r: any) => <span className="mono small">whsec_…{r.secret_hint}</span> },
        ]} /></Card>}</Gate>
      {sel && <Endpoint id={sel} onClose={() => setSel(null)} onSecret={setSecret} />}
      <Deliveries endpoint={sel} />
      <Verify />
    </div>
    {add && <AddEndpoint onClose={() => setAdd(false)} onCreated={(s) => { setAdd(false); setSecret(s); }} />}
    <Modal open={!!secret} onClose={() => setSecret(null)} title="Your signing secret">
      <div className="stack">
        <div className="notice warn">Copy it now. For your security Knock shows it only once. If you lose it, rotate it.</div>
        <div className="row"><code className="mono addr">{secret}</code>{secret && <Copy text={secret} />}</div>
        <div className="small muted">Store it on your server only (for example as KNOCK_WEBHOOK_SECRET). Never put it in a website or mobile app.</div>
        <button className="btn primary" onClick={() => setSecret(null)}>I've saved it</button>
      </div>
    </Modal>
  </>;
}

function EventPicker({ value, onChange }: { value: string[]; onChange: (v: string[]) => void }) {
  const types = useOp<any[]>('biz.webhook_event_types');
  return <Gate q={types}>{(t) => <div className="stack tight">{t.map((e: any) => <label key={e.type} className="check">
    <input type="checkbox" checked={value.includes(e.type)} onChange={(x) => onChange(x.target.checked ? [...value, e.type] : value.filter((v) => v !== e.type))} />
    <span><span className="mono small">{e.type}</span> <span className="small muted">{e.description}</span></span></label>)}</div>}</Gate>;
}

function AddEndpoint({ onClose, onCreated }: { onClose: () => void; onCreated: (secret: string) => void }) {
  const { run, busy } = useAct();
  const [f, setF] = useState({ url: 'https://', description: '', events: ['payment.succeeded', 'payment.failed'] as string[] });
  const urlOk = /^https:\/\/[^/\s@]+\.[^/\s@]+/.test(f.url);
  return <Modal open onClose={onClose} title="Add webhook endpoint">
    <div className="stack">
      <Field label="Endpoint URL" hint="Must be HTTPS and reachable from the internet." error={f.url.length > 8 && !urlOk ? 'Use a full https:// address' : null}>
        <input className="input mono" value={f.url} onChange={(e) => setF({ ...f, url: e.target.value })} placeholder="https://yourshop.com/webhooks/knock" autoFocus /></Field>
      <Field label="Description (optional)"><input className="input" value={f.description} onChange={(e) => setF({ ...f, description: e.target.value })} placeholder="Online store orders" /></Field>
      <Field label="Events to send"><EventPicker value={f.events} onChange={(events) => setF({ ...f, events })} /></Field>
      <div className="row" style={{ justifyContent: 'flex-end' }}>
        <button className="btn ghost" onClick={onClose}>Cancel</button>
        <button className="btn primary" disabled={!urlOk || !f.events.length || busy} onClick={async () => {
          const r = await run<any>('biz.webhook_create', { endpoint: f }, 'Endpoint added');
          if (r) onCreated(r.secret);
        }}>Add endpoint</button>
      </div>
    </div>
  </Modal>;
}

function Endpoint({ id, onClose, onSecret }: { id: string; onClose: () => void; onSecret: (s: string) => void }) {
  const { run, busy } = useAct();
  const eps = useOp<any[]>('biz.webhooks');
  const e = eps.data?.find((x) => x.id === id);
  const [events, setEvents] = useState<string[] | null>(null);
  const [confirm, setConfirm] = useState<'rotate' | 'delete' | null>(null);
  if (!e) return null;
  const ev = events ?? e.events;
  return <Card title={<span className="mono small">{e.url}</span>} actions={<button className="btn ghost sm" onClick={onClose}>Close</button>}>
    <div className="stack">
      <div className="row wrap">
        <button className="btn sm" disabled={busy || e.status !== 'active'} onClick={() => run('biz.webhook_test', { endpoint_id: id }, 'Test event queued')}>Send test event</button>
        <button className="btn sm" disabled={busy} onClick={() => run('biz.webhook_update', { endpoint_id: id, endpoint: { status: e.status === 'active' ? 'disabled' : 'active' } }, e.status === 'active' ? 'Endpoint paused' : 'Endpoint resumed')}>{e.status === 'active' ? 'Pause' : 'Resume'}</button>
        <button className="btn sm" disabled={busy} onClick={() => setConfirm('rotate')}>Rotate secret</button>
        <button className="btn sm danger" disabled={busy} onClick={() => setConfirm('delete')}>Delete</button>
      </div>
      <div className="small muted">Created {fmtDate(e.created_at)}{e.rotated_at && ` · secret rotated ${ago(e.rotated_at)}`}{e.last_delivered_at && ` · last delivery ${ago(e.last_delivered_at)}`}</div>
      <Field label="Events"><EventPicker value={ev} onChange={setEvents} /></Field>
      {events && <div><button className="btn primary sm" disabled={busy || !events.length} onClick={async () => { if (await run('biz.webhook_update', { endpoint_id: id, endpoint: { events } }, 'Events saved')) setEvents(null); }}>Save events</button></div>}
    </div>
    <Modal open={!!confirm} onClose={() => setConfirm(null)} title={confirm === 'rotate' ? 'Rotate signing secret?' : 'Delete endpoint?'}>
      <div className="stack">
        <p className="muted" style={{ margin: 0 }}>{confirm === 'rotate' ? 'The old secret stops working immediately. Update your server with the new one straight away.' : 'Knock stops sending events to this URL. Queued deliveries are cancelled.'}</p>
        <div className="row" style={{ justifyContent: 'flex-end' }}>
          <button className="btn ghost" onClick={() => setConfirm(null)}>Cancel</button>
          <button className={'btn ' + (confirm === 'delete' ? 'danger' : 'primary')} disabled={busy} onClick={async () => {
            if (confirm === 'rotate') { const r = await run<any>('biz.webhook_rotate', { endpoint_id: id }, 'Secret rotated'); if (r) onSecret(r.secret); }
            else if (await run('biz.webhook_delete', { endpoint_id: id }, 'Endpoint deleted')) onClose();
            setConfirm(null);
          }}>{confirm === 'rotate' ? 'Rotate' : 'Delete'}</button>
        </div>
      </div>
    </Modal>
  </Card>;
}

function Deliveries({ endpoint }: { endpoint: string | null }) {
  const { sb } = useApp();
  const { run, sim, busy } = useAct();
  const q = useOp<any[]>('biz.webhook_deliveries', { endpoint_id: endpoint });
  const [open, setOpen] = useState<any>(null);
  const [req, setReq] = useState<any>(null);
  const queued = (q.data ?? []).filter((d) => ['pending', 'sending'].includes(d.status)).length;
  return <Card title={endpoint ? 'Events for this endpoint' : 'Recent events'} pad={false}
    actions={queued > 0 && <span className="row small"><span className="muted">Sandbox receiver answers:</span>
      <button className="btn sm" disabled={busy} onClick={() => sim(() => sb.sim.deliver(200), 'Delivered (receiver answered 200)')}>200 OK</button>
      <button className="btn sm" disabled={busy} onClick={() => sim(() => sb.sim.deliver(500), 'Receiver answered 500; retry scheduled')}>500 error</button></span>}>
    {queued > 0 && <div className="notice" style={{ margin: 12 }}>{queued} queued. The sandbox preview can't call your URL, so nothing has really been sent. In production the delivery worker sends within seconds. Use the buttons to choose how your server answers and see the retry schedule work.</div>}
    <Gate q={q}>{(rows) => <Table rows={rows} onRow={(r: any) => { setOpen(r); setReq(null); }} empty={<div className="card-b muted">No events yet. Events appear when payments, deposits or payouts change, or when you send a test event.</div>} cols={[
      { h: 'Event', c: (r: any) => <div><span className="mono small">{r.type}</span><div className="small muted mono">{r.event_ref}</div></div> },
      { h: 'Created', c: (r: any) => <span className="small">{ago(r.created_at)}</span> },
      { h: 'Delivery', c: (r: any) => <div><Status s={r.status === 'pending' || r.status === 'sending' ? 'queued' : r.status} /><div className="small muted">{r.attempts} attempt{r.attempts === 1 ? '' : 's'}{r.last_status_code ? ` · HTTP ${r.last_status_code}` : ''}{r.status === 'retrying' ? ` · next ${fmtDate(r.next_attempt_at)}` : ''}</div></div> },
      ...(endpoint ? [] : [{ h: 'Endpoint', c: (r: any) => <span className="mono small" style={{ wordBreak: 'break-all' }}>{r.url}</span> }]),
    ]} />}</Gate>
    <Modal open={!!open} onClose={() => setOpen(null)} title={open?.type}>
      {open && <div className="stack">
        <div className="kv small"><div>Event id</div><div className="mono">{open.event_ref}</div><div>Status</div><div><Status s={open.status} /></div>
          <div>Attempts</div><div>{open.attempts}</div>{open.last_error && <><div>Last error</div><div>{open.last_error}</div></>}
          {open.delivered_at && <><div>Delivered</div><div>{fmtDate(open.delivered_at)} ({open.last_duration_ms} ms)</div></>}</div>
        <div className="row wrap">
          <button className="btn sm" onClick={async () => setReq(await sb.sim.signedRequest(open.id))}>Show signed request</button>
          {['failed', 'cancelled', 'retrying'].includes(open.status) && <button className="btn sm" disabled={busy} onClick={async () => { if (await run('biz.webhook_retry', { delivery_id: open.id }, 'Redelivery queued')) setOpen(null); }}>Resend now</button>}
        </div>
        {req ? <pre className="code">{`POST ${req.url}\n${Object.entries(req.headers).map(([k, v]) => `${k}: ${v}`).join('\n')}\n\n${JSON.stringify(JSON.parse(req.body), null, 2)}`}</pre>
          : <pre className="code">{JSON.stringify(open.payload, null, 2)}</pre>}
      </div>}
    </Modal>
  </Card>;
}

const SNIPPET = `// Node.js: verify a Knock webhook before trusting it
import crypto from 'node:crypto';

export function verifyKnock(rawBody, header, secret) {
  const parts = Object.fromEntries(header.split(',').map((p) => p.split('=')));
  if (Math.abs(Date.now() / 1000 - Number(parts.t)) > 300) return false; // replay window
  const expected = crypto.createHmac('sha256', secret).update(parts.t + '.' + rawBody).digest('hex');
  return crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(parts.v1 ?? ''));
}
// Answer 2xx quickly, process in the background, and ignore an event id
// (knock-event-id) you've already handled: retries can repeat an event.`;

function Verify() {
  return <Card title="Verify signatures">
    <div className="stack">
      <div className="small">Every request has a <span className="mono">knock-signature</span> header: <span className="mono">t=&lt;unix time&gt;,v1=&lt;HMAC-SHA256 of "t.body" with your secret&gt;</span>. Use the raw request body, check the time is within 5 minutes, and compare in constant time. Failed deliveries are retried after 1 minute, 5 minutes, 30 minutes, 2 hours, 6 hours, 12 hours and 24 hours.</div>
      <pre className="code">{SNIPPET}</pre>
    </div>
  </Card>;
}

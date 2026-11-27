import { useEffect, useState } from 'react';
import { Copy, Field, Gate, Money, QR, Status, fmtDate, fmtMoney, toMinor, useAct, useApp, useHash, useOp } from '../ui/kit.tsx';

// Hosted checkout: the page a customer lands on from a payment link.
// Follows Breet's e-commerce flow: one deposit address per payment (label =
// the payment's Knock reference), exact amount + network + QR, live status
// from Breet's trade.pending / trade.completed / trade.flagged / trade.deleted
// webhooks, then a receipt. Production: "Continue" calls
// POST /v1/checkout/:slug and the page polls pub.checkout. In this sandbox
// the same SQL runs in the browser and the panel at the bottom plays the
// customer's wallet and Breet.
const PUBLIC = { userId: '00000000-0000-0000-0000-000000000000', context: null };

export function PayPage({ slug, paymentId }: { slug: string; paymentId?: string }) {
  const q = useOp<any>('pub.link', { slug }, { context: null });
  return <div className="paypage">
    <div className="sandbox" style={{ borderRadius: 10, marginBottom: 16 }}><b>SANDBOX</b> Test checkout. No real money moves. <a href="#/links">Back to dashboard</a></div>
    <Gate q={q} empty={<div className="card card-b"><h2>This payment link doesn't exist</h2><p className="muted">Check the link with the business that sent it.</p></div>}>
      {(l) => paymentId ? <Pay l={l} slug={slug} id={paymentId} /> : <Details l={l} slug={slug} />}
    </Gate>
    <div className="small muted" style={{ textAlign: 'center', marginTop: 14 }}>Secured by Knock · Crypto processed by Breet</div>
  </div>;
}

function Merchant({ l }: { l: any }) {
  return <div className="row"><div className="mark" aria-hidden>{(l.merchant ?? '?').slice(0, 1)}</div>
    <div><b>{l.merchant}</b>{l.verified && <span className="small" style={{ color: 'var(--green-strong)' }}> · ✓ Verified business</span>}<div className="small muted">@{l.handle}</div></div></div>;
}

function Steps({ at }: { at: number }) {
  return <ol className="steps" aria-label="Checkout steps">{['Details', 'Pay', 'Receipt'].map((s, i) => <li key={s} className={i < at ? 'done' : i === at ? 'on' : ''}>{s}</li>)}</ol>;
}

// ---------------------------------------------------------------- 1. details
function Details({ l, slug }: { l: any; slug: string }) {
  const { sb } = useApp();
  const [, go] = useHash();
  const { sim, busy } = useAct();
  const [amt, setAmt] = useState('');
  const [payer, setPayer] = useState({ name: '', email: '', reference: '' });
  const [quote, setQuote] = useState<any>(null);
  const [qErr, setQErr] = useState<string | null>(null);
  const crypto = l.currency !== 'NGN';
  const amount = l.amount_mode === 'fixed' ? l.fixed_amount : toMinor(amt, l.currency);

  useEffect(() => {
    if (!amount) { setQuote(null); setQErr(null); return; }
    let live = true;
    sb.run('pub.quote', PUBLIC, { slug, amount }).then((r) => { if (live) { setQuote(r); setQErr(null); } })
      .catch((e) => { if (live) { setQuote(null); setQErr(e.message); } });
    return () => { live = false; };
  }, [l.reference, amount]);

  const closed = l.status !== 'active' || (l.expires_at && new Date(l.expires_at) <= new Date());
  const emailOk = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(payer.email.trim());
  const ok = crypto && quote && payer.name.trim().length >= 2 && emailOk && (!l.require_customer_reference || payer.reference.trim());
  const start = async () => {
    const r = await sim(() => sb.sim.checkout(slug, l.amount_mode === 'fixed' ? null : amount, payer));
    if (r) go(`pay/${slug}/${r.payment_id}`);
  };

  return <div className="card card-b stack">
    <Merchant l={l} />
    <Steps at={0} />
    <div><h2 style={{ margin: '6px 0' }}>{l.title}</h2>{l.description && <p className="muted" style={{ margin: 0 }}>{l.description}</p>}
      {l.invoice_number && <div className="small muted">Invoice {l.invoice_number}</div>}</div>
    {l.target_amount && <div className="small muted">{fmtMoney(l.collected, l.currency)} of {fmtMoney(l.target_amount, l.currency)} collected</div>}
    {closed ? <div className="notice bad">This link is not accepting payments{l.status !== 'active' ? <> (<Status s={l.status} />)</> : ' because it has expired'}.</div> : <>
      {l.amount_mode === 'fixed' ? <div style={{ fontSize: 30, fontWeight: 700 }}><Money minor={l.fixed_amount} currency={l.currency} /></div>
        : <Field label={`Amount (${l.currency})`}><input className="input num" inputMode="decimal" value={amt} onChange={(e) => setAmt(e.target.value)} placeholder="0.00" autoFocus /></Field>}
      <div className="grid g2">
        <Field label="Your name"><input className="input" value={payer.name} onChange={(e) => setPayer({ ...payer, name: e.target.value })} autoComplete="name" /></Field>
        <Field label="Email for your receipt" error={payer.email && !emailOk ? 'Enter a valid email' : null}><input className="input" type="email" value={payer.email} onChange={(e) => setPayer({ ...payer, email: e.target.value })} autoComplete="email" /></Field>
      </div>
      {l.require_customer_reference && <Field label="Your reference" hint="The business asked for this, e.g. your order or student number."><input className="input" value={payer.reference} onChange={(e) => setPayer({ ...payer, reference: e.target.value })} /></Field>}
      <div>
        <div className="small muted" style={{ marginBottom: 6 }}>Pay with</div>
        <div className="methods">
          <label className={'method' + (crypto ? ' on' : ' off')}><input type="radio" checked={crypto} disabled={!crypto} readOnly /> <span><b>Crypto</b><br /><span className="small muted">{crypto ? `${l.currency} on ${l.network}` : 'Not offered on this link'}</span></span></label>
          <label className="method off" title="Needs the 9PSB collections integration"><input type="radio" disabled /> <span><b>Bank transfer</b><br /><span className="small muted">Coming soon</span></span></label>
        </div>
        {!crypto && <div className="notice warn" style={{ marginTop: 8 }}>Naira checkout by bank transfer isn't available yet. It switches on when the 9PSB collections integration is live.</div>}
      </div>
      {qErr && <div className="notice bad">{qErr}</div>}
      {quote && <div className="kv small">
        <div>Amount</div><div className="num">{fmtMoney(quote.amount, l.currency)}</div>
        {BigInt(quote.payer_fee) > 0n && <><div>Knock fee</div><div className="num">{fmtMoney(quote.payer_fee, l.currency)}</div></>}
        <div><b>You pay</b></div><div className="num"><b>{fmtMoney(quote.total_to_pay, l.currency)}</b></div>
      </div>}
      <button className="btn primary" style={{ justifyContent: 'center', padding: 12 }} disabled={!ok || busy} onClick={start}>
        {busy ? 'Creating your payment address…' : `Continue to payment${quote ? ' · ' + fmtMoney(quote.total_to_pay, l.currency) : ''}`}</button>
      <div className="small muted">You'll get a one-time address for this payment. Knock never asks for your PIN or seed phrase.{l.expires_at && ` Link expires ${fmtDate(l.expires_at)}.`}</div>
    </>}
    <div className="small muted mono" style={{ textAlign: 'center' }}>{l.reference}</div>
  </div>;
}

// ---------------------------------------------------------------- 2/3. pay + receipt
function useCountdown(to: string | null) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => { const t = setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(t); }, []);
  if (!to) return null;
  const s = Math.max(0, Math.floor((new Date(to).getTime() - now) / 1000));
  return { s, text: `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}` };
}

function Pay({ l, slug, id }: { l: any; slug: string; id: string }) {
  const { bump } = useApp();
  const q = useOp<any>('pub.checkout', { payment_id: id }, { context: null });
  // Poll for Breet's webhooks (production: every few seconds; Breet confirms
  // Solana in seconds and Bitcoin in 5 to 60 minutes).
  useEffect(() => { const t = setInterval(bump, 4000); return () => clearInterval(t); }, []);
  return <Gate q={q} empty={<div className="card card-b"><h2>Checkout not found</h2><p className="muted">This checkout session isn't available. <a href={'#/pay/' + slug}>Start again</a>.</p></div>}>
    {(c) => <div className="stack">
      {c.status === 'succeeded' ? <Receipt c={c} /> : c.status === 'failed' ? <Ended c={c} slug={slug} kind="failed" />
        : c.status === 'expired' ? <Ended c={c} slug={slug} kind="expired" /> : <Waiting c={c} l={l} />}
      {!['succeeded', 'failed'].includes(c.status) && <SandboxWallet c={c} />}
    </div>}
  </Gate>;
}

function Waiting({ c, l }: { c: any; l: any }) {
  const left = useCountdown(c.expires_at);
  const total = fmtMoney(c.total, c.currency);
  const plain = (Number(c.total) / 10 ** (c.decimals ?? 6)).toFixed(c.decimals ?? 6).replace(/\.?0+$/, '');
  const detected = c.status === 'confirming';
  return <div className="card card-b stack">
    <Merchant l={l} />
    <Steps at={1} />
    {!c.address ? <div className="empty"><div className="spinner" />Creating your payment address…</div> : <>
      <div className="center stack tight">
        <div className="small muted">Send exactly</div>
        <div className="row" style={{ justifyContent: 'center' }}><span style={{ fontSize: 28, fontWeight: 700 }} className="num">{total}</span><Copy text={plain} label="Copy amount" /></div>
        <div className="small"><b>{c.currency}</b> on the <b>{c.network}</b> network only</div>
      </div>
      <div className="center"><div style={{ display: 'inline-block', padding: 10, background: '#fff', borderRadius: 12, border: '1px solid var(--line)' }}><QR text={c.address} /></div></div>
      <Field label={`Your ${c.currency} (${c.network}) payment address`}>
        <div className="row"><code className="mono addr">{c.address}</code><Copy text={c.address} /></div>
      </Field>
      {c.memo && <Field label="Memo / tag (required)"><div className="row"><code className="mono addr">{c.memo}</code><Copy text={c.memo} /></div></Field>}
      <div className={'notice ' + (c.held ? 'warn' : detected ? 'good' : '')} role="status" aria-live="polite">
        {c.held ? <><b>Payment on hold.</b> The provider is reviewing this transfer. Nothing is credited until it clears. You don't need to send again.</>
          : detected ? <><b>Payment detected.</b> Waiting for network confirmations ({c.confirmations}{c.required_confirmations ? ` of ${c.required_confirmations}` : ''}). You can keep this page open.
            {c.received && c.received !== c.total && <div>We've seen {fmtMoney(c.received, c.currency)} so far.</div>}</>
          : <><span className="spinner sm" /> <b>Waiting for your transfer.</b> This page updates by itself.</>}
      </div>
      {!detected && !c.held && left && <div className="small muted center">{left.s > 0 ? <>Rate and address reserved for <b className="num">{left.text}</b></> : 'Time is up. Checking…'}</div>}
      <ul className="small muted" style={{ margin: 0, paddingLeft: 18 }}>
        <li>Send only {c.currency} on {c.network}. Other coins or networks can be lost.</li>
        <li>Send the full amount in one transfer. Network fees are paid by you, on top.</li>
        <li>This address is for this payment only. Don't save it for later.</li>
      </ul>
      <div className="small muted mono center">Payment {c.reference}</div>
    </>}
  </div>;
}

function Receipt({ c }: { c: any }) {
  return <div className="card card-b stack receipt">
    <Steps at={3} />
    <div className="center"><div className="tick" aria-hidden>✓</div>
      <h2 style={{ margin: '8px 0 2px' }}>Payment received</h2>
      <p className="muted" style={{ margin: 0 }}>{c.merchant} has been notified.{c.under_review && ' The amount you sent differs from the amount due, so the business will review it and contact you if needed.'}</p></div>
    <div className="kv small">
      <div>Paid to</div><div>{c.merchant} (@{c.handle})</div>
      <div>For</div><div>{c.link.title}</div>
      <div>Amount received</div><div className="num"><b>{fmtMoney(c.received ?? c.total, c.currency)}</b></div>
      {c.received && c.received !== c.total && <><div>Amount due</div><div className="num">{fmtMoney(c.total, c.currency)}</div></>}
      <div>Network</div><div>{c.currency} on {c.network}</div>
      <div>Date</div><div>{fmtDate(c.paid_at)}</div>
      <div>Payer</div><div>{c.payer_name}</div>
      {c.customer_reference && <><div>Your reference</div><div>{c.customer_reference}</div></>}
      <div>Knock reference</div><div className="mono">{c.reference}</div>
      {c.tx_hash && <><div>Transaction</div><div className="mono" style={{ wordBreak: 'break-all' }}>{c.tx_hash}</div></>}
    </div>
    <div className="row" style={{ justifyContent: 'center' }}><button className="btn" onClick={() => window.print()}>Print receipt</button></div>
    <div className="small muted center">A copy goes to your email once Knock's email service is switched on.</div>
  </div>;
}

function Ended({ c, slug, kind }: { c: any; slug: string; kind: 'failed' | 'expired' }) {
  return <div className="card card-b stack center">
    <div className="tick bad" aria-hidden>{kind === 'failed' ? '✕' : '⏱'}</div>
    <h2 style={{ margin: 0 }}>{kind === 'failed' ? 'Payment not completed' : 'This checkout expired'}</h2>
    <p className="muted" style={{ margin: 0 }}>{kind === 'failed' ? 'The transfer failed or was rejected by the provider. Nothing was credited.'
      : 'No transfer arrived in time. If you already sent it, it will still be matched to this payment. Keep this reference and contact the business.'}</p>
    <div className="mono small">{c.reference}</div>
    <a className="btn primary" href={'#/pay/' + slug} style={{ justifyContent: 'center' }}>Start a new payment</a>
  </div>;
}

function SandboxWallet({ c }: { c: any }) {
  const { sb } = useApp();
  const { sim, busy } = useAct();
  const go = (s: 'detected' | 'completed' | 'underpaid' | 'held' | 'failed' | 'expire', msg: string) => sim(() => sb.sim.checkoutEvent(c.payment_id, s), msg);
  if (!c.address) return null;
  const detected = c.status === 'confirming';
  return <div className="card card-b stack tight sandbox-panel">
    <b className="small">Sandbox: act as the customer's wallet and Breet</b>
    <div className="small muted">Each button sends the Breet webhook Knock would receive, through the same database function production uses.</div>
    <div className="row wrap">
      {!detected && !c.held && <button className="btn sm" disabled={busy} onClick={() => go('detected', 'trade.pending: transfer detected')}>Send full amount</button>}
      <button className="btn sm primary" disabled={busy} onClick={() => go('completed', 'trade.completed: confirmed')}>{detected ? 'Network confirms' : 'Send and confirm'}</button>
      {!detected && <button className="btn sm" disabled={busy} onClick={() => go('underpaid', 'trade.completed with 80% of the amount')}>Underpay (80%)</button>}
      {!c.held && <button className="btn sm" disabled={busy} onClick={() => go('held', 'trade.flagged: under review')}>Breet flags for review</button>}
      <button className="btn sm" disabled={busy} onClick={() => go('failed', 'trade.deleted: failed')}>Fails on chain</button>
      {!detected && !c.held && <button className="btn sm ghost" disabled={busy} onClick={() => go('expire', 'Quote window ended')}>Let it expire</button>}
    </div>
  </div>;
}

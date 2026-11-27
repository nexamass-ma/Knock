import { useEffect, useState } from 'react';
import { Field, Gate, Money, Status, fmtDate, fmtMoney, toMinor, useAct, useApp, useOp } from '../ui/kit.tsx';

// The public page a customer opens from a payment link. It reads only the
// public link fields, asks the database for a quote, and (in the sandbox)
// plays the provider's checkout. Production hands the customer to the
// provider's hosted checkout and waits for the verified webhook.
export function PayPage({ slug }: { slug: string }) {
  const q = useOp<any>('pub.link', { slug }, { context: null });
  const { sb } = useApp();
  const { sim, busy } = useAct();
  const [amt, setAmt] = useState('');
  const [payer, setPayer] = useState({ name: '', email: '', reference: '' });
  const [quote, setQuote] = useState<any>(null);
  const [qErr, setQErr] = useState<string | null>(null);
  const [done, setDone] = useState<any>(null);
  const l = q.data;
  const amount = l ? (l.amount_mode === 'fixed' ? l.fixed_amount : toMinor(amt, l.currency)) : null;

  useEffect(() => {
    if (!l || !amount) { setQuote(null); setQErr(null); return; }
    let live = true;
    sb.run('pub.quote', { userId: '00000000-0000-0000-0000-000000000000', context: null }, { slug, amount })
      .then((r) => { if (live) { setQuote(r); setQErr(null); } })
      .catch((e) => { if (live) { setQuote(null); setQErr(e.message); } });
    return () => { live = false; };
  }, [l?.reference, amount]);

  const ok = quote && payer.name.trim().length >= 2 && /.+@.+\..+/.test(payer.email) && (!l?.require_customer_reference || payer.reference.trim());
  return <div className="paypage">
    <div className="sandbox" style={{ borderRadius: 10, marginBottom: 16 }}><b>SANDBOX</b> Test payment page. No real money moves. <a href="#/links">Back to dashboard</a></div>
    <Gate q={q} empty={<div className="card card-b"><h2>This payment link doesn't exist</h2><p className="muted">Check the link with the business that sent it.</p></div>}>{(l) => {
      if (done) return <div className="card card-b stack" style={{ textAlign: 'center' }}>
        <div style={{ fontSize: 44 }}>{done.status === 'succeeded' ? '✓' : '✕'}</div>
        <h2>{done.status === 'succeeded' ? 'Payment confirmed' : 'Payment failed'}</h2>
        <p className="muted">{done.status === 'succeeded' ? `${l.merchant} has received your payment.` : 'No money was taken. You can try again.'}</p>
        <div className="mono small">Reference {done.reference}</div>
        {done.status !== 'succeeded' && <button className="btn" onClick={() => setDone(null)}>Try again</button>}
      </div>;
      const closed = l.status !== 'active' || (l.expires_at && new Date(l.expires_at) <= new Date());
      return <div className="card card-b stack">
        <div className="row"><div className="mark" aria-hidden>{l.merchant.slice(0, 1)}</div><div><b>{l.merchant}</b>{l.verified && <span className="small" style={{ color: 'var(--green-strong)' }}> · ✓ Verified business</span>}<div className="small muted">@{l.handle}</div></div></div>
        <div><h2 style={{ margin: '6px 0' }}>{l.title}</h2>{l.description && <p className="muted" style={{ margin: 0 }}>{l.description}</p>}{l.invoice_number && <div className="small muted">Invoice {l.invoice_number}</div>}</div>
        {l.target_amount && <div className="small muted">{fmtMoney(l.collected, l.currency)} of {fmtMoney(l.target_amount, l.currency)} collected</div>}
        {closed ? <div className="notice bad">This link is not accepting payments{l.status !== 'active' ? <> (<Status s={l.status} />)</> : ' because it has expired'}.</div> : <>
          {l.amount_mode === 'fixed' ? <div className="value" style={{ fontSize: 30, fontWeight: 700 }}><Money minor={l.fixed_amount} currency={l.currency} /></div>
            : <Field label={`Amount (${l.currency})`}><input className="input num" inputMode="decimal" value={amt} onChange={(e) => setAmt(e.target.value)} placeholder="0.00" autoFocus /></Field>}
          <div className="grid g2">
            <Field label="Your name"><input className="input" value={payer.name} onChange={(e) => setPayer({ ...payer, name: e.target.value })} autoComplete="name" /></Field>
            <Field label="Email for your receipt"><input className="input" type="email" value={payer.email} onChange={(e) => setPayer({ ...payer, email: e.target.value })} autoComplete="email" /></Field>
          </div>
          {l.require_customer_reference && <Field label="Your reference" hint="The business asked for this, e.g. your order or student number."><input className="input" value={payer.reference} onChange={(e) => setPayer({ ...payer, reference: e.target.value })} /></Field>}
          {qErr && <div className="notice bad">{qErr}</div>}
          {quote && <div className="kv small">
            <div>Amount</div><div className="num">{fmtMoney(quote.amount, l.currency)}</div>
            {BigInt(quote.payer_fee) > 0n && <><div>Knock fee</div><div className="num">{fmtMoney(quote.payer_fee, l.currency)}</div></>}
            <div><b>You pay</b></div><div className="num"><b>{fmtMoney(quote.total_to_pay, l.currency)}</b></div>
            {l.currency !== 'NGN' && <><div>Network</div><div>{l.currency} on {l.network}</div></>}
          </div>}
          <div className="stack tight">
            <button className="btn primary" style={{ justifyContent: 'center', padding: 12 }} disabled={!ok || busy} onClick={async () => { const r = await sim(() => sb.sim.pay(slug, l.amount_mode === 'fixed' ? null : amount, payer)); if (r) setDone(r); }}>
              Pay {quote ? fmtMoney(quote.total_to_pay, l.currency) : ''} (sandbox)</button>
            <button className="btn ghost sm" disabled={!ok || busy} onClick={async () => { const r = await sim(() => sb.sim.pay(slug, l.amount_mode === 'fixed' ? null : amount, payer, 'failed')); if (r) setDone(r); }}>Sandbox: simulate a failed payment</button>
          </div>
          <div className="small muted">Payments are confirmed with the payment provider before the business is credited. Knock never asks for your PIN on this page.{l.expires_at && ` Link expires ${fmtDate(l.expires_at)}.`}</div>
        </>}
        <div className="small muted mono" style={{ textAlign: 'center' }}>{l.reference} · Powered by Knock</div>
      </div>;
    }}</Gate>
  </div>;
}

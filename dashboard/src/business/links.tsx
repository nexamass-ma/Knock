import { useMemo, useState } from 'react';
import { Card, Copy, Drawer, Empty, Field, Gate, Modal, Money, PageHead, QR, Seg, Status, Table, decimals, downloadCsv, fmtDate, fmtMoney, toMinor, useAct, useApp, useHash, useOp } from '../ui/kit.tsx';
import { can, type Biz } from './App.tsx';

export const payUrl = (slug: string) => `${location.origin}${location.pathname.replace(/admin\.html$/, 'index.html')}#/pay/${slug}`;

function useFlags() {
  const f = useOp<any[]>('biz.flags');
  return (k: string) => f.data?.find((x) => x.key === k);
}

export function Links({ biz, id }: { biz: Biz; id?: string }) {
  const [, go] = useHash();
  const [filter, setFilter] = useState({ status: '', search: '' });
  const q = useOp<any[]>('biz.links', { type: null, status: filter.status || null, search: filter.search || null });
  const [creating, setCreating] = useState(false);
  const rows = (q.data ?? []).filter((l) => l.link_type !== 'split');
  return <>
    <PageHead title="Payment Links" sub="Share a link, get paid. Every payment is confirmed with the provider before it counts."
      actions={<>
        <button className="btn" disabled={!rows.length} onClick={() => downloadCsv(`knock-links-${biz.handle}.csv`, rows)}>Export</button>
        {can(biz, 'links.create') && <button className="btn primary" onClick={() => setCreating(true)}>New payment link</button>}</>} />
    <Card pad={false}>
      <div className="card-b row wrap" style={{ borderBottom: '1px solid var(--line)' }}>
        <input className="input" style={{ maxWidth: 260 }} placeholder="Search title or reference" value={filter.search} onChange={(e) => setFilter({ ...filter, search: e.target.value })} aria-label="Search links" />
        <Seg value={filter.status} onChange={(status) => setFilter({ ...filter, status })} options={[['', 'All'], ['active', 'Active'], ['paused', 'Paused'], ['completed', 'Completed'], ['expired', 'Expired'], ['closed', 'Closed']]} />
      </div>
      <Gate q={q}>{() => <Table rows={rows} onRow={(l) => go('links/' + l.id)} empty={<Empty title="No payment links yet" action={can(biz, 'links.create') ? <button className="btn primary" onClick={() => setCreating(true)}>Create a payment link</button> : undefined}>
        A payment link is a page your customers open to pay you. Create one for an order, an invoice or a product.</Empty>} cols={[
        { h: 'Link', c: (l) => <div><div><b>{l.title}</b></div><div className="small muted mono">{l.reference}</div></div> },
        { h: 'Amount', c: (l) => l.amount_mode === 'fixed' ? <Money minor={l.fixed_amount} currency={l.currency} /> : <span className="muted">Customer enters amount</span> },
        { h: 'Status', c: (l) => <Status s={l.status} /> },
        { h: 'Payments', right: true, c: (l) => l.payments },
        { h: 'Collected', right: true, c: (l) => <Money minor={l.collected} currency={l.currency} /> },
        { h: 'Created', c: (l) => <span className="small">{fmtDate(l.created_at, false)}</span> },
      ]} />}</Gate>
    </Card>
    <CreateLink open={creating} onClose={() => setCreating(false)} split={false} onCreated={(nid) => go('links/' + nid)} />
    <LinkDrawer biz={biz} id={id ?? null} onClose={() => go('links')} />
  </>;
}

export function SmartSplit({ biz, id }: { biz: Biz; id?: string }) {
  const [, go] = useHash();
  const q = useOp<any[]>('biz.links', { type: 'split', status: null, search: null });
  const [creating, setCreating] = useState(false);
  if (id) return <SplitDetail biz={biz} id={id} />;
  return <>
    <PageHead title="Smart Split" sub="One link, many recipients. Each confirmed payment is shared automatically by your rules."
      actions={can(biz, 'splits.manage') && <button className="btn primary" onClick={() => setCreating(true)}>New split link</button>} />
    <Gate q={q} empty={<Card><Empty title="No split links yet" action={can(biz, 'splits.manage') ? <button className="btn primary" onClick={() => setCreating(true)}>Create a split link</button> : undefined}>
      Collect for a team, an event or a group purchase, and pay everyone their share. Shares are only recorded after a payment is confirmed, and never twice.</Empty></Card>}>
      {(rows) => <div className="grid g2">{rows.map((l) => {
        const pct = l.target_amount ? Number((BigInt(l.collected) * 1000n) / BigInt(l.target_amount)) / 10 : null;
        return <a key={l.id} href={`#/split/${l.id}`} className="card stat" style={{ color: 'inherit', textDecoration: 'none' }}>
          <div className="row"><b>{l.title}</b><div className="spacer" /><Status s={l.status} /></div>
          <div className="value"><Money minor={l.collected} currency={l.currency} /></div>
          <div className="sub">{l.target_amount ? <>of <Money minor={l.target_amount} currency={l.currency} /> target · {l.payments} payments</> : <>{l.payments} payments</>}</div>
          {pct !== null && <div className="bar-track" style={{ marginTop: 10 }}><div className="bar-fill" style={{ width: Math.min(pct, 100) + '%' }} /></div>}
          {l.failed_distributions > 0 && <div className="small" style={{ color: 'var(--red)', marginTop: 8 }}>{l.failed_distributions} distribution(s) retrying</div>}
        </a>;
      })}</div>}
    </Gate>
    <CreateLink open={creating} onClose={() => setCreating(false)} split onCreated={(nid) => go('split/' + nid)} />
  </>;
}

interface Rcpt { username: string; user?: { id: string; username: string; display_name: string; verified: boolean } | null; value: string; error?: string }

function CreateLink({ open, onClose, split, onCreated }: { open: boolean; onClose: () => void; split: boolean; onCreated: (id: string) => void }) {
  const { sb, session } = useApp();
  const { run, busy } = useAct();
  const flag = useFlags();
  const assets = useOp<any[]>('biz.link_assets', {}, { skip: !open });
  const [f, setF] = useState({ title: '', description: '', asset: 'USDT|TRC20', amount_mode: 'flexible', amount: '', target: '', expires: '', invoice: '', ref: false,
    fee_bearer: 'deduct', method: 'percentage', settlement: 'each_payment', alloc: 'exact' });
  const [rc, setRc] = useState<Rcpt[]>([{ username: '', value: '' }, { username: '', value: '' }]);
  const [step, setStep] = useState<'edit' | 'review'>('edit');
  const [cur, net] = f.asset.split('|');
  const ngn = cur === 'NGN';
  const ngnFlag = flag('business.ngn_collections');
  const set = (k: string) => (e: any) => setF({ ...f, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value });

  const lookup = async (i: number, name: string) => {
    const u = name.replace(/^@/, '').trim().toLowerCase();
    if (!u) return;
    try {
      const r: any = await sb.run('biz.lookup_user', session, { username: u });
      setRc((x) => x.map((y, j) => j === i ? { ...y, user: r, error: r ? (r.verified ? undefined : `@${u} must verify their Knock account first`) : `No Knock user @${u}` } : y));
    } catch (e: any) { setRc((x) => x.map((y, j) => j === i ? { ...y, error: e.message } : y)); }
  };

  // Live allocation calculator (display only; the database recomputes and validates).
  const calc = useMemo(() => {
    const target = toMinor(f.target, cur);
    if (f.method === 'percentage') {
      const bps = rc.map((r) => Math.round(Number(r.value || 0) * 100));
      const total = bps.reduce((a, b) => a + b, 0);
      return { total, ok: total === 10000 || (f.alloc === 'remainder_to_creator' && total < 10000), shares: bps.map((b) => target ? (BigInt(target) * BigInt(b)) / 10000n : null), label: (total / 100).toFixed(2) + '%', target };
    }
    const amts = rc.map((r) => BigInt(toMinor(r.value, cur) ?? '0'));
    const total = amts.reduce((a, b) => a + b, 0n);
    return { total, ok: !!target && (total === BigInt(target) || (f.alloc === 'remainder_to_creator' && total < BigInt(target))), shares: amts, label: fmtMoney(total, cur), target };
  }, [rc, f.method, f.target, f.alloc, cur]);

  const fixed = toMinor(f.amount, cur);
  const problems: string[] = [];
  if (!f.title.trim()) problems.push('Add a title.');
  if (f.amount_mode === 'fixed' && !fixed) problems.push('Enter the amount each customer pays.');
  if (ngn && !ngnFlag?.enabled) problems.push('Naira links are not enabled yet.');
  if (split) {
    if (rc.some((r) => !r.user || r.error)) problems.push('Every recipient must be a verified Knock user.');
    if (!calc.ok) problems.push(f.method === 'percentage' ? 'Percentages must add up to 100%.' : 'Fixed amounts must add up to the target.');
    if ((f.method === 'fixed' || f.settlement === 'on_target') && !calc.target) problems.push('Set the expected total.');
    if (new Set(rc.map((r) => r.user?.id)).size !== rc.length) problems.push('Each recipient can appear once.');
  }

  const submit = async () => {
    const body: any = { link_type: split ? 'split' : ngn ? 'naira' : 'crypto', title: f.title.trim(), description: f.description.trim() || null, currency: cur, network: net,
      amount_mode: f.amount_mode, fixed_amount: f.amount_mode === 'fixed' ? fixed : null, target_amount: toMinor(f.target, cur), fee_bearer: f.fee_bearer,
      expires_at: f.expires ? new Date(f.expires + 'T23:59:00').toISOString() : null, invoice_number: f.invoice || null, require_customer_reference: f.ref };
    if (split) Object.assign(body, { split_method: f.method, settlement_mode: f.settlement, allocation_mode: f.alloc,
      recipients: rc.map((r) => f.method === 'percentage' ? { recipient_id: r.user!.id, basis_points: Math.round(Number(r.value) * 100) } : { recipient_id: r.user!.id, allocated_amount: toMinor(r.value, cur) }) });
    const r = await run<any>('biz.create_link', { link: body }, split ? 'Split link created' : 'Payment link created');
    if (r) { onClose(); setStep('edit'); onCreated(r.id); }
  };

  const assetOpts = (assets.data ?? []).filter((a) => a.kind === 'fiat' || a.decimals === decimals(a.code));
  return <Modal open={open} onClose={onClose} title={split ? 'New Smart Split link' : 'New payment link'}>
    {step === 'edit' ? <div className="stack">
      <Field label="Title"><input className="input" value={f.title} onChange={set('title')} maxLength={80} placeholder={split ? 'e.g. Owambe event crew' : 'e.g. Party tray order'} /></Field>
      <Field label="Description" hint="Shown to customers on the payment page."><textarea className="input" rows={2} value={f.description} onChange={set('description')} maxLength={500} /></Field>
      <div className="grid g2">
        <Field label="Currency" hint={ngn && !ngnFlag?.enabled ? 'Needs: ' + ngnFlag?.depends_on : undefined}>
          <select className="input" value={f.asset} onChange={set('asset')}>{assetOpts.map((a) => <option key={a.code + a.network} value={a.code + '|' + a.network}>{a.kind === 'fiat' ? 'Naira (NGN)' : `${a.code} · ${a.network}`}</option>)}</select></Field>
        <Field label="Amount"><Seg value={f.amount_mode} onChange={(v) => setF({ ...f, amount_mode: v })} options={[['flexible', 'Customer enters'], ['fixed', 'Fixed']]} /></Field>
      </div>
      {f.amount_mode === 'fixed' && <Field label={`Amount (${cur})`}><input className="input num" inputMode="decimal" value={f.amount} onChange={set('amount')} placeholder="0.00" /></Field>}
      {split && <>
        <div className="grid g2">
          <Field label="Split by"><Seg value={f.method} onChange={(v) => setF({ ...f, method: v })} options={[['percentage', 'Percentage'], ['fixed', 'Fixed amount']]} /></Field>
          <Field label={`Expected total (${cur})`} hint={f.method === 'fixed' ? 'Required for fixed amounts.' : 'Optional. Lets you track progress.'}><input className="input num" inputMode="decimal" value={f.target} onChange={set('target')} /></Field>
        </div>
        <Field label="When to pay recipients">
          <select className="input" value={f.settlement} onChange={set('settlement')}>
            <option value="each_payment">After each confirmed payment</option><option value="on_target">When the target is reached</option><option value="manual">Manually, when I choose</option></select></Field>
        <div className="stack tight">
          <div className="row"><b>Recipients</b><div className="spacer" /><button className="btn sm" type="button" onClick={() => setRc([...rc, { username: '', value: '' }])} disabled={rc.length >= 20}>+ Add recipient</button></div>
          {rc.map((r, i) => <div key={i} className="stack tight">
            <div className="row">
              <input className="input" style={{ flex: 2 }} placeholder="@username" value={r.username} onChange={(e) => setRc(rc.map((y, j) => j === i ? { ...y, username: e.target.value, user: null, error: undefined } : y))} onBlur={(e) => lookup(i, e.target.value)} aria-label={`Recipient ${i + 1} username`} />
              <input className="input num" style={{ flex: 1 }} placeholder={f.method === 'percentage' ? '%' : cur} inputMode="decimal" value={r.value} onChange={(e) => setRc(rc.map((y, j) => j === i ? { ...y, value: e.target.value } : y))} aria-label={`Recipient ${i + 1} share`} />
              <span className="small num muted" style={{ width: 110, textAlign: 'right' }}>{calc.shares[i] !== null && calc.shares[i] !== undefined ? fmtMoney(calc.shares[i]!, cur) : ''}</span>
              <button className="btn ghost sm" type="button" onClick={() => setRc(rc.filter((_, j) => j !== i))} disabled={rc.length <= 1} aria-label="Remove recipient">✕</button>
            </div>
            {(r.user || r.error) && <div className="small" style={{ color: r.error ? 'var(--red)' : 'var(--green-strong)', paddingLeft: 4 }}>{r.error ?? `✓ ${r.user!.display_name} · verified`}</div>}
          </div>)}
          <div className={'notice ' + (calc.ok ? 'good' : 'warn')}>Allocated: <b className="num">{calc.label}</b> {f.method === 'percentage' ? 'of 100%' : calc.target ? `of ${fmtMoney(calc.target, cur)}` : ''}
            <label className="check small" style={{ marginTop: 6 }}><input type="checkbox" checked={f.alloc === 'remainder_to_creator'} onChange={(e) => setF({ ...f, alloc: e.target.checked ? 'remainder_to_creator' : 'exact' })} /> Keep any unallocated remainder for this business</label></div>
        </div>
      </>}
      <div className="grid g2">
        <Field label="Expires (optional)"><input type="date" className="input" value={f.expires} min={new Date().toISOString().slice(0, 10)} onChange={set('expires')} /></Field>
        <Field label="Invoice reference (optional)"><input className="input" value={f.invoice} onChange={set('invoice')} maxLength={40} /></Field>
      </div>
      <div className="row wrap">
        <label className="check"><input type="checkbox" checked={f.ref} onChange={set('ref')} /> Ask customers for a reference</label>
        <label className="check"><input type="checkbox" checked={f.fee_bearer === 'payer'} onChange={(e) => setF({ ...f, fee_bearer: e.target.checked ? 'payer' : 'deduct' })} /> Customer pays the Knock fee</label>
      </div>
      {problems.length > 0 && <div className="small muted">{problems.join(' ')}</div>}
      <div className="row"><div className="spacer" /><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={problems.length > 0} onClick={() => setStep('review')}>Review</button></div>
    </div> : <div className="stack">
      <div className="kv">
        <div>Title</div><div><b>{f.title}</b></div>
        <div>Currency</div><div>{cur}{net !== 'fiat' ? ' · ' + net : ''}</div>
        <div>Amount</div><div>{f.amount_mode === 'fixed' ? fmtMoney(fixed, cur) : 'Customer enters amount'}</div>
        {calc.target && <><div>Expected total</div><div>{fmtMoney(calc.target, cur)}</div></>}
        <div>Knock fee</div><div>{f.fee_bearer === 'payer' ? 'Paid by customer' : 'Deducted from each payment'}</div>
        {split && <><div>Recipients</div><div>{rc.map((r, i) => <div key={i}>@{r.user?.username} · {f.method === 'percentage' ? r.value + '%' : fmtMoney(toMinor(r.value, cur), cur)}</div>)}</div>
          <div>Pay recipients</div><div>{f.settlement === 'each_payment' ? 'After each confirmed payment' : f.settlement === 'on_target' ? 'When the target is reached' : 'Manually'}</div></>}
      </div>
      {split && <div className="notice">After the first payment, these rules are locked. Changes create a new version and keep the old one for payments already received.</div>}
      <div className="row"><button className="btn" onClick={() => setStep('edit')}>Back</button><div className="spacer" /><button className="btn primary" disabled={busy} onClick={submit}>Create link</button></div>
    </div>}
  </Modal>;
}

function Share({ slug, title }: { slug: string; title: string }) {
  const url = payUrl(slug);
  return <div className="row wrap" style={{ alignItems: 'flex-start' }}>
    <QR text={url} />
    <div className="stack tight" style={{ flex: 1, minWidth: 220 }}>
      <div className="mono small" style={{ wordBreak: 'break-all' }}>{url}</div>
      <div className="row wrap"><Copy text={url} label="Copy link" /><a className="btn sm" href={"#/pay/" + slug}>Open payment page</a>
        {'share' in navigator && <button className="btn sm" onClick={() => (navigator as any).share({ title, url }).catch(() => {})}>Share</button>}</div>
      <div className="small muted">Sandbox: records live in this browser tab only, so open the page here. A new tab starts a fresh sandbox.</div>
    </div>
  </div>;
}

function SimPay({ slug, currency, fixed }: { slug: string; currency: string; fixed: string | null }) {
  const { sb } = useApp();
  const { sim, busy } = useAct();
  const [amt, setAmt] = useState('');
  return <div className="notice warn"><b>Sandbox:</b> simulate a customer paying this link (production: the provider's verified webhook does this).
    <div className="row wrap" style={{ marginTop: 8 }}>
      {!fixed && <input className="input num" style={{ width: 140 }} placeholder={`Amount ${currency}`} value={amt} onChange={(e) => setAmt(e.target.value)} />}
      <button className="btn sm primary" disabled={busy || (!fixed && !toMinor(amt, currency))} onClick={() => sim(() => sb.sim.pay(slug, fixed ? null : toMinor(amt, currency), { name: 'Sandbox Customer', email: 'customer@example.com' }), 'Payment confirmed and recorded')}>Simulate successful payment</button>
      <button className="btn sm" disabled={busy || (!fixed && !toMinor(amt, currency))} onClick={() => sim(() => sb.sim.pay(slug, fixed ? null : toMinor(amt, currency), { name: 'Sandbox Customer', email: 'customer@example.com' }, 'failed'), 'Failed payment recorded')}>Simulate failed payment</button>
    </div></div>;
}

function LinkActions({ biz, l }: { biz: Biz; l: any }) {
  const { run, busy } = useAct();
  const [confirm, setConfirm] = useState(false);
  if (!can(biz, 'links.manage')) return null;
  return <div className="row wrap">
    {l.status === 'active' && <button className="btn" disabled={busy} onClick={() => run('biz.link_action', { id: l.id, action: 'pause' }, 'Link paused')}>Pause</button>}
    {l.status === 'paused' && <button className="btn" disabled={busy} onClick={() => run('biz.link_action', { id: l.id, action: 'resume' }, 'Link active again')}>Resume</button>}
    {!['closed', 'under_review'].includes(l.status) && <button className="btn danger" onClick={() => setConfirm(true)}>Close link</button>}
    <Modal open={confirm} onClose={() => setConfirm(false)} title="Close this link?">
      <p>Customers will no longer be able to pay "{l.title}". Payments already received are not affected. This cannot be undone.</p>
      <div className="row"><div className="spacer" /><button className="btn" onClick={() => setConfirm(false)}>Keep it</button>
        <button className="btn danger" disabled={busy} onClick={async () => { await run('biz.link_action', { id: l.id, action: 'close' }, 'Link closed'); setConfirm(false); }}>Close link</button></div>
    </Modal>
  </div>;
}

function LinkDrawer({ biz, id, onClose }: { biz: Biz; id: string | null; onClose: () => void }) {
  const q = useOp<any>('biz.link', { id }, { skip: !id });
  return <Drawer open={!!id} onClose={onClose} title="Payment link">
    <Gate q={q} empty={<Empty title="Link not found" />}>{(l) => <div className="stack">
      <div><div className="row"><h2>{l.title}</h2><div className="spacer" /><Status s={l.status} /></div><div className="muted small mono">{l.reference}</div>{l.description && <p className="muted">{l.description}</p>}</div>
      <div className="grid g2">
        <div className="card stat"><div className="label">Collected</div><div className="value"><Money minor={l.collected} currency={l.currency} /></div></div>
        <div className="card stat"><div className="label">Amount</div><div className="value" style={{ fontSize: 18 }}>{l.amount_mode === 'fixed' ? <Money minor={l.fixed_amount} currency={l.currency} /> : 'Flexible'}</div><div className="sub">{l.currency}{l.network !== 'fiat' ? ' · ' + l.network : ''}</div></div>
      </div>
      {['active'].includes(l.status) && <Share slug={l.slug} title={l.title} />}
      <LinkActions biz={biz} l={l} />
      {l.status === 'active' && <SimPay slug={l.slug} currency={l.currency} fixed={l.amount_mode === 'fixed' ? l.fixed_amount : null} />}
      <div className="kv small"><div>Expires</div><div>{l.expires_at ? fmtDate(l.expires_at) : 'Never'}</div><div>Invoice</div><div>{l.invoice_number ?? '—'}</div><div>Fee paid by</div><div>{l.fee_bearer === 'payer' ? 'Customer' : 'Business (deducted)'}</div></div>
      <Card title="Payment history" pad={false}><Table rows={l.payments} cols={[
        { h: 'Date', c: (p: any) => <span className="small">{fmtDate(p.at)}</span> }, { h: 'Customer', c: (p: any) => p.payer ?? '—' },
        { h: 'Status', c: (p: any) => <Status s={p.status} /> }, { h: 'Amount', right: true, c: (p: any) => <Money minor={p.amount} currency={l.currency} /> },
      ]} empty={<div className="card-b muted">No payments yet. Share the link to get paid.</div>} /></Card>
    </div>}</Gate>
  </Drawer>;
}

function SplitDetail({ biz, id }: { biz: Biz; id: string }) {
  const q = useOp<any>('biz.link', { id });
  const { run, busy } = useAct();
  return <Gate q={q} empty={<Empty title="Split link not found" />}>{(l) => {
    const target = l.target_amount ? BigInt(l.target_amount) : null;
    const collected = BigInt(l.collected);
    const held = l.payments.filter((p: any) => p.distribution === 'held').length;
    const failed = l.payments.filter((p: any) => p.distribution === 'failed_retrying');
    return <div className="stack">
      <PageHead title={l.title} sub={<><a href="#/split">Smart Split</a> · <span className="mono">{l.reference}</span> · rules version {l.current_rule_version}</>} actions={<><Status s={l.status} /><LinkActions biz={biz} l={l} /></>} />
      <div className="grid g4">
        <Stat2 label="Total expected" v={target !== null ? <Money minor={target} currency={l.currency} /> : 'Open-ended'} />
        <Stat2 label="Total collected" v={<Money minor={collected} currency={l.currency} />} />
        <Stat2 label="Remaining" v={target !== null ? <Money minor={target > collected ? target - collected : 0n} currency={l.currency} /> : '—'} />
        <Stat2 label="Payments" v={l.payments.filter((p: any) => p.status === 'succeeded').length} />
      </div>
      {target !== null && <div className="bar-track"><div className="bar-fill" style={{ width: Math.min(100, Number((collected * 100n) / target)) + '%' }} /></div>}
      {failed.length > 0 && <div className="notice bad">{failed.length} distribution(s) failed and are being retried automatically. Nothing was paid twice.</div>}
      {held > 0 && <div className="notice warn row wrap">{held} payment(s) are confirmed and waiting to be distributed{l.settlement_mode === 'manual' ? ' (manual mode)' : l.settlement_mode === 'on_target' ? ' until the target is reached' : ''}.
        {can(biz, 'splits.manage') && l.settlement_mode !== 'each_payment' && <><span className="spacer" /><button className="btn sm primary" disabled={busy} onClick={() => run('biz.distribute_held', { id: l.id }, 'Distribution recorded')}>Distribute now</button></>}</div>}
      <div className="grid g2">
        <Card title="Recipients" pad={false}><Table rows={l.recipients} cols={[
          { h: 'Recipient', c: (r: any) => <div><div>{r.display_name}</div><div className="small muted">@{r.username}</div></div> },
          { h: 'Share', right: true, c: (r: any) => (r.basis_points / 100).toFixed(2) + '%' },
          { h: 'Received', right: true, c: (r: any) => <Money minor={r.received} currency={l.currency} /> },
          { h: 'Pending', right: true, c: (r: any) => <Money minor={r.pending} currency={l.currency} /> },
        ]} /></Card>
        <div className="stack">
          {l.status === 'active' && <Card title="Share this link"><Share slug={l.slug} title={l.title} /></Card>}
          {l.status === 'active' && <SimPay slug={l.slug} currency={l.currency} fixed={l.amount_mode === 'fixed' ? l.fixed_amount : null} />}
        </div>
      </div>
      <Card title="Payment history" pad={false}><Table rows={l.payments} cols={[
        { h: 'Date', c: (p: any) => <span className="small">{fmtDate(p.at)}</span> }, { h: 'Customer', c: (p: any) => p.payer ?? '—' },
        { h: 'Payment', c: (p: any) => <Status s={p.status} /> }, { h: 'Distribution', c: (p: any) => <Status s={p.distribution === 'none' ? 'pending' : p.distribution} /> },
        { h: 'Amount', right: true, c: (p: any) => <Money minor={p.amount} currency={l.currency} /> }, { h: 'Knock fee', right: true, c: (p: any) => <Money minor={p.fee} currency={l.currency} /> },
      ]} empty={<div className="card-b muted">No payments yet.</div>} /></Card>
    </div>;
  }}</Gate>;
}
const Stat2 = ({ label, v }: { label: string; v: any }) => <div className="card stat"><div className="label">{label}</div><div className="value" style={{ fontSize: 20 }}>{v}</div></div>;

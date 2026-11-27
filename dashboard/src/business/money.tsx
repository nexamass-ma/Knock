import { useState } from 'react';
import { Card, Copy, Empty, Field, Gate, Modal, Money, PageHead, QR, Seg, Status, Table, fmtDate, fmtMoney, toMinor, useAct, useApp, useOp } from '../ui/kit.tsx';
import { can, type Biz } from './App.tsx';

const today = () => { const d = new Date(); d.setHours(0, 0, 0, 0); return d; };
function useBalances() {
  const from = today(); const to = new Date(from.getTime() + 86400000);
  const q = useOp<any>('biz.overview', { from: from.toISOString(), to: to.toISOString() });
  return q;
}

// ---------------------------------------------------------------- Crypto
export function Crypto({ biz }: { biz: Biz }) {
  const assets = useOp<any[]>('biz.assets');
  const addrs = useOp<any[]>('biz.addresses', {}, { skip: !can(biz, 'crypto.receive') });
  const deps = useOp<any[]>('biz.deposits');
  const { run, busy } = useAct();
  const [show, setShow] = useState<any>(null);
  const [sim, setSim] = useState<any>(null);
  const verified = biz.verification_status === 'verified';
  return <>
    <PageHead title="Crypto" sub="Receive crypto into this business through Breet. A deposit only counts after Breet confirms it and the risk checks pass." />
    <div className="grid g2">
      <Card title="Receive crypto" pad={false}>
        <Gate q={assets} empty={<div className="card-b muted">No assets are configured yet.</div>}>{(rows) => <Table rows={rows} cols={[
          { h: 'Asset', c: (a) => <b>{a.symbol}</b> }, { h: 'Network', c: (a) => a.network },
          { h: 'Minimum', right: true, c: (a) => a.min_deposit ? <span className="num">{a.min_deposit}</span> : '—' },
          { h: '', right: true, c: (a) => {
            const have = addrs.data?.find((x) => x.asset_id === a.asset_id && ['active', 'requested'].includes(x.status));
            if (!a.deposit_enabled) return <span className="small muted">Paused by provider</span>;
            if (have) return <button className="btn sm" onClick={() => setShow(have)}>Show address</button>;
            if (!can(biz, 'crypto.receive')) return <span className="small muted">No permission</span>;
            return <button className="btn sm primary" disabled={busy || !verified} title={verified ? undefined : 'Verify the business first'}
              onClick={async () => { const r = await run<any>('biz.request_address', { asset_id: a.asset_id }, 'Address requested from Breet'); if (r?.address) setShow(r.address); }}>Get address</button>;
          } },
        ]} />}</Gate>
      </Card>
      <Card title="Your deposit addresses" pad={false}>
        <Gate q={addrs} empty={<div className="card-b muted">No addresses yet. Pick an asset to get one.</div>}>{(rows) => <Table rows={rows} onRow={setShow} cols={[
          { h: 'Asset', c: (a) => <b>{a.symbol} · {a.network}</b> }, { h: 'Address', c: (a) => a.address ? <span className="mono small">{a.address.slice(0, 10)}…{a.address.slice(-6)}</span> : <span className="small muted">Waiting for Breet</span> },
          { h: 'Status', c: (a) => <Status s={a.status} /> },
        ]} />}</Gate>
      </Card>
    </div>
    <Card title="Deposits" pad={false} actions={addrs.data?.some((x) => x.address) ? <button className="btn sm" onClick={() => setSim(addrs.data!.find((x) => x.address))}>Sandbox: simulate deposit</button> : undefined}>
      <Gate q={deps} empty={<Empty title="No deposits yet">Deposits sent to your addresses appear here as soon as Breet sees them.</Empty>}>{(rows) => <Table rows={rows} cols={[
        { h: 'Date', c: (d) => <span className="small">{fmtDate(d.created_at)}</span> },
        { h: 'Reference', c: (d) => <span className="mono small">{d.knock_reference}</span> },
        { h: 'Received', c: (d) => <span className="num">{d.crypto_amount ?? '—'} {d.symbol}</span> },
        { h: 'Status', c: (d) => <div><Status s={d.status} />{d.flag_reason && <div className="small muted">{d.flag_reason}</div>}</div> },
        { h: 'Confirmations', c: (d) => d.required_confirmations ? `${d.confirmations ?? 0}/${d.required_confirmations}` : d.confirmations ?? '—' },
        { h: 'Fee', right: true, c: (d) => d.knock_fee_minor ? <Money minor={d.knock_fee_minor} currency={d.credited_currency} /> : '—' },
        { h: 'Credited', right: true, c: (d) => d.status === 'completed' && d.customer_net_minor ? <b><Money minor={d.customer_net_minor} currency={d.credited_currency} /></b> : <span className="muted small">Not credited</span> },
      ]} />}</Gate>
    </Card>
    <Modal open={!!show} onClose={() => setShow(null)} title={show ? `Deposit ${show.symbol} on ${show.network}` : ''}>
      {show && !show.address && <PendingAddress a={show} onReady={(x) => setShow(x)} />}
      {show && show.address && <div className="stack" style={{ alignItems: 'center', textAlign: 'center' }}>
        <QR text={show.address} size={5} />
        <div className="mono" style={{ wordBreak: 'break-all' }}>{show.address}</div>
        {show.memo && <div>Memo / tag: <b className="mono">{show.memo}</b></div>}
        <Copy text={show.address} label="Copy address" />
        <div className="notice warn" style={{ textAlign: 'left' }}>Send only <b>{show.symbol}</b> on the <b>{show.network}</b> network to this address. Other assets or networks can be lost and are not credited automatically.
          Deposits below the minimum are held. Funds are credited after network confirmations and Breet's checks.</div>
      </div>}
    </Modal>
    <SimDeposit addr={sim} addrs={addrs.data ?? []} onClose={() => setSim(null)} />
  </>;
}

function PendingAddress({ a, onReady }: { a: any; onReady: (x: any) => void }) {
  const { sb } = useApp();
  const { sim, busy } = useAct();
  return <div className="stack">
    <p>Knock asked Breet for a {a.symbol} ({a.network}) address. It appears here as soon as Breet returns it. Don't send funds until you see the address.</p>
    <div className="notice warn"><b>Sandbox:</b> play Breet's generate-address response.
      <div style={{ marginTop: 8 }}><button className="btn sm primary" disabled={busy} onClick={async () => { const r = await sim(() => sb.sim.address(a.id), 'Breet returned the address'); if (r?.address) onReady(r.address); }}>Return address from Breet</button></div></div>
  </div>;
}

function SimDeposit({ addr, addrs, onClose }: { addr: any; addrs: any[]; onClose: () => void }) {
  const { sb } = useApp();
  const { sim, busy } = useAct();
  const [a, setA] = useState<string>('');
  const [ngn, setNgn] = useState('250000');
  const [sc, setSc] = useState<'completed' | 'confirming' | 'under_review' | 'below_minimum' | 'failed'>('completed');
  const id = a || addr?.id;
  return <Modal open={!!addr} onClose={onClose} title="Sandbox: simulate a Breet deposit">
    <div className="stack">
      <div className="notice">This plays the part of Breet's verified webhook. It records a webhook event and runs the same deposit functions production uses.</div>
      <Field label="Address"><select className="input" value={id ?? ''} onChange={(e) => setA(e.target.value)}>{addrs.filter((x) => x.address).map((x) => <option key={x.id} value={x.id}>{x.symbol} · {x.network} · {x.address.slice(0, 12)}…</option>)}</select></Field>
      <Field label="Value in Naira (NGN)"><input className="input num" value={ngn} onChange={(e) => setNgn(e.target.value.replace(/[^\d]/g, ''))} /></Field>
      <Field label="Outcome"><select className="input" value={sc} onChange={(e) => setSc(e.target.value as any)}>
        <option value="completed">Completed and credited</option><option value="confirming">Still confirming (pending)</option>
        <option value="under_review">Flagged for KYT review (not credited)</option><option value="below_minimum">Below minimum (held)</option><option value="failed">Failed</option></select></Field>
      <div className="row"><div className="spacer" /><button className="btn" onClick={onClose}>Cancel</button>
        <button className="btn primary" disabled={busy || !id || !Number(ngn)} onClick={async () => { const r = await sim(() => sb.sim.deposit(id, sc, Number(ngn)), 'Deposit event processed'); if (r) onClose(); }}>Send event</button></div>
    </div>
  </Modal>;
}

// ---------------------------------------------------------------- Withdrawals
export function Withdrawals({ biz }: { biz: Biz }) {
  const q = useOp<any[]>('biz.payouts');
  const bal = useBalances();
  const flags = useOp<any[]>('biz.flags');
  const settings = useOp<any>('biz.settings');
  const { run, busy } = useAct();
  const { sb, session } = useApp();
  const act = useAct();
  const [open, setOpen] = useState(false);
  const [filter, setFilter] = useState('');
  const flag = (k: string) => flags.data?.find((f) => f.key === k);
  const ngn = bal.data?.balances?.find((b: any) => b.currency === 'NGN');
  const rows = (q.data ?? []).filter((r) => !filter || (filter === 'waiting' ? r.status === 'pending_approval' : r.status === filter));
  const waiting = (q.data ?? []).filter((r) => r.status === 'pending_approval');
  return <>
    <PageHead title="Withdrawals" sub="Move money out of the business. Payouts above your approval limit need a second team member."
      actions={can(biz, 'withdrawals.initiate') && <button className="btn primary" onClick={() => setOpen(true)} disabled={biz.verification_status !== 'verified'}>New withdrawal</button>} />
    <div className="grid g4">
      <div className="card stat"><div className="label">Available (NGN)</div><div className="value"><Money minor={ngn?.available ?? '0'} currency="NGN" /></div></div>
      <div className="card stat"><div className="label">Reserved for payouts</div><div className="value"><Money minor={ngn?.reserved ?? '0'} currency="NGN" /></div></div>
      <div className="card stat"><div className="label">Waiting for approval</div><div className="value">{waiting.length}</div></div>
      <div className="card stat"><div className="label">Second approval above</div><div className="value" style={{ fontSize: 18 }}>{settings.data ? <Money minor={settings.data.payout_dual_approval_above} currency="NGN" /> : '…'}</div></div>
    </div>
    <div className="row wrap" style={{ margin: '4px 0 12px' }}>
      {[['business.crypto_payouts', 'Crypto payouts'], ['business.bank_payouts', 'Bank payouts (9PSB)']].map(([k, l]) => { const f = flag(k); return f &&
        <span key={k} className="small"><Status s={f.enabled ? 'enabled' : 'disabled'} label={`${l}: ${f.enabled ? 'on' : 'off'}`} />{!f.enabled && f.depends_on && <span className="muted"> · needs {f.depends_on}</span>}</span>; })}
    </div>
    <Card pad={false}>
      <div className="card-b" style={{ borderBottom: '1px solid var(--line)' }}><Seg value={filter} onChange={setFilter} options={[['', 'All'], ['waiting', `Waiting (${waiting.length})`], ['approved', 'Approved'], ['rejected', 'Rejected']]} /></div>
      <Gate q={q}>{() => <Table rows={rows} empty={<Empty title="No withdrawals yet">Withdrawals you or your team request appear here with every approval step.</Empty>} cols={[
        { h: 'Requested', c: (r) => <div><div className="small">{fmtDate(r.created_at)}</div><div className="small muted">by @{r.requested_by}</div></div> },
        { h: 'Reference', c: (r) => <span className="mono small">{r.reference}</span> },
        { h: 'To', c: (r) => r.kind === 'crypto' ? <div><div>{r.asset} · {r.network}</div><div className="mono small muted">{r.destination?.slice(0, 10)}…{r.destination?.slice(-4)}</div></div> : 'Bank account' },
        { h: 'Amount', right: true, c: (r) => <b><Money minor={r.amount_minor} currency={r.currency} /></b> },
        { h: 'Approval', c: (r) => <div><Status s={r.status} />{r.approved_by && <div className="small muted">{r.status === 'rejected' ? 'rejected' : 'approved'} by @{r.approved_by}</div>}{r.status === 'pending_approval' && r.needs_second_approver && <div className="small muted">needs a second approver</div>}</div> },
        { h: 'Payout', c: (r) => r.withdrawal_status ? <div><Status s={r.withdrawal_status} />{r.withdrawal_error && <div className="small" style={{ color: 'var(--red)' }}>{r.withdrawal_error}</div>}</div> : <span className="muted small">—</span> },
        { h: '', right: true, c: (r) => <div className="row" style={{ justifyContent: 'flex-end' }}>
          {r.status === 'pending_approval' && can(biz, 'withdrawals.approve') && !(r.mine && r.needs_second_approver) && <>
            <button className="btn sm primary" disabled={busy} onClick={(e) => { e.stopPropagation(); run('biz.decide_payout', { id: r.id, approve: true, note: null }, 'Payout approved and reserved'); }}>Approve</button>
            <button className="btn sm danger" disabled={busy} onClick={(e) => { e.stopPropagation(); run('biz.decide_payout', { id: r.id, approve: false, note: 'Rejected in dashboard' }, 'Payout rejected'); }}>Reject</button></>}
          {r.status === 'pending_approval' && r.mine && r.needs_second_approver && <span className="small muted">Another approver needed</span>}
          {r.withdrawal_id && ['reserved', 'submitted', 'processing'].includes(r.withdrawal_status) && <select className="input" style={{ width: 'auto', padding: '3px 6px', fontSize: 12 }} value="" disabled={act.busy}
            onChange={(e) => { const v = e.target.value as any; if (v) act.sim(() => sb.sim.withdrawal(r.withdrawal_id, v), 'Provider event processed'); }} aria-label="Sandbox: provider outcome">
            <option value="">Sandbox: Breet says…</option><option value="processing">processing</option><option value="completed">completed</option><option value="rejected">rejected (refund)</option></select>}
        </div> },
      ]} />}</Gate>
    </Card>
    <NewPayout open={open} onClose={() => setOpen(false)} available={ngn?.available ?? '0'} threshold={settings.data?.payout_dual_approval_above ?? '0'}
      cryptoOn={!!flag('business.crypto_payouts')?.enabled} bankOn={!!flag('business.bank_payouts')?.enabled} sessionUser={session.userId} />
  </>;
}

function NewPayout({ open, onClose, available, threshold, cryptoOn, bankOn }: { open: boolean; onClose: () => void; available: string; threshold: string; cryptoOn: boolean; bankOn: boolean; sessionUser: string }) {
  const { run, busy } = useAct();
  const assets = useOp<any[]>('biz.assets', {}, { skip: !open });
  const [kind, setKind] = useState<'crypto' | 'bank'>('crypto');
  const [f, setF] = useState({ asset: '', amount: '', address: '', note: '' });
  const [step, setStep] = useState<'edit' | 'review'>('edit');
  const [ack, setAck] = useState(false);
  const wd = (assets.data ?? []).filter((a) => a.withdraw_enabled);
  const asset = wd.find((a) => a.asset_id === f.asset) ?? wd[0];
  const amt = toMinor(f.amount, 'NGN');
  const dual = amt ? BigInt(amt) > BigInt(threshold) : false;
  const problems: string[] = [];
  if (kind === 'crypto' && !cryptoOn) problems.push('Crypto payouts are switched off.');
  if (kind === 'bank' && !bankOn) problems.push('Bank payouts are not available until the 9PSB integration is approved.');
  if (!amt) problems.push('Enter an amount.');
  else if (BigInt(amt) > BigInt(available)) problems.push('This is more than the available balance.');
  if (kind === 'crypto' && f.address.trim().length < 20) problems.push('Enter the destination wallet address.');
  const close = () => { onClose(); setStep('edit'); setAck(false); };
  const submit = async () => {
    const r = await run<any>('biz.request_payout', { payout: { kind, currency: 'NGN', amount_minor: amt, asset: asset?.symbol, network: asset?.network, destination_address: f.address.trim(), note: f.note || null } },
      dual ? 'Payout requested. A second approver must confirm it.' : 'Payout approved and reserved');
    if (r) { close(); setF({ asset: '', amount: '', address: '', note: '' }); }
  };
  return <Modal open={open} onClose={close} title="New withdrawal">
    {step === 'edit' ? <div className="stack">
      <Seg value={kind} onChange={setKind} options={[['crypto', 'To a crypto wallet'], ['bank', 'To a bank account']]} />
      {kind === 'bank' ? <div className="notice warn">Bank payouts run through 9PSB, which is not connected yet. This option turns on when Knock enables <b>business.bank_payouts</b>.</div> : <>
        <Field label="Asset and network"><select className="input" value={asset?.asset_id ?? ''} onChange={(e) => setF({ ...f, asset: e.target.value })}>
          {wd.map((a) => <option key={a.asset_id} value={a.asset_id}>{a.symbol} · {a.network}{a.withdrawal_fee ? ` (network fee ${a.withdrawal_fee})` : ''}</option>)}</select></Field>
        <Field label="Destination address" hint="Double-check it. Crypto sent to a wrong address cannot be recovered."><input className="input mono" value={f.address} onChange={(e) => setF({ ...f, address: e.target.value })} autoComplete="off" spellCheck={false} /></Field>
      </>}
      <Field label="Amount (NGN)" hint={<>Available: {fmtMoney(available, 'NGN')}. Breet converts at its rate when it pays out.</>}>
        <input className="input num" inputMode="decimal" value={f.amount} onChange={(e) => setF({ ...f, amount: e.target.value })} placeholder="0.00" /></Field>
      <Field label="Note for your team (optional)"><input className="input" maxLength={140} value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} /></Field>
      {problems.length > 0 && <div className="small muted">{problems.join(' ')}</div>}
      <div className="row"><div className="spacer" /><button className="btn" onClick={close}>Cancel</button><button className="btn primary" disabled={problems.length > 0} onClick={() => setStep('review')}>Review</button></div>
    </div> : <div className="stack">
      <div className="kv">
        <div>Amount</div><div><b>{fmtMoney(amt, 'NGN')}</b></div>
        <div>Pay to</div><div>{asset?.symbol} on {asset?.network}<div className="mono small" style={{ wordBreak: 'break-all' }}>{f.address}</div></div>
        <div>Approval</div><div>{dual ? `Needs a second team member (above ${fmtMoney(threshold, 'NGN')})` : 'Within your limit, reserved immediately'}</div>
        {f.note && <><div>Note</div><div>{f.note}</div></>}
      </div>
      <label className="check"><input type="checkbox" checked={ack} onChange={(e) => setAck(e.target.checked)} /> I checked the address and network. Crypto payouts cannot be reversed once sent.</label>
      <div className="row"><button className="btn" onClick={() => setStep('edit')}>Back</button><div className="spacer" /><button className="btn primary" disabled={!ack || busy} onClick={submit}>{dual ? 'Request approval' : 'Confirm withdrawal'}</button></div>
    </div>}
  </Modal>;
}

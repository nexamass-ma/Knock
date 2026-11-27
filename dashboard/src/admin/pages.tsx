import { useState } from 'react';
import { Card, Drawer, Empty, Field, Gate, Modal, Money, PageHead, Seg, Stat, Status, Table, ago, downloadCsv, fmtDate, human, useAct, useHash, useOp } from '../ui/kit.tsx';
import { sp, type Staff } from './App.tsx';

const Search = ({ value, onChange, ph = 'Search' }: { value: string; onChange: (v: string) => void; ph?: string }) =>
  <input className="input" style={{ maxWidth: 280 }} placeholder={ph} value={value} onChange={(e) => onChange(e.target.value)} aria-label={ph} />;
const Toolbar = ({ children }: { children: any }) => <div className="card-b row wrap" style={{ borderBottom: '1px solid var(--line)' }}>{children}</div>;
const Mono = ({ s }: { s: any }) => <span className="mono small">{s ?? '—'}</span>;
const Holder = ({ h, kind }: { h: string; kind?: string }) => <span>@{h}{kind === 'business' && <span className="badge" style={{ marginLeft: 6 }}>business</span>}</span>;
const amt = (l: any[]) => l?.length ? l.map((x: any) => <div key={x.currency}><Money minor={x.amount} currency={x.currency} /></div>) : <span className="muted">—</span>;
const Json = ({ v }: { v: any }) => <pre className="mono small" style={{ whiteSpace: 'pre-wrap', margin: 0, maxHeight: 220, overflow: 'auto' }}>{JSON.stringify(v, null, 2)}</pre>;

// Sensitive actions are requests: a second staff member approves them.
function RequestAction({ action, subject, label, danger }: { action: string; subject: string; label: string; danger?: boolean }) {
  const { run, busy } = useAct();
  const [open, setOpen] = useState(false);
  const [f, setF] = useState({ reason: '', type: 'case_note', ref: '' });
  return <>
    <button className={'btn ' + (danger ? 'danger' : '')} onClick={() => setOpen(true)}>{label}</button>
    <Modal open={open} onClose={() => setOpen(false)} title={label}>
      <div className="stack">
        <div className="notice">This needs a second staff member to approve before it takes effect. Your request and the decision are audited.</div>
        <Field label="Reason"><textarea className="input" rows={3} value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} /></Field>
        <div className="grid g2">
          <Field label="Evidence type"><select className="input" value={f.type} onChange={(e) => setF({ ...f, type: e.target.value })}>{['case_note', 'risk_alert', 'provider_report', 'law_enforcement', 'customer_report'].map((t) => <option key={t} value={t}>{human(t)}</option>)}</select></Field>
          <Field label="Evidence reference"><input className="input mono" value={f.ref} onChange={(e) => setF({ ...f, ref: e.target.value })} placeholder="e.g. alert id or case number" /></Field>
        </div>
        <div className="row"><div className="spacer" /><button className="btn" onClick={() => setOpen(false)}>Cancel</button>
          <button className={'btn ' + (danger ? 'danger' : 'primary')} disabled={busy || f.reason.trim().length < 5 || !f.ref.trim()} onClick={async () => {
            const r = await run('adm.request_action', { action, subject_id: subject, reason: f.reason.trim(), evidence: [{ type: f.type, ref: f.ref.trim() }], payload: {} }, 'Request created. Waiting for a second approver.');
            if (r) setOpen(false); }}>Request</button></div>
      </div>
    </Modal>
  </>;
}

// ---------------------------------------------------------------- Transactions
export function Transactions() {
  const [f, setF] = useState({ category: '', state: '', currency: '', search: '', provider: '', kind: '' });
  const q = useOp<any[]>('adm.transactions', Object.fromEntries(Object.entries(f).map(([k, v]) => [k, v || null])));
  const [sel, setSel] = useState<any>(null);
  return <>
    <PageHead title="Transactions" sub="Every collection, split share, deposit and withdrawal across personal and business accounts." actions={<button className="btn" disabled={!q.data?.length} onClick={() => downloadCsv('knock-admin-transactions.csv', q.data!)}>Export CSV</button>} />
    <Card pad={false}>
      <Toolbar>
        <Search value={f.search} onChange={(search) => setF({ ...f, search })} ph="Reference, handle or provider ref" />
        <select className="input" style={{ width: 'auto' }} value={f.category} onChange={(e) => setF({ ...f, category: e.target.value })} aria-label="Category"><option value="">All types</option>{['link_payment', 'split_distribution', 'crypto_deposit', 'crypto_withdrawal'].map((c) => <option key={c} value={c}>{human(c)}</option>)}</select>
        <select className="input" style={{ width: 'auto' }} value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value })} aria-label="Account type"><option value="">All accounts</option><option value="person">Personal</option><option value="business">Business</option></select>
        <Seg value={f.state} onChange={(state) => setF({ ...f, state })} options={[['', 'All'], ['succeeded', 'Succeeded'], ['pending', 'Pending'], ['failed', 'Failed'], ['reversed', 'Reversed']]} />
      </Toolbar>
      <Gate q={q} empty={<Empty title="No transactions match" />}>{(rows) => <Table rows={rows} onRow={setSel} cols={[
        { h: 'When', c: (t) => <span className="small">{fmtDate(t.occurred_at)}</span> }, { h: 'Reference', c: (t) => <Mono s={t.reference} /> },
        { h: 'Type', c: (t) => human(t.category) }, { h: 'Holder', c: (t) => <Holder h={t.holder_handle} kind={t.holder_kind} /> },
        { h: 'State', c: (t) => <Status s={t.state} /> }, { h: 'Risk', c: (t) => <Status s={t.risk_status} /> },
        { h: 'Amount', right: true, c: (t) => <Money minor={t.amount} currency={t.currency} /> }, { h: 'Fee', right: true, c: (t) => <Money minor={t.fees} currency={t.currency} /> },
      ]} />}</Gate>
    </Card>
    <Drawer open={!!sel} onClose={() => setSel(null)} title="Transaction">{sel && <div className="kv">
      {Object.entries(sel).map(([k, v]) => <><div key={k + 'k'}>{human(k)}</div><div key={k + 'v'} className="mono small" style={{ wordBreak: 'break-all' }}>{String(v ?? '—')}</div></>)}
    </div>}</Drawer>
  </>;
}

export function Deposits() {
  const [status, setStatus] = useState('');
  const q = useOp<any[]>('adm.deposits', { status: status || null });
  return <>
    <PageHead title="Crypto deposits" sub="Breet deposits as Knock recorded them. Only completed deposits that passed checks are credited." />
    <Card pad={false}>
      <Toolbar><Seg value={status} onChange={setStatus} options={[['', 'All'], ['pending', 'Pending'], ['under_review', 'Under review'], ['flagged', 'Flagged'], ['below_minimum', 'Below minimum'], ['completed', 'Completed'], ['failed', 'Failed']]} /></Toolbar>
      <Gate q={q} empty={<Empty title="No deposits" />}>{(rows) => <Table rows={rows} cols={[
        { h: 'When', c: (d) => <span className="small">{fmtDate(d.created_at)}</span> }, { h: 'Reference', c: (d) => <div><Mono s={d.knock_reference} /><div className="small muted mono">{d.provider_trade_id}</div></div> },
        { h: 'Holder', c: (d) => <Holder h={d.holder} kind={d.holder_kind} /> }, { h: 'Crypto', c: (d) => <span className="num">{d.crypto_amount} {d.symbol} · {d.network}</span> },
        { h: 'USD', right: true, c: (d) => d.amount_in_usd ?? '—' },
        { h: 'Status', c: (d) => <div><Status s={d.status} />{d.flag_reason && <div className="small muted">{d.flag_reason}</div>}{d.is_wrong_asset && <div className="small" style={{ color: 'var(--red)' }}>Wrong asset</div>}</div> },
        { h: 'Credited', right: true, c: (d) => d.credited_minor ? <Money minor={d.credited_minor} currency={d.credited_currency} /> : <span className="muted small">No</span> },
        { h: 'Knock fee', right: true, c: (d) => d.credited_currency ? <Money minor={d.knock_fee_minor} currency={d.credited_currency} /> : '—' },
      ]} />}</Gate>
    </Card>
  </>;
}

export function Withdrawals() {
  const [status, setStatus] = useState('');
  const q = useOp<any[]>('adm.withdrawals', { status: status || null });
  return <>
    <PageHead title="Withdrawals" sub="Payouts reserved in the ledger and submitted to Breet, with who requested and approved each one." />
    <Card pad={false}>
      <Toolbar><Seg value={status} onChange={setStatus} options={[['', 'All'], ['reserved', 'Reserved'], ['submission_unknown', 'Unknown'], ['processing', 'Processing'], ['completed', 'Completed'], ['rejected', 'Rejected'], ['failed', 'Failed']]} /></Toolbar>
      <Gate q={q} empty={<Empty title="No withdrawals" />}>{(rows) => <Table rows={rows} cols={[
        { h: 'When', c: (w) => <span className="small">{fmtDate(w.created_at)}</span> }, { h: 'Reference', c: (w) => <div><Mono s={w.knock_reference} /><div className="small muted mono">{w.provider_withdrawal_id ?? 'not submitted'}</div></div> },
        { h: 'Holder', c: (w) => <Holder h={w.holder} kind={w.holder_kind} /> },
        { h: 'Destination', c: (w) => w.kind === 'crypto' ? <div>{w.asset} · {w.network}<div className="mono small muted">{w.destination_address?.slice(0, 14)}…</div></div> : <div>{w.bank_name}<div className="small muted">{w.account_number_masked}</div></div> },
        { h: 'Status', c: (w) => <div><Status s={w.status} />{w.last_error_code && <div className="small muted">{w.last_error_code}</div>}</div> },
        { h: 'Maker / checker', c: (w) => <span className="small">{w.created_by ? '@' + w.created_by : '—'} / {w.approved_by ? '@' + w.approved_by : '—'}</span> },
        { h: 'Amount', right: true, c: (w) => <Money minor={w.amount_minor} currency={w.currency} /> },
      ]} />}</Gate>
    </Card>
  </>;
}

export function Settlements() {
  const q = useOp<any>('adm.settlements');
  return <>
    <PageHead title="Settlements" sub="Breet's conversion of crypto to Naira and any settlement exceptions." />
    <Gate q={q}>{(s) => <div className="stack">
      <div className="notice">Breet automatic settlement for businesses is {s.provider_settings?.[0]?.business_auto_settlement ? 'on' : 'off'} in Knock's records. It is configured in Breet's own dashboard; Knock only reads it.</div>
      <Card title="Exceptions" pad={false}><Table rows={s.exceptions} cols={[
        { h: 'When', c: (e: any) => <span className="small">{fmtDate(e.created_at)}</span> }, { h: 'Trade', c: (e: any) => <Mono s={e.trade_id} /> }, { h: 'Reason', c: (e: any) => e.reason },
        { h: 'Status', c: (e: any) => <Status s={e.status} /> }, { h: 'Amount', right: true, c: (e: any) => e.amount ? <Money minor={e.amount} currency={e.currency} /> : '—' },
      ]} empty={<div className="card-b muted">No settlement exceptions.</div>} /></Card>
      <Card title="Settlements" pad={false}><Table rows={s.settlements} cols={[
        { h: 'When', c: (e: any) => <span className="small">{fmtDate(e.created_at)}</span> }, { h: 'Trade', c: (e: any) => <Mono s={e.trade_id} /> }, { h: 'Holder', c: (e: any) => '@' + e.holder },
        { h: 'Mode', c: (e: any) => human(e.mode) }, { h: 'Status', c: (e: any) => <Status s={e.status} /> }, { h: 'Rate', right: true, c: (e: any) => e.rate ?? '—' },
        { h: 'Settled', right: true, c: (e: any) => e.amount_settled ? <Money minor={e.amount_settled} currency={e.currency} /> : '—' },
      ]} empty={<div className="card-b muted">No bank settlements yet. Business deposits are credited to the Knock wallet; bank settlement turns on with the auto-settlement flag.</div>} /></Card>
    </div>}</Gate>
  </>;
}

// ---------------------------------------------------------------- Links and Smart Split
export function Links({ staff, split }: { staff: Staff; split: boolean }) {
  const [f, setF] = useState({ status: '', search: '' });
  const q = useOp<any[]>('adm.links', { type: split ? 'split' : null, status: f.status || null, search: f.search || null });
  const { run, busy } = useAct();
  const [rev, setRev] = useState<any>(null); const [note, setNote] = useState('');
  const rows = (q.data ?? []).filter((l) => split || l.link_type !== 'split');
  return <>
    <PageHead title={split ? 'Smart Split' : 'Payment links'} sub={split ? 'Split links, held funds and failed distributions.' : 'Every payment link on Knock.'} />
    <Card pad={false}>
      <Toolbar><Search value={f.search} onChange={(search) => setF({ ...f, search })} ph="Title, reference or creator" />
        <Seg value={f.status} onChange={(status) => setF({ ...f, status })} options={[['', 'All'], ['active', 'Active'], ['paused', 'Paused'], ['under_review', 'Under review'], ['closed', 'Closed']]} /></Toolbar>
      <Gate q={q}>{() => <Table rows={rows} empty={<Empty title="No links" />} cols={[
        { h: 'Link', c: (l) => <div><b>{l.title}</b><div className="small muted mono">{l.reference}</div></div> }, { h: 'Creator', c: (l) => <Holder h={l.creator} kind={l.creator_kind} /> },
        { h: 'Status', c: (l) => <Status s={l.status} /> }, { h: 'Payments', right: true, c: (l) => l.payments },
        ...(split ? [{ h: 'Held / failed', right: true, c: (l: any) => <span className={l.failed_distributions ? '' : 'muted'}>{l.held} / {l.failed_distributions}</span> }] : []),
        { h: 'Collected', right: true, c: (l) => <Money minor={l.collected} currency={l.currency} /> },
        { h: '', right: true, c: (l) => sp(staff, 'links.review') ? (l.status === 'under_review'
          ? <button className="btn sm" disabled={busy} onClick={() => run('adm.link_review', { id: l.id, action: 'clear_review', note: null }, 'Review cleared')}>Clear review</button>
          : l.status !== 'closed' ? <button className="btn sm danger" onClick={() => { setRev(l); setNote(''); }}>Put under review</button> : null) : null },
      ]} />}</Gate>
    </Card>
    <Modal open={!!rev} onClose={() => setRev(null)} title="Put link under review">{rev && <div className="stack">
      <p>Customers can't pay "{rev.title}" while it's under review. Confirmed payments stay held until the review is cleared.</p>
      <Field label="Reason (shown in the audit log)"><textarea className="input" rows={3} value={note} onChange={(e) => setNote(e.target.value)} /></Field>
      <div className="row"><div className="spacer" /><button className="btn" onClick={() => setRev(null)}>Cancel</button><button className="btn danger" disabled={busy || note.trim().length < 5} onClick={async () => { const r = await run('adm.link_review', { id: rev.id, action: 'review', note }, 'Link under review'); if (r) setRev(null); }}>Put under review</button></div>
    </div>}</Modal>
  </>;
}

// ---------------------------------------------------------------- Users and businesses
export function Users({ staff, id }: { staff: Staff; id?: string }) {
  const [, go] = useHash();
  const [s, setS] = useState('');
  const q = useOp<any[]>('adm.users', { search: s || null });
  return <>
    <PageHead title="Users" sub="Personal Knock accounts." />
    <Card pad={false}><Toolbar><Search value={s} onChange={setS} ph="Username or name" /></Toolbar>
      <Gate q={q} empty={<Empty title="No users found" />}>{(rows) => <Table rows={rows} onRow={(u) => go('users/' + u.id)} cols={[
        { h: 'User', c: (u) => <div><b>{u.display_name}</b><div className="small muted">@{u.username}</div></div> }, { h: 'KYC tier', c: (u) => u.kyc_tier },
        { h: 'Status', c: (u) => <Status s={u.status} /> }, { h: 'Open alerts', right: true, c: (u) => u.open_flags }, { h: 'Businesses', right: true, c: (u) => u.businesses },
        { h: 'Balance', right: true, c: (u) => amt(u.balances) }, { h: 'Joined', c: (u) => <span className="small">{fmtDate(u.created_at, false)}</span> },
      ]} />}</Gate></Card>
    <Drawer open={!!id} onClose={() => go('users')} title="User">{id && <UserDetail id={id} staff={staff} />}</Drawer>
  </>;
}
function UserDetail({ id, staff }: { id: string; staff: Staff }) {
  const q = useOp<any>('adm.holder', { id });
  return <Gate q={q} empty={<Empty title="Not found" />}>{(u) => <div className="stack">
    <div className="row"><div><h2>{u.display_name}</h2><div className="muted">@{u.username} · tier {u.kyc_tier}</div></div><div className="spacer" /><Status s={u.status} /></div>
    {sp(staff, 'users.restrict') && <div className="row">{u.status === 'active' ? <RequestAction action="user.restrict" subject={u.id} label="Request restriction" danger /> : <RequestAction action="user.unrestrict" subject={u.id} label="Request unrestriction" />}</div>}
    <Card title="Balances" pad={false}><Table rows={u.balances} cols={[{ h: 'Account', c: (b: any) => human(b.purpose) }, { h: 'Amount', right: true, c: (b: any) => <Money minor={b.amount} currency={b.currency} /> }]} empty={<div className="card-b muted">No balances.</div>} /></Card>
    <Card title="Businesses" pad={false}><Table rows={u.memberships} cols={[{ h: 'Business', c: (m: any) => m.business }, { h: 'Role', c: (m: any) => human(m.role) }, { h: 'Status', c: (m: any) => <Status s={m.status} /> }]} empty={<div className="card-b muted">None.</div>} /></Card>
    <Card title="Risk alerts" pad={false}><Table rows={u.flags} cols={[{ h: 'Rule', c: (f: any) => human(f.rule) }, { h: 'Severity', c: (f: any) => <Status s={f.severity} /> }, { h: 'Case', c: (f: any) => <Status s={f.case_status} /> }]} empty={<div className="card-b muted">None.</div>} /></Card>
    <Card title="Recent transactions" pad={false}><Table rows={u.transactions} cols={[{ h: 'When', c: (t: any) => <span className="small">{fmtDate(t.occurred_at)}</span> }, { h: 'Type', c: (t: any) => human(t.category) }, { h: 'State', c: (t: any) => <Status s={t.state} /> }, { h: 'Amount', right: true, c: (t: any) => <Money minor={t.amount} currency={t.currency} /> }]} empty={<div className="card-b muted">None.</div>} /></Card>
  </div>}</Gate>;
}

export function Businesses({ staff, id }: { staff: Staff; id?: string }) {
  const [, go] = useHash();
  const [f, setF] = useState({ search: '', status: '' });
  const q = useOp<any[]>('adm.businesses', { search: f.search || null, status: f.status || null });
  return <>
    <PageHead title="Businesses" sub="Knock Business accounts. They share the same ledger, risk and audit as personal accounts." />
    <Card pad={false}><Toolbar><Search value={f.search} onChange={(search) => setF({ ...f, search })} ph="Name or handle" />
      <Seg value={f.status} onChange={(status) => setF({ ...f, status })} options={[['', 'All'], ['not_started', 'Not started'], ['pending', 'Pending'], ['under_review', 'Under review'], ['verified', 'Verified'], ['restricted', 'Restricted']]} /></Toolbar>
      <Gate q={q} empty={<Empty title="No businesses" />}>{(rows) => <Table rows={rows} onRow={(b) => go('businesses/' + b.id)} cols={[
        { h: 'Business', c: (b) => <div><b>{b.name}</b><div className="small muted">@{b.handle} · owner @{b.owner}</div></div> }, { h: 'Category', c: (b) => human(b.category) },
        { h: 'Verification', c: (b) => <Status s={b.verification_status} /> }, { h: 'Account', c: (b) => <Status s={b.account_status} /> }, { h: 'Risk', c: (b) => <Status s={b.risk_status} /> },
        { h: 'Links', right: true, c: (b) => b.links }, { h: 'Volume', right: true, c: (b) => amt(b.volume) },
      ]} />}</Gate></Card>
    <Drawer open={!!id} onClose={() => go('businesses')} title="Business">{id && <BusinessDetail id={id} staff={staff} />}</Drawer>
  </>;
}
function BusinessDetail({ id, staff }: { id: string; staff: Staff }) {
  const q = useOp<any>('adm.business', { id });
  return <Gate q={q} empty={<Empty title="Not found" />}>{(b) => <div className="stack">
    <div className="row"><div><h2>{b.trading_name ?? b.legal_name}</h2><div className="muted">{b.legal_name} · @{b.handle} · owner @{b.owner}</div></div><div className="spacer" /><Status s={b.verification_status} /></div>
    {b.pending_action && <div className="notice warn">Pending request: <b>{human(b.pending_action.action)}</b>. {b.pending_action.reason} <a href="#/approvals">Review →</a></div>}
    <div className="row wrap">
      {sp(staff, 'businesses.verify') && ['pending', 'under_review', 'info_required'].includes(b.verification_status) && <ReviewButtons id={b.id} status={b.verification_status} />}
      {sp(staff, 'businesses.restrict') && !b.pending_action && (b.account_status === 'active' && b.verification_status !== 'restricted'
        ? <RequestAction action="business.restrict" subject={b.id} label="Request restriction" danger /> : <RequestAction action="business.unrestrict" subject={b.id} label="Request unrestriction" />)}
    </div>
    <div className="kv small"><div>Category</div><div>{human(b.category)}</div><div>Country</div><div>{b.country}</div><div>Registration</div><div>{b.registration_number ?? '—'}</div>
      <div>Email</div><div>{b.email}</div><div>Phone</div><div>{b.phone ?? '—'}</div><div>Payout second approval above</div><div><Money minor={b.payout_dual_approval_above} currency="NGN" /></div></div>
    <Card title="Documents" pad={false}><Table rows={b.documents} cols={[{ h: 'Type', c: (d: any) => human(d.doc_type) }, { h: 'File', c: (d: any) => <div>{d.file_name}<div className="mono small muted">sha256 {d.sha256?.slice(0, 16)}…</div></div> }, { h: 'Status', c: (d: any) => <Status s={d.status} /> }]} empty={<div className="card-b muted">No documents.</div>} /></Card>
    <Card title="Representatives" pad={false}><Table rows={b.representatives} cols={[{ h: 'Name', c: (r: any) => r.full_name }, { h: 'Role', c: (r: any) => r.role_title }, { h: 'Owns', right: true, c: (r: any) => r.ownership_bps != null ? (r.ownership_bps / 100) + '%' : '—' }]} empty={<div className="card-b muted">None.</div>} /></Card>
    <div className="grid g2">
      <Card title="Balances" pad={false}><Table rows={b.balances} cols={[{ h: 'Account', c: (x: any) => human(x.purpose) }, { h: 'Amount', right: true, c: (x: any) => <Money minor={x.amount} currency={x.currency} /> }]} empty={<div className="card-b muted">None.</div>} /></Card>
      <Card title="Team" pad={false}><Table rows={b.members} cols={[{ h: 'Member', c: (m: any) => '@' + m.username }, { h: 'Role', c: (m: any) => human(m.role) }, { h: 'Status', c: (m: any) => <Status s={m.status} /> }]} /></Card>
    </div>
    <Card title="Risk alerts" pad={false}><Table rows={b.flags} cols={[{ h: 'Rule', c: (f: any) => human(f.rule) }, { h: 'Severity', c: (f: any) => <Status s={f.severity} /> }, { h: 'Case', c: (f: any) => <Status s={f.case_status} /> }]} empty={<div className="card-b muted">None.</div>} /></Card>
    <Card title="Withdrawal requests" pad={false}><Table rows={b.payouts} cols={[{ h: 'When', c: (p: any) => <span className="small">{fmtDate(p.at)}</span> }, { h: 'Reference', c: (p: any) => <Mono s={p.reference} /> }, { h: 'Status', c: (p: any) => <Status s={p.status} /> }, { h: 'Amount', right: true, c: (p: any) => <Money minor={p.amount} currency={p.currency} /> }]} empty={<div className="card-b muted">None.</div>} /></Card>
    <Card title="Verification history" pad={false}><Table rows={b.history} cols={[{ h: 'When', c: (h: any) => <span className="small">{fmtDate(h.at)}</span> }, { h: 'From → to', c: (h: any) => <span>{human(h.from_status ?? '—')} → <Status s={h.to_status} /></span> }, { h: 'Note', c: (h: any) => h.note ?? '' }]} /></Card>
  </div>}</Gate>;
}
function ReviewButtons({ id, status }: { id: string; status: string }) {
  const { run, busy } = useAct();
  const [d, setD] = useState<string | null>(null); const [note, setNote] = useState('');
  const opts: [string, string][] = [...(status === 'pending' ? [['under_review', 'Start review'] as [string, string]] : []), ['info_required', 'Ask for more info'], ['verified', 'Verify'], ['rejected', 'Reject']];
  return <>{opts.map(([k, l]) => <button key={k} className={'btn ' + (k === 'verified' ? 'primary' : k === 'rejected' ? 'danger' : '')} onClick={() => { setD(k); setNote(''); }}>{l}</button>)}
    <Modal open={!!d} onClose={() => setD(null)} title={d ? human(d) : ''}><div className="stack">
      <Field label="Note to the business" hint={d === 'verified' ? 'Optional.' : 'Required. The business sees this.'}><textarea className="input" rows={3} value={note} onChange={(e) => setNote(e.target.value)} /></Field>
      <div className="row"><div className="spacer" /><button className="btn" onClick={() => setD(null)}>Cancel</button>
        <button className="btn primary" disabled={busy || (d !== 'verified' && d !== 'under_review' && note.trim().length < 5)} onClick={async () => { const r = await run('adm.review_business', { id, decision: d, note: note || null }, 'Decision recorded'); if (r) setD(null); }}>Confirm</button></div>
    </div></Modal></>;
}

export function Kyc() {
  const q = useOp<any[]>('adm.kyc_queue');
  const [, go] = useHash();
  return <>
    <PageHead title="Verification queue" sub="Businesses waiting for review, oldest first." />
    <Card pad={false}><Gate q={q} empty={<Empty title="Queue is empty">No business is waiting for review.</Empty>}>{(rows) => <Table rows={rows} onRow={(b) => go('businesses/' + b.id)} cols={[
      { h: 'Business', c: (b) => <div><b>{b.name}</b><div className="small muted">{b.legal_name}</div></div> }, { h: 'Category', c: (b) => <span>{human(b.category)}{b.high_risk_category && <span className="badge bad" style={{ marginLeft: 6 }}>high risk</span>}</span> },
      { h: 'Country', c: (b) => b.country }, { h: 'Status', c: (b) => <Status s={b.verification_status} /> }, { h: 'Documents', right: true, c: (b) => b.documents }, { h: 'People', right: true, c: (b) => b.representatives },
      { h: 'Waiting', c: (b) => b.submitted_at ? ago(b.submitted_at) : '—' },
    ]} />}</Gate></Card>
  </>;
}

export function Support({ staff }: { staff: Staff }) {
  const q = useOp<any[]>('adm.tickets');
  const { run, busy } = useAct();
  const [sel, setSel] = useState<any>(null);
  const [r, setR] = useState({ body: '', internal: false, status: '' });
  const t = sel && q.data?.find((x) => x.id === sel.id);
  return <>
    <PageHead title="Support" sub="Tickets from personal and business accounts." />
    <Card pad={false}><Gate q={q} empty={<Empty title="No tickets" />}>{(rows) => <Table rows={rows} onRow={(x) => { setSel(x); setR({ body: '', internal: false, status: '' }); }} cols={[
      { h: 'Ticket', c: (x) => <div><b>{x.subject}</b><div className="small muted mono">{x.reference}</div></div> }, { h: 'From', c: (x) => '@' + x.holder },
      { h: 'Priority', c: (x) => <Status s={x.priority} /> }, { h: 'Status', c: (x) => <Status s={x.status} /> }, { h: 'Assigned', c: (x) => x.assigned_to ? '@' + x.assigned_to : '—' }, { h: 'Updated', c: (x) => ago(x.updated_at) },
    ]} />}</Gate></Card>
    <Drawer open={!!t} onClose={() => setSel(null)} title={t?.subject ?? ''}>{t && <div className="stack">
      {(t.messages ?? []).map((m: any, i: number) => <div key={i} className="card" style={{ padding: 10, background: m.internal ? 'var(--amber-soft)' : m.author_kind === 'staff' ? 'var(--green-soft)' : undefined }}>
        <div className="small muted">{m.internal ? 'Internal note' : m.author_kind === 'staff' ? 'Knock' : 'Customer'} · {ago(m.at)}</div><div>{m.body}</div></div>)}
      {sp(staff, 'support.manage') ? <div className="stack tight">
        <textarea className="input" rows={3} placeholder="Reply…" value={r.body} onChange={(e) => setR({ ...r, body: e.target.value })} />
        <div className="row wrap"><label className="check small"><input type="checkbox" checked={r.internal} onChange={(e) => setR({ ...r, internal: e.target.checked })} /> Internal note (customer won't see it)</label><div className="spacer" />
          <select className="input" style={{ width: 'auto' }} value={r.status} onChange={(e) => setR({ ...r, status: e.target.value })} aria-label="Set status"><option value="">Keep status</option>{['open', 'pending_customer', 'escalated', 'resolved', 'closed'].map((s) => <option key={s} value={s}>{human(s)}</option>)}</select>
          <button className="btn primary" disabled={busy || (!r.body.trim() && !r.status)} onClick={async () => { const x = await run('adm.ticket_reply', { id: t.id, reply: { body: r.body.trim(), internal: r.internal, status: r.status || null, assign_to_me: true } }, 'Saved'); if (x !== null) setR({ body: '', internal: false, status: '' }); }}>Send</button></div>
      </div> : <div className="small muted">Your role can read tickets but not reply.</div>}
    </div>}</Drawer>
  </>;
}

// ---------------------------------------------------------------- Risk
export function Risk({ staff }: { staff: Staff }) {
  const [f, setF] = useState({ status: '', severity: '' });
  const q = useOp<any[]>('adm.risk', { status: f.status || null, severity: f.severity || null });
  const { run, busy } = useAct();
  const [sel, setSel] = useState<any>(null);
  const [c, setC] = useState({ case_status: '', notes: '' });
  return <>
    <PageHead title="Risk and fraud" sub="Alerts from Knock's rules and from Breet. A high-severity open alert pauses withdrawals for that account."
      actions={sp(staff, 'risk.manage') && <button className="btn" disabled={busy} onClick={() => run<number>('adm.run_risk_rules', {}, 'Risk rules ran')}>Run rules now</button>} />
    <Card pad={false}>
      <Toolbar><Seg value={f.status} onChange={(status) => setF({ ...f, status })} options={[['', 'All'], ['new', 'New'], ['investigating', 'Investigating'], ['escalated', 'Escalated'], ['resolved', 'Resolved'], ['closed', 'Closed']]} />
        <Seg value={f.severity} onChange={(severity) => setF({ ...f, severity })} options={[['', 'Any severity'], ['high', 'High'], ['medium', 'Medium'], ['low', 'Low']]} /></Toolbar>
      <Gate q={q} empty={<Empty title="No alerts" />}>{(rows) => <Table rows={rows} onRow={(x) => { setSel(x); setC({ case_status: x.case_status, notes: x.resolution_notes ?? '' }); }} cols={[
        { h: 'Raised', c: (x) => <span className="small">{fmtDate(x.created_at)}</span> }, { h: 'Rule', c: (x) => <div><b>{human(x.rule)}</b><div className="small muted">{x.reason}</div></div> },
        { h: 'Holder', c: (x) => x.holder ? <Holder h={x.holder} kind={x.holder_kind} /> : '—' }, { h: 'Severity', c: (x) => <Status s={x.severity} /> },
        { h: 'Case', c: (x) => <Status s={x.case_status} /> }, { h: 'Assigned', c: (x) => x.assigned_to ? '@' + x.assigned_to : '—' },
      ]} />}</Gate>
    </Card>
    <Drawer open={!!sel} onClose={() => setSel(null)} title="Risk alert">{sel && <div className="stack">
      <div className="row"><h2>{human(sel.rule)}</h2><div className="spacer" /><Status s={sel.severity} /></div>
      <div>{sel.reason}</div>
      <Card title="Evidence"><Json v={sel.evidence ?? sel.detail} /></Card>
      {sp(staff, 'risk.manage') ? <div className="stack tight">
        <Field label="Case status"><select className="input" value={c.case_status} onChange={(e) => setC({ ...c, case_status: e.target.value })}>{['new', 'investigating', 'info_required', 'escalated', 'resolved', 'closed'].map((s) => <option key={s} value={s}>{human(s)}</option>)}</select></Field>
        <Field label="Notes" hint="Required to resolve or close. Resolving clears the alert and lifts its withdrawal pause."><textarea className="input" rows={3} value={c.notes} onChange={(e) => setC({ ...c, notes: e.target.value })} /></Field>
        <div className="row"><button className="btn" disabled={busy} onClick={() => run('adm.update_risk', { id: sel.id, change: { assigned_to: staff.id } }, 'Assigned to you')}>Assign to me</button><div className="spacer" />
          <button className="btn primary" disabled={busy} onClick={async () => { const r = await run('adm.update_risk', { id: sel.id, change: { case_status: c.case_status, resolution_notes: c.notes || null } }, 'Case updated'); if (r !== null) setSel(null); }}>Save</button></div>
      </div> : <div className="small muted">Your role can view alerts but not change them.</div>}
    </div>}</Drawer>
  </>;
}

export function Lists({ staff }: { staff: Staff }) {
  const q = useOp<any[]>('adm.lists');
  const { run, busy } = useAct();
  const [open, setOpen] = useState(false);
  const [f, setF] = useState({ list: 'watch', subject_kind: 'wallet_address', value: '', reason: '', ref: '' });
  return <>
    <PageHead title="Watch and block lists" sub="Watchlist entries raise alerts. Blocklist entries stop money moving and need a second approver. Allowlist entries suppress one rule's alert, never the checks."
      actions={sp(staff, 'lists.manage') && <button className="btn primary" onClick={() => setOpen(true)}>Add entry</button>} />
    <Card pad={false}><Gate q={q} empty={<Empty title="No entries" />}>{(rows) => <Table rows={rows} cols={[
      { h: 'List', c: (w) => <Status s={w.list === 'black' ? 'blocked' : w.list === 'white' ? 'allowed' : 'watch'} label={w.list === 'black' ? 'Blocklist' : w.list === 'white' ? 'Allowlist' : 'Watchlist'} /> },
      { h: 'Subject', c: (w) => <div>{human(w.subject_kind)}<div className="mono small">{w.value}</div></div> }, { h: 'Reason', c: (w) => w.reason },
      { h: 'Status', c: (w) => <Status s={w.status} /> }, { h: 'By', c: (w) => <span className="small">@{w.requested_by}{w.approved_by && ` · approved @${w.approved_by}`}</span> },
    ]} />}</Gate></Card>
    <Modal open={open} onClose={() => setOpen(false)} title="Add list entry"><div className="stack">
      <div className="grid g2">
        <Field label="List"><select className="input" value={f.list} onChange={(e) => setF({ ...f, list: e.target.value })}><option value="watch">Watchlist</option><option value="black">Blocklist (needs approval)</option><option value="white">Allowlist</option></select></Field>
        <Field label="Subject type"><select className="input" value={f.subject_kind} onChange={(e) => setF({ ...f, subject_kind: e.target.value })}>{['wallet_address', 'email', 'phone', 'bank_account_hash', 'device', 'user', 'business'].map((s) => <option key={s} value={s}>{human(s)}</option>)}</select></Field>
      </div>
      <Field label="Value"><input className="input mono" value={f.value} onChange={(e) => setF({ ...f, value: e.target.value })} /></Field>
      <Field label="Reason"><textarea className="input" rows={2} value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} /></Field>
      <Field label="Evidence reference" hint={f.list === 'black' ? 'Required for the blocklist.' : 'Optional.'}><input className="input mono" value={f.ref} onChange={(e) => setF({ ...f, ref: e.target.value })} /></Field>
      <div className="row"><div className="spacer" /><button className="btn" onClick={() => setOpen(false)}>Cancel</button>
        <button className="btn primary" disabled={busy || !f.value.trim() || f.reason.trim().length < 5 || (f.list === 'black' && !f.ref.trim())} onClick={async () => {
          const r = await run('adm.add_list_entry', { entry: { list: f.list, subject_kind: f.subject_kind, value: f.value.trim(), reason: f.reason.trim(), evidence: f.ref ? [{ type: 'case_note', ref: f.ref.trim() }] : [] } }, f.list === 'black' ? 'Requested. A second approver must confirm it.' : 'Entry added');
          if (r) { setOpen(false); setF({ ...f, value: '', reason: '', ref: '' }); } }}>Add</button></div>
    </div></Modal>
  </>;
}

export function Approvals({ staff }: { staff: Staff }) {
  const q = useOp<any[]>('adm.action_requests');
  const { run, busy } = useAct();
  return <>
    <PageHead title="Approvals" sub="Restrictions and blocklist entries need a second staff member. You can't approve your own request." />
    <Card pad={false}><Gate q={q} empty={<Empty title="Nothing to approve" />}>{(rows) => <Table rows={rows} cols={[
      { h: 'Requested', c: (r) => <div><div className="small">{fmtDate(r.created_at)}</div><div className="small muted">by @{r.requested_by}</div></div> },
      { h: 'Action', c: (r) => <b>{human(r.action)}</b> }, { h: 'Subject', c: (r) => r.subject }, { h: 'Reason', c: (r) => <div>{r.reason}<div className="small muted mono">{(r.evidence ?? []).map((e: any) => `${e.type}: ${e.ref}`).join(' · ')}</div></div> },
      { h: 'Status', c: (r) => <div><Status s={r.status} />{r.decided_by && <div className="small muted">by @{r.decided_by}</div>}</div> },
      { h: '', right: true, c: (r) => r.status !== 'pending' ? null : r.mine ? <span className="small muted">Your request</span> : <div className="row" style={{ justifyContent: 'flex-end' }}>
        <button className="btn sm primary" disabled={busy} onClick={() => run('adm.decide_action', { id: r.id, approve: true, note: null }, 'Approved and applied')}>Approve</button>
        <button className="btn sm" disabled={busy} onClick={() => run('adm.decide_action', { id: r.id, approve: false, note: 'Rejected in admin' }, 'Rejected')}>Reject</button></div> },
    ]} />}</Gate></Card>
    {!sp(staff, 'businesses.restrict') && !sp(staff, 'lists.approve') && <div className="small muted" style={{ marginTop: 8 }}>Your role can see requests; approving needs the matching permission.</div>}
  </>;
}

// ---------------------------------------------------------------- Operations (read-only over Knock's records)
export function Breet() {
  const q = useOp<any>('adm.providers');
  return <>
    <PageHead title="Breet monitoring" sub="Read-only view of Knock's own records about Breet. Breet's settings, wallets and payouts are managed in Breet's dashboard, not here." />
    <Gate q={q}>{(p) => <div className="stack">
      <div className="grid g4">
        <Stat label="Pending deposits" value={p.pending_deposits} /><Stat label="Pending withdrawals" value={p.pending_withdrawals} />
        <Stat label="Unreconciled items" value={p.unreconciled} tone={p.unreconciled ? 'warn' : undefined} /><Stat label="Settlement exceptions" value={p.failed_settlements} tone={p.failed_settlements ? 'bad' : undefined} />
      </div>
      <Card title="Connection" pad={false}><Table rows={p.accounts} cols={[
        { h: 'Provider', c: (a: any) => <b>{human(a.provider)}</b> }, { h: 'Environment', c: (a: any) => <Status s={a.environment} /> }, { h: 'Status', c: (a: any) => <Status s={a.status} /> },
        { h: 'Last health check', c: (a: any) => a.last_health_at ? <span>{a.last_health_ok ? '✓' : '✕'} {ago(a.last_health_at)}</span> : 'Never' },
        { h: 'Last webhook', c: (a: any) => a.webhook_last_received_at ? ago(a.webhook_last_received_at) : 'Never' },
      ]} /></Card>
      <div className="notice warn">No Breet credentials are configured. The values above come from sandbox records; no live Breet call has been made.</div>
      <Card title="API calls (24 hours)" pad={false}><Table rows={p.api} cols={[{ h: 'Route', c: (a: any) => <Mono s={a.route} /> }, { h: 'Requests', right: true, c: (a: any) => a.requests }, { h: 'Failed', right: true, c: (a: any) => a.failed }, { h: 'Last', c: (a: any) => ago(a.last_at) }]}
        empty={<div className="card-b muted">No API calls recorded. The sandbox never calls Breet.</div>} /></Card>
      <Card title="Knock's ledger view of the Breet wallet" pad={false}><Table rows={p.wallet_ledger} cols={[{ h: 'Account', c: (w: any) => <Mono s={w.code} /> }, { h: 'Balance', right: true, c: (w: any) => <Money minor={w.balance} currency={w.currency} /> }]} empty={<div className="card-b muted">No movements.</div>} /></Card>
    </div>}</Gate>
  </>;
}

export function Webhooks() {
  const q = useOp<any>('adm.providers');
  const [sel, setSel] = useState<any>(null);
  return <>
    <PageHead title="Webhooks" sub="Every provider event is stored before processing, verified, de-duplicated and applied once." />
    <Gate q={q}>{(p) => <div className="stack">
      <div className="row wrap">{p.webhooks.map((w: any) => <span key={w.status} className="small"><Status s={w.status} label={`${human(w.status)}: ${w.n}`} /></span>)}<span className="small muted">Last processed {p.last_webhook ? ago(p.last_webhook) : 'never'}</span></div>
      <Card pad={false}><Table rows={p.recent_webhooks} onRow={setSel} cols={[
        { h: 'Received', c: (w: any) => <span className="small">{fmtDate(w.received_at)}</span> }, { h: 'Event', c: (w: any) => <Mono s={w.event_type} /> }, { h: 'Event id', c: (w: any) => <Mono s={w.event_id?.slice(0, 22)} /> },
        { h: 'Status', c: (w: any) => <Status s={w.status} /> }, { h: 'Attempts', right: true, c: (w: any) => w.attempts }, { h: 'Deliveries', right: true, c: (w: any) => w.delivery_count }, { h: 'Error', c: (w: any) => w.last_error ?? '' },
      ]} empty={<div className="card-b muted">No webhooks yet.</div>} /></Card>
    </div>}</Gate>
    <Drawer open={!!sel} onClose={() => setSel(null)} title="Webhook event">{sel && <Json v={sel} />}</Drawer>
  </>;
}

export function Reconciliation() {
  const q = useOp<any>('adm.providers');
  return <>
    <PageHead title="Reconciliation" sub="Knock compares its records with Breet's on a schedule. Differences are listed, never auto-corrected." />
    <Gate q={q}>{(p) => <div className="stack">
      <Card title="Mismatches" pad={false}><Table rows={p.reconciliation} cols={[
        { h: 'Found', c: (r: any) => <span className="small">{fmtDate(r.created_at)}</span> }, { h: 'Check', c: (r: any) => human(r.check_name) }, { h: 'Subject', c: (r: any) => <div>{human(r.subject_kind)}<div className="mono small">{r.subject_ref}</div></div> },
        { h: 'Knock', c: (r: any) => <Json v={r.expected} /> }, { h: 'Breet', c: (r: any) => <Json v={r.actual} /> }, { h: 'Status', c: (r: any) => <Status s={r.status} /> },
      ]} empty={<div className="card-b muted">Everything matches.</div>} /></Card>
      <Card title="Recent runs" pad={false}><Table rows={p.runs} cols={[{ h: 'Started', c: (r: any) => <span className="small">{fmtDate(r.started_at)}</span> }, { h: 'Scope', c: (r: any) => human(r.scope) }, { h: 'Trigger', c: (r: any) => human(r.trigger) }, { h: 'Status', c: (r: any) => <Status s={r.status} /> }, { h: 'Differences', right: true, c: (r: any) => r.discrepancies }]} empty={<div className="card-b muted">No runs yet.</div>} /></Card>
    </div>}</Gate>
  </>;
}

export function Health() {
  const q = useOp<any>('adm.health');
  return <>
    <PageHead title="System health" sub="Ledger integrity and background work." />
    <Gate q={q}>{(h) => <div className="stack">
      <div className="grid g4">
        <Stat label="Unbalanced ledger entries" value={h.unbalanced_entries} tone={h.unbalanced_entries ? 'bad' : 'good'} sub="Must always be 0" />
        <Stat label="Negative liability balances" value={h.negative_liabilities} tone={h.negative_liabilities ? 'bad' : 'good'} sub="Must always be 0" />
        <Stat label="Webhooks queued / failed" value={`${h.webhook_queue} / ${h.webhook_failed}`} tone={h.webhook_failed ? 'warn' : undefined} sub={h.oldest_queued ? 'oldest ' + ago(h.oldest_queued) : undefined} />
        <Stat label="Withdrawals with unknown result" value={h.submission_unknown} tone={h.submission_unknown ? 'warn' : undefined} sub="Checked with Breet before any retry" />
      </div>
      <div className="grid g4"><Stat label="Split distributions retrying" value={h.distribution_retrying} /><Stat label="Database time" value={<span style={{ fontSize: 14 }}>{fmtDate(h.db_time)}</span>} /></div>
      <Card title="Provider rate limits" pad={false}><Table rows={h.rate_limits} cols={[{ h: 'Limit', c: (r: any) => <Json v={r} /> }]} empty={<div className="card-b muted">No rate limit state recorded.</div>} /></Card>
    </div>}</Gate>
  </>;
}

export function Alerts({ staff }: { staff: Staff }) {
  const q = useOp<any[]>('adm.alerts');
  const { run, busy } = useAct();
  return <>
    <PageHead title="Alerts" sub="Raised automatically for settlement failures, reconciliation mismatches, webhook failures, high-risk alerts and new verifications." />
    <Card pad={false}><Gate q={q} empty={<Empty title="No alerts" />}>{(rows) => <Table rows={rows} cols={[
      { h: 'When', c: (a) => <span className="small">{fmtDate(a.created_at)}</span> }, { h: 'Severity', c: (a) => <Status s={a.severity} /> },
      { h: 'Alert', c: (a) => <div><b>{a.title}</b><div className="small muted">{a.body}</div></div> },
      { h: '', right: true, c: (a) => a.acknowledged_at ? <span className="small muted">Acknowledged by @{a.acknowledged_by}</span> : sp(staff, 'notifications.view') ? <button className="btn sm" disabled={busy} onClick={() => run('adm.ack_alert', { id: a.id }, 'Acknowledged')}>Acknowledge</button> : null },
    ]} />}</Gate></Card>
  </>;
}

// ---------------------------------------------------------------- Control
export function Audit() {
  const [f, setF] = useState({ search: '', kind: '' });
  const q = useOp<any[]>('adm.audit', { search: f.search || null, kind: f.kind || null });
  return <>
    <PageHead title="Audit log" sub="Append-only record of every user, staff and system action." actions={<button className="btn" disabled={!q.data?.length} onClick={() => downloadCsv('knock-audit.csv', q.data!)}>Export CSV</button>} />
    <Card pad={false}><Toolbar><Search value={f.search} onChange={(search) => setF({ ...f, search })} ph="Action, actor or business" />
      <Seg value={f.kind} onChange={(kind) => setF({ ...f, kind })} options={[['', 'All'], ['user', 'Users'], ['staff', 'Staff'], ['system', 'System'], ['provider', 'Provider']]} /></Toolbar>
      <Gate q={q} empty={<Empty title="No entries" />}>{(rows) => <Table rows={rows} cols={[
        { h: 'When', c: (a) => <span className="small">{fmtDate(a.at)}</span> }, { h: 'Actor', c: (a) => <span>{human(a.actor_kind)}{a.actor && ` @${a.actor}`}</span> },
        { h: 'Action', c: (a) => <Mono s={a.action} /> }, { h: 'Business', c: (a) => a.business ? '@' + a.business : '' },
        { h: 'Detail', c: (a) => <span className="mono small muted">{JSON.stringify(a.detail).slice(0, 140)}</span> },
      ]} />}</Gate></Card>
  </>;
}

export function StaffPage() {
  const s = useOp<any[]>('adm.staff');
  const r = useOp<any[]>('adm.role_permissions');
  return <>
    <PageHead title="Staff and roles" sub="Staff are personal Knock accounts with a staff role. Admin requires two-factor sign-in." />
    <Card title="Staff" pad={false}><Gate q={s}>{(rows) => <Table rows={rows} cols={[{ h: 'Name', c: (x) => <div><b>{x.display_name}</b><div className="small muted">@{x.username}</div></div> }, { h: 'Roles', c: (x) => x.roles.map(human).join(', ') }, { h: 'Status', c: (x) => <Status s={x.status} /> }, { h: 'Since', c: (x) => <span className="small">{fmtDate(x.since, false)}</span> }]} />}</Gate></Card>
    <Card title="Role permissions" pad={false}><Gate q={r}>{(rows) => <Table rows={rows} cols={[{ h: 'Role', c: (x) => <b>{human(x.role)}</b> }, { h: 'Permissions', c: (x) => <span className="small">{x.permissions.join(' · ')}</span> }]} />}</Gate></Card>
    <div className="small muted">Granting staff roles is done by a super admin through a reviewed database change, not from this screen.</div>
  </>;
}

export function SettingsPage({ staff }: { staff: Staff }) {
  const f = useOp<any[]>('adm.flags');
  const t = useOp<any>('adm.thresholds');
  const { run, busy } = useAct();
  const [confirm, setConfirm] = useState<any>(null);
  return <>
    <PageHead title="Flags and limits" sub="Features stay off until their provider approval and credentials exist." />
    <Card title="Feature flags" pad={false}><Gate q={f}>{(rows) => <Table rows={rows} cols={[
      { h: 'Feature', c: (x) => <div><b>{x.label}</b><div className="mono small muted">{x.key}</div></div> }, { h: 'Needs', c: (x) => <span className="small">{x.depends_on}</span> },
      { h: 'State', c: (x) => <div><Status s={x.enabled ? 'enabled' : 'disabled'} />{x.updated_by && <div className="small muted">@{x.updated_by} · {ago(x.updated_at)}</div>}</div> },
      { h: '', right: true, c: (x) => sp(staff, 'settings.manage') ? <button className={'btn sm ' + (x.enabled ? '' : 'primary')} onClick={() => setConfirm(x)}>{x.enabled ? 'Turn off' : 'Turn on'}</button> : null },
    ]} />}</Gate></Card>
    <Gate q={t}>{(x) => <div className="grid g2">
      <Card title="Knock fees" pad={false}><Table rows={x.fees ?? []} cols={[{ h: 'Currency', c: (r: any) => r.currency }, { h: 'Rate', right: true, c: (r: any) => (r.bps / 100).toFixed(2) + '%' }, { h: 'Min', right: true, c: (r: any) => <Money minor={r.min_fee} currency={r.currency} /> }, { h: 'Cap', right: true, c: (r: any) => r.cap_fee != null ? <Money minor={r.cap_fee} currency={r.currency} /> : 'None' }]} /></Card>
      <Card title="Verification tier limits (NGN)" pad={false}><Table rows={x.tiers ?? []} cols={[{ h: 'Tier', c: (r: any) => r.kyc_tier }, { h: 'Per payment', right: true, c: (r: any) => <Money minor={r.max_single_payment} currency="NGN" /> }, { h: 'Link target', right: true, c: (r: any) => <Money minor={r.max_link_target} currency="NGN" /> }, { h: 'Recipients', right: true, c: (r: any) => r.max_recipients }]} /></Card>
      <Card title="Business settings"><div className="kv small">{Object.entries(x.business ?? {}).map(([k, v]) => <><div key={k}>{human(k)}</div><div key={k + 'v'} className="mono">{JSON.stringify(v)}</div></>)}</div></Card>
      <Card title="Approval thresholds" pad={false}><Table rows={x.approvals ?? []} cols={[{ h: 'Rule', c: (r: any) => <Json v={r} /> }]} empty={<div className="card-b muted">None.</div>} /></Card>
    </div>}</Gate>
    <Modal open={!!confirm} onClose={() => setConfirm(null)} title={confirm ? `${confirm.enabled ? 'Turn off' : 'Turn on'} ${confirm.label}?` : ''}>{confirm && <div className="stack">
      {!confirm.enabled && <div className="notice warn">Only turn this on once this is true: <b>{confirm.depends_on}</b>. Turning it on without that will make real customer actions fail.</div>}
      <div className="row"><div className="spacer" /><button className="btn" onClick={() => setConfirm(null)}>Cancel</button>
        <button className="btn primary" disabled={busy} onClick={async () => { const r = await run('adm.set_flag', { key: confirm.key, enabled: !confirm.enabled }, 'Flag updated'); if (r !== null) setConfirm(null); }}>Confirm</button></div>
    </div>}</Modal>
  </>;
}

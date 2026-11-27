import { useState } from 'react';
import { Card, ErrorBox, Gate, Loading, Money, PageHead, RangePicker, Stat, Status, Table, human, useApp, useHash, useOp, useRange } from '../ui/kit.tsx';
import * as P from './pages.tsx';

export interface Staff { id: string; username: string; display_name: string; roles: string[]; permissions: string[]; aal: string }
export const sp = (s: Staff | null, p: string) => !!s?.permissions?.includes(p);

// [route, label, required permission, group]
const NAV: [string, string, string, string][] = [
  ['', 'Overview', 'overview.view', 'Money'], ['earnings', 'Earnings', 'earnings.view', 'Money'], ['transactions', 'Transactions', 'transactions.view', 'Money'],
  ['deposits', 'Crypto deposits', 'transactions.view', 'Money'], ['withdrawals', 'Withdrawals', 'transactions.view', 'Money'], ['settlements', 'Settlements', 'transactions.view', 'Money'],
  ['links', 'Payment links', 'links.view', 'Money'], ['splits', 'Smart Split', 'links.view', 'Money'],
  ['users', 'Users', 'users.view', 'Customers'], ['businesses', 'Businesses', 'businesses.view', 'Customers'], ['kyc', 'Verification queue', 'kyc.view', 'Customers'], ['support', 'Support', 'support.view', 'Customers'],
  ['risk', 'Risk and fraud', 'risk.view', 'Risk'], ['lists', 'Watch and block lists', 'risk.view', 'Risk'], ['approvals', 'Approvals', 'overview.view', 'Risk'],
  ['breet', 'Breet monitoring', 'providers.view', 'Operations'], ['webhooks', 'Webhooks', 'providers.view', 'Operations'], ['reconciliation', 'Reconciliation', 'providers.view', 'Operations'],
  ['health', 'System health', 'providers.view', 'Operations'], ['alerts', 'Alerts', 'notifications.view', 'Operations'],
  ['audit', 'Audit log', 'audit.view', 'Control'], ['staff', 'Staff and roles', 'overview.view', 'Control'], ['settings', 'Flags and limits', 'overview.view', 'Control'],
];
const STAFF = ['root', 'amaka', 'bola', 'dayo', 'ese'];

export function AdminApp() {
  const [parts] = useHash();
  const { sb, session, setSession } = useApp();
  const me = useOp<Staff>('adm.me');
  const page = parts[0] ?? '';
  const staff = me.data;
  const nav = NAV.filter((n) => sp(staff ?? null, n[2]));
  const groups = Array.from(new Set(nav.map((n) => n[3])));
  const [menu, setMenu] = useState(false);
  const entry = NAV.find((n) => n[0] === page);

  let body;
  if (me.error) body = <div className="stack"><ErrorBox error={me.error} />{me.error.code === 'mfa_required' && <div className="notice warn">Knock Admin requires two-factor sign-in. Turn on "MFA verified" above (production: Supabase Auth MFA, aal2).</div>}</div>;
  else if (!staff) body = <Loading />;
  else if (entry && !sp(staff, entry[2])) body = <div className="empty"><b>No access</b><div className="muted">Your role ({staff.roles?.join(', ')}) doesn't include {entry[2]}.</div></div>;
  else body = <Page page={page} id={parts[1]} staff={staff} />;

  return <div className="shell admin">
    <aside className={'side' + (menu ? ' open' : '')} onClick={() => setMenu(false)}>
      <div className="brand"><div className="mark" style={{ background: 'var(--ink)' }}>K</div><div>Knock Admin<small>Internal operations</small></div></div>
      <nav className="nav">{groups.map((g) => <div key={g}><div className="nav-group">{g}</div>
        {nav.filter((n) => n[3] === g).map(([k, l]) => <a key={k} href={'#/' + k} className={page === k ? 'on' : ''}>{l}</a>)}</div>)}</nav>
      <div className="spacer" />
      <div className="small muted" style={{ padding: 10 }}>Customer-facing app: <a href="./index.html">Knock Business</a></div>
    </aside>
    <div className="main">
      <div className="sandbox"><b>SANDBOX</b> Staff view of sandbox records. Every action runs the real permission checks and is written to the audit log.
        <span className="spacer" />Staff
        <select className="input" style={{ width: 'auto', padding: '3px 8px' }} value={session.userId} onChange={(e) => setSession({ ...session, userId: e.target.value })} aria-label="Sandbox staff member">
          {STAFF.map((u) => sb.people[u]).filter(Boolean).map((p) => <option key={p.id} value={p.id}>@{p.username} · {p.note}</option>)}</select>
        <label className="check"><input type="checkbox" checked={session.context === 'aal2'} onChange={(e) => setSession({ ...session, context: e.target.checked ? 'aal2' : 'aal1' })} /> MFA verified</label>
      </div>
      <header className="top">
        <button className="btn ghost menu-btn" onClick={() => setMenu(true)} aria-label="Menu">☰</button>
        <b>{entry?.[1] ?? 'Knock Admin'}</b><div className="spacer" />
        {staff && <span className="small muted">{staff.display_name} · {staff.roles?.map(human).join(', ')}</span>}
      </header>
      <div className="content">{body}</div>
    </div>
  </div>;
}

function Page({ page, id, staff }: { page: string; id?: string; staff: Staff }) {
  switch (page) {
    case '': return <Overview />;
    case 'earnings': return <Earnings />;
    case 'transactions': return <P.Transactions />;
    case 'deposits': return <P.Deposits />;
    case 'withdrawals': return <P.Withdrawals />;
    case 'settlements': return <P.Settlements />;
    case 'links': return <P.Links staff={staff} split={false} />;
    case 'splits': return <P.Links staff={staff} split />;
    case 'users': return <P.Users staff={staff} id={id} />;
    case 'businesses': return <P.Businesses staff={staff} id={id} />;
    case 'kyc': return <P.Kyc />;
    case 'support': return <P.Support staff={staff} />;
    case 'risk': return <P.Risk staff={staff} />;
    case 'lists': return <P.Lists staff={staff} />;
    case 'approvals': return <P.Approvals staff={staff} />;
    case 'breet': return <P.Breet />;
    case 'webhooks': return <P.Webhooks />;
    case 'reconciliation': return <P.Reconciliation />;
    case 'health': return <P.Health />;
    case 'alerts': return <P.Alerts staff={staff} />;
    case 'audit': return <P.Audit />;
    case 'staff': return <P.StaffPage />;
    case 'settings': return <P.SettingsPage staff={staff} />;
    default: return <div className="empty">Page not found</div>;
  }
}

const sumList = (l: any[] | undefined) => l?.length ? <div className="stack tight">{l.map((x) => <div key={x.currency}><Money minor={x.amount} currency={x.currency} /></div>)}</div> : <span className="muted">—</span>;

function Overview() {
  const { from, to, r: range, setR: setRange } = useRange('30d');
  const q = useOp<any>('adm.overview', { from, to });
  return <>
    <PageHead title="Overview" sub="Platform activity for the selected period." actions={<RangePicker value={range} onChange={setRange} />} />
    <Gate q={q}>{(o) => <div className="stack">
      <div className="grid g4">
        <Stat label="Successful volume" value={sumList(o.volume)} sub={`${o.counts.succeeded} successful transactions`} />
        <Stat label="Knock revenue" value={sumList(o.knock_revenue)} sub="Knock fees in the ledger only" tone="good" />
        <Stat label="Split distributions" value={sumList(o.split_distributions)} />
        <Stat label="Provider fees" value={sumList(o.provider_fees)} sub="Charged by providers" />
      </div>
      <div className="grid g4">
        <Stat label="Users" value={o.users} /><Stat label="Businesses" value={o.businesses} sub={`${o.verified_businesses} verified · ${o.active_businesses} active in period`} />
        <Stat label="Payment links" value={o.payment_links} /><Stat label="Transactions" value={o.counts.succeeded + o.counts.pending + o.counts.failed} sub={`${o.counts.pending} pending · ${o.counts.failed} failed`} />
      </div>
      <Card title="Needs attention"><div className="grid g4">
        <a href="#/kyc" className="card stat linkcard"><div className="label">Verifications waiting</div><div className="value">{o.pending_verifications}</div></a>
        <a href="#/risk" className="card stat linkcard"><div className="label">Open risk alerts</div><div className="value" style={{ color: o.open_risk_alerts ? 'var(--red)' : undefined }}>{o.open_risk_alerts}</div></a>
        <a href="#/settlements" className="card stat linkcard"><div className="label">Settlements pending / failed</div><div className="value">{o.pending_settlements} / {o.failed_settlements}</div></a>
        <a href="#/alerts" className="card stat linkcard"><div className="label">Unacknowledged alerts</div><div className="value">{o.open_alerts}</div></a>
      </div></Card>
    </div>}</Gate>
  </>;
}

const BUCKET: Record<string, [string, string]> = {
  customer_funds: ['Customer funds', 'Owed to personal users. Not revenue.'],
  business_funds: ['Business funds', 'Owed to businesses. Not revenue.'],
  awaiting_distribution: ['Awaiting distribution', 'Collected on links, not yet released.'],
  provider_held: ['Held at providers', 'Breet wallet and clearing.'],
  knock_bank: ['Knock settlement bank', 'Cash in the settlement account.'],
  knock_revenue_total: ['Knock revenue (all time)', 'Knock fees earned.'],
  provider_costs_total: ['Provider costs (all time)', 'Fees providers charged Knock.'],
  recoveries_owed: ['Recoveries owed', 'Money to recover from holders.'],
};
function Earnings() {
  const { from, to, r: range, setR: setRange } = useRange('30d');
  const q = useOp<any>('adm.earnings', { from, to });
  const abs = (s: string) => (s.startsWith('-') ? s.slice(1) : s);
  return <>
    <PageHead title="Earnings" sub="Knock's own money, kept apart from the money Knock holds for customers." actions={<RangePicker value={range} onChange={setRange} />} />
    <Gate q={q}>{(e) => {
      const byKind = (k: string) => e.period.filter((p: any) => p.kind === k);
      const curs: string[] = Array.from(new Set(e.period.map((p: any) => p.currency)));
      return <div className="stack">
        <div className="grid g3">
          <Stat label="Knock revenue (period)" value={sumList(byKind('knock_revenue'))} tone="good" />
          <Stat label="Provider costs (period)" value={sumList(byKind('provider_costs'))} />
          <Stat label="Net before operating expenses" value={curs.length ? <div className="stack tight">{curs.map((c) => { const r = BigInt(byKind('knock_revenue').find((x: any) => x.currency === c)?.amount ?? 0); const k = BigInt(byKind('provider_costs').find((x: any) => x.currency === c)?.amount ?? 0); return <div key={c}><Money minor={r - k} currency={c} /></div>; })}</div> : '—'}
            sub={e.operating_expenses === null ? 'Operating expenses are not in the ledger' : undefined} />
        </div>
        <Card title="Where the money is (now)" pad={false}><Table rows={e.positions} cols={[
          { h: 'Position', c: (p: any) => <div><b>{BUCKET[p.bucket]?.[0] ?? human(p.bucket)}</b><div className="small muted">{BUCKET[p.bucket]?.[1]}</div></div> },
          { h: 'Currency', c: (p: any) => p.currency }, { h: 'Amount', right: true, c: (p: any) => <Money minor={abs(p.amount)} currency={p.currency} /> },
        ]} /></Card>
        <Card title="Revenue by fee type (period)" pad={false}><Table rows={e.fee_breakdown} cols={[
          { h: 'Fee', c: (f: any) => human(f.fee_type) }, { h: 'Source', c: (f: any) => human(f.source) }, { h: 'Amount', right: true, c: (f: any) => <Money minor={f.amount} currency={f.currency} /> },
        ]} empty={<div className="card-b muted">No fees in this period.</div>} /></Card>
        {e.reversals?.length > 0 && <Card title="Reversals" pad={false}><Table rows={e.reversals} cols={[{ h: 'Currency', c: (r: any) => r.currency }, { h: 'Amount', right: true, c: (r: any) => <Money minor={r.amount} currency={r.currency} /> }]} /></Card>}
        <div className="notice">{e.notes.map((n: string, i: number) => <div key={i}>{n}</div>)}</div>
      </div>;
    }}</Gate>
  </>;
}

import { useState } from 'react';
import { Card, DailyBars, Drawer, Empty, Gate, Money, PageHead, RangePicker, Stat, Status, Table, downloadCsv, fmtDate, fmtMoney, human, useOp, useRange } from '../ui/kit.tsx';
import { can, type Biz } from './App.tsx';

const CAT: Record<string, string> = {
  payment_link_collection: 'Payment link', split_distribution: 'Smart Split share', crypto_deposit: 'Crypto deposit',
  crypto_withdrawal: 'Crypto withdrawal', bank_payout: 'Bank payout',
};
export const catLabel = (c: string) => CAT[c] ?? human(c);

export function Overview({ biz }: { biz: Biz }) {
  const { r, setR, from, to } = useRange('30d');
  const q = useOp<any>('biz.overview', { from, to });
  const [cur, setCur] = useState<string | null>(null);
  return <>
    <PageHead title="Overview" sub="Money collected, money sent and what needs attention." actions={<RangePicker value={r} onChange={setR} />} />
    <Gate q={q}>{(o) => {
      const currencies: string[] = Array.from(new Set([...o.balances.map((b: any) => b.currency), ...o.totals.map((t: any) => t.currency)]));
      const c = cur && currencies.includes(cur) ? cur : currencies.includes('NGN') ? 'NGN' : currencies[0];
      const bal = o.balances.find((b: any) => b.currency === c) ?? { available: '0', pending: '0', reserved: '0' };
      const tot = o.totals.find((t: any) => t.currency === c) ?? { collected: '0', paid_out: '0', fees: '0', payments: 0, successful: 0, average: '0', success_rate: null };
      if (!currencies.length) return <Card><Empty title="Welcome to Knock Business" action={can(biz, 'links.create') ? <a className="btn primary" href="#/links">Create your first payment link</a> : undefined}>
        Create a payment link or a crypto deposit address to start collecting money. Everything you receive shows up here.</Empty></Card>;
      return <div className="stack">
        <div className="row wrap"><span className="muted small">Currency</span>{currencies.map((x) => <button key={x} className={'btn sm' + (x === c ? ' primary' : '')} onClick={() => setCur(x)}>{x}</button>)}</div>
        <div className="grid g4">
          <div className="card stat" style={{ gridColumn: 'span 2' }}>
            <div className="label">Available balance · {c}</div>
            <div className="hero" style={{ marginTop: 6 }}><Money minor={bal.available} currency={c} /></div>
            <div className="row wrap small muted" style={{ marginTop: 8, gap: 16 }}>
              <span>Pending <b className="num"><Money minor={bal.pending} currency={c} /></b></span>
              <span>Reserved for payouts <b className="num"><Money minor={bal.reserved} currency={c} /></b></span>
            </div>
          </div>
          <Stat label="Money collected" value={<Money minor={tot.collected} currency={c} compact />} sub={`${tot.successful} successful payments`} />
          <Stat label="Money sent" value={<Money minor={tot.paid_out} currency={c} compact />} sub="Completed payouts" />
        </div>
        <div className="grid g4">
          <Stat label="Payment success rate" value={tot.success_rate === null ? '—' : tot.success_rate + '%'} sub={`${tot.payments} completed attempts`} />
          <Stat label="Average payment" value={<Money minor={tot.average} currency={c} compact />} />
          <Stat label="Fees paid to Knock" value={<Money minor={tot.fees} currency={c} compact />} sub="Knock service fees only" />
          <Stat label="Customers" value={o.counts.customers} sub="Paid at least once" />
        </div>
        <div className="grid g3">
          <Stat label="Successful" value={o.counts.succeeded} tone="good" />
          <Stat label="Pending" value={o.counts.pending} tone={o.counts.pending ? 'warn' : undefined} sub="Deposits confirming or under review, payouts in flight" />
          <Stat label="Failed" value={o.counts.failed} tone={o.counts.failed ? 'bad' : undefined} />
        </div>
        <Card title={`Money collected per day · ${c}`}><DailyBars series={o.series.filter((s: any) => s.currency === c)} currency={c} from={from} to={to} /></Card>
        <div className="grid g2">
          <Card title="Recent activity" actions={<a href="#/transactions" className="small">View all</a>} pad={false}>
            <Table rows={o.recent} cols={[
              { h: 'Activity', c: (t: any) => <div><div>{catLabel(t.category)}</div><div className="small muted">{t.counterparty}</div></div> },
              { h: 'Status', c: (t: any) => <Status s={t.state} /> },
              { h: 'Amount', right: true, c: (t: any) => <span style={{ color: t.direction === 'out' ? 'var(--ink)' : 'var(--green-strong)' }}>{t.direction === 'out' ? '−' : '+'}<Money minor={t.amount} currency={t.currency} /></span> },
            ]} empty={<Empty title="No activity yet" />} />
          </Card>
          <div className="stack">
            <Card title="Needs attention">
              <div className="stack tight">
                <Attn n={o.pending_payouts} label="payouts waiting for approval" href="#/withdrawals" />
                <Attn n={o.settlements.failed} label="bank settlements that failed to start" href="#/crypto" />
                <Attn n={o.settlements.awaiting} label="bank settlements in progress" href="#/crypto" />
                <Attn n={o.risk_alerts} label="account reviews open with Knock" href="#/settings/support" />
                {!o.pending_payouts && !o.settlements.failed && !o.settlements.awaiting && !o.risk_alerts && <div className="muted">Nothing needs your attention.</div>}
              </div>
            </Card>
            <Card title="Top payment links" actions={<a href="#/links" className="small">All links</a>} pad={false}>
              <Table rows={o.top_links} cols={[
                { h: 'Link', c: (l: any) => <a href={`#/${l.type === 'split' ? 'split' : 'links'}/${l.id}`}>{l.title}</a> },
                { h: 'Payments', right: true, c: (l: any) => l.payments },
                { h: 'Collected', right: true, c: (l: any) => <Money minor={l.collected} currency={l.currency} compact /> },
              ]} empty={<Empty title="No links yet" />} />
            </Card>
          </div>
        </div>
      </div>;
    }}</Gate>
  </>;
}
const Attn = ({ n, label, href }: { n: number; label: string; href: string }) => n ? <a href={href} className="row"><span className="badge warn plain">{n}</span><span style={{ color: 'var(--ink)' }}>{label}</span></a> : null;

export function Transactions({ biz }: { biz: Biz }) {
  const [f, setF] = useState<{ category: string; state: string; currency: string; search: string; from: string; to: string }>({ category: '', state: '', currency: '', search: '', from: '', to: '' });
  const q = useOp<any[]>('biz.transactions', { ...f, from: f.from || null, to: f.to ? new Date(new Date(f.to).getTime() + 86400_000).toISOString() : null });
  const [open, setOpen] = useState<string | null>(null);
  const set = (k: string) => (e: any) => setF({ ...f, [k]: e.target.value });
  return <>
    <PageHead title="Transactions" sub="Every payment, deposit, share and payout for this business."
      actions={<button className="btn" disabled={!q.data?.length} onClick={() => downloadCsv(`knock-transactions-${biz.handle}.csv`, q.data ?? [])}>Export CSV</button>} />
    <Card pad={false}>
      <div className="card-b row wrap" style={{ borderBottom: '1px solid var(--line)' }}>
        <input className="input" style={{ maxWidth: 240 }} placeholder="Search reference or customer" value={f.search} onChange={set('search')} aria-label="Search" />
        <select className="input" style={{ width: 180 }} value={f.category} onChange={set('category')} aria-label="Type"><option value="">All types</option>{Object.entries(CAT).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select>
        <select className="input" style={{ width: 150 }} value={f.state} onChange={set('state')} aria-label="Status"><option value="">All statuses</option>{['succeeded', 'pending', 'failed', 'reversed'].map((s) => <option key={s} value={s}>{human(s === 'succeeded' ? 'successful' : s)}</option>)}</select>
        <select className="input" style={{ width: 120 }} value={f.currency} onChange={set('currency')} aria-label="Currency"><option value="">Any currency</option>{['NGN', 'USDT', 'USDC', 'BTC'].map((s) => <option key={s}>{s}</option>)}</select>
        <input type="date" className="input" style={{ width: 150 }} value={f.from} onChange={set('from')} aria-label="From date" />
        <input type="date" className="input" style={{ width: 150 }} value={f.to} onChange={set('to')} aria-label="To date" />
      </div>
      <Gate q={q} empty={<Empty title="No transactions match">Try a wider date range or clear the filters.</Empty>}>{(rows) => <Table rows={rows} onRow={(t) => setOpen(t.id)} cols={[
        { h: 'Date', c: (t) => <span className="small">{fmtDate(t.occurred_at)}</span> },
        { h: 'Type', c: (t) => catLabel(t.category) },
        { h: 'Customer / detail', c: (t) => <div><div>{t.counterparty}</div><div className="small muted mono">{t.reference}</div></div> },
        { h: 'Status', c: (t) => <Status s={t.state} /> },
        { h: 'Amount', right: true, c: (t) => <>{t.direction === 'out' ? '−' : ''}<Money minor={t.amount} currency={t.currency} /></> },
        { h: 'Fees', right: true, c: (t) => <Money minor={t.fees} currency={t.currency} /> },
        { h: 'Net', right: true, c: (t) => <Money minor={t.net} currency={t.currency} /> },
      ]} />}</Gate>
    </Card>
    <TxDrawer id={open} onClose={() => setOpen(null)} />
  </>;
}

function TxDrawer({ id, onClose }: { id: string | null; onClose: () => void }) {
  const q = useOp<any>('biz.transaction', { id }, { skip: !id });
  return <Drawer open={!!id} onClose={onClose} title="Transaction details">
    <Gate q={q} empty={<Empty title="Not found" />}>{(t) => <div className="stack">
      <div><div className="muted small">{catLabel(t.category)}</div><div className="hero">{t.direction === 'out' ? '−' : '+'}<Money minor={t.amount} currency={t.currency} /></div><div style={{ marginTop: 6 }}><Status s={t.state} /></div></div>
      <div className="kv">
        <div>Reference</div><div className="mono">{t.reference}</div>
        <div>Date</div><div>{fmtDate(t.occurred_at)}</div>
        <div>Customer / detail</div><div>{t.counterparty}</div>
        {t.link_title && <><div>Payment link</div><div>{t.link_title}</div></>}
        <div>Fees (Knock)</div><div><Money minor={t.fees} currency={t.currency} /></div>
        <div>Net</div><div><Money minor={t.net} currency={t.currency} /></div>
        <div>Provider</div><div>{t.provider}</div>
        <div>Provider reference</div><div className="mono">{t.provider_reference ?? '—'}</div>
        <div>Provider status</div><div>{human(t.provider_status)}</div>
      </div>
      <Card title="Ledger entries for this business" pad={false}>
        <Table rows={t.ledger} cols={[
          { h: 'When', c: (l: any) => <span className="small">{fmtDate(l.at)}</span> },
          { h: 'Entry', c: (l: any) => <div><div>{human(l.kind)}</div><div className="small muted">{human(l.account.replace('user_', ''))} balance</div></div> },
          { h: 'Change', right: true, c: (l: any) => <span style={{ color: BigInt(l.amount) < 0n ? 'var(--ink)' : 'var(--green-strong)' }}>{BigInt(l.amount) > 0n ? '+' : ''}{fmtMoney(l.amount, l.currency)}</span> },
        ]} empty={<div className="card-b muted">No ledger movement yet. Pending or failed items never touch your balance.</div>} />
      </Card>
      {t.history?.length > 0 && <Card title="Lifecycle"><ul className="timeline">{t.history.map((h: any, i: number) => <li key={i}><div>{human(h.action.replace('crypto.', ''))}</div><div className="small muted">{fmtDate(h.at)} · {h.actor_kind}</div></li>)}</ul></Card>}
    </div>}</Gate>
  </Drawer>;
}

export function Customers({ biz }: { biz: Biz }) {
  const q = useOp<any[]>('biz.customers');
  const [s, setS] = useState('');
  return <>
    <PageHead title="Customers" sub="People who have paid you through your payment links." actions={<button className="btn" disabled={!q.data?.length} onClick={() => downloadCsv(`knock-customers-${biz.handle}.csv`, q.data ?? [])}>Export CSV</button>} />
    <Card pad={false}>
      <div className="card-b" style={{ borderBottom: '1px solid var(--line)' }}><input className="input" style={{ maxWidth: 300 }} placeholder="Search name or email" value={s} onChange={(e) => setS(e.target.value)} aria-label="Search customers" /></div>
      <Gate q={q} empty={<Empty title="No customers yet">Share a payment link. Anyone who pays appears here.</Empty>}>{(rows) => <Table rows={rows.filter((c) => !s || (c.name + c.email).toLowerCase().includes(s.toLowerCase()))} cols={[
        { h: 'Customer', c: (c) => <div><div>{c.name ?? '—'}</div><div className="small muted">{c.email}</div></div> },
        { h: 'Payments', right: true, c: (c) => c.payments },
        { h: 'Total paid', right: true, c: (c) => <Money minor={c.total} currency={c.currency} /> },
        { h: 'First paid', c: (c) => fmtDate(c.first_paid_at, false) },
        { h: 'Last paid', c: (c) => fmtDate(c.last_paid_at, false) },
      ]} />}</Gate>
    </Card>
  </>;
}

export function Analytics({ biz }: { biz: Biz }) {
  const { r, setR, from, to } = useRange('90d');
  const q = useOp<any>('biz.analytics', { from, to });
  const DOW = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return <>
    <PageHead title="Analytics" sub="How your links and payment methods perform." actions={<RangePicker value={r} onChange={setR} />} />
    <Gate q={q}>{(a) => <div className="stack">
      <Card title="Payment link performance" pad={false} actions={<button className="btn sm" onClick={() => downloadCsv(`knock-links-${biz.handle}.csv`, a.by_link)}>Export</button>}>
        <Table rows={a.by_link} cols={[
          { h: 'Link', c: (l: any) => <div><div>{l.title}</div><div className="small muted mono">{l.reference}</div></div> },
          { h: 'Attempts', right: true, c: (l: any) => l.attempts },
          { h: 'Successful', right: true, c: (l: any) => l.succeeded },
          { h: 'Conversion', right: true, c: (l: any) => l.attempts ? Math.round((100 * l.succeeded) / l.attempts) + '%' : '—' },
          { h: 'Collected', right: true, c: (l: any) => <Money minor={l.collected} currency={l.currency} /> },
        ]} />
      </Card>
      <div className="grid g2">
        <Card title="Activity by type" pad={false}><Table rows={a.by_category} cols={[
          { h: 'Type', c: (x: any) => catLabel(x.category) }, { h: 'Status', c: (x: any) => <Status s={x.state} /> },
          { h: 'Count', right: true, c: (x: any) => x.n }, { h: 'Amount', right: true, c: (x: any) => <Money minor={x.amount} currency={x.currency} compact /> },
        ]} /></Card>
        <Card title="Busiest days (successful income)">
          {a.by_weekday.length ? <div className="stack tight">{(() => {
            const max = a.by_weekday.reduce((m: number, x: any) => Math.max(m, x.n), 1);
            return a.by_weekday.map((x: any, i: number) => <div key={i} className="row"><span style={{ width: 40 }} className="small">{DOW[x.dow]}</span>
              <div className="bar-track" style={{ flex: 1 }}><div className="bar-fill" style={{ width: `${(100 * x.n) / max}%` }} /></div><span className="small num" style={{ width: 120, textAlign: 'right' }}>{x.n} · {fmtMoney(x.amount, x.currency, { compact: true })}</span></div>);
          })()}</div> : <Empty title="No income in this period" />}
        </Card>
      </div>
    </div>}</Gate>
  </>;
}

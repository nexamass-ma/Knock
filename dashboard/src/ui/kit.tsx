import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import qrcode from 'qrcode-generator';
import type { Sandbox } from '../data/sandbox.ts';
import { ApiError } from '../data/sandbox.ts';

// ---------------------------------------------------------------- data
export interface Session { userId: string; context: string | null }
interface Ctx { sb: Sandbox; session: Session; setSession: (s: Session) => void; tick: number; bump: () => void; toast: (msg: string, bad?: boolean) => void }
export const AppCtx = createContext<Ctx>(null as any);
export const useApp = () => useContext(AppCtx);

export function AppProvider({ sb, initial, children }: { sb: Sandbox; initial: Session; children: ReactNode }) {
  const [session, setSession] = useState(initial);
  const [tick, setTick] = useState(0);
  const [t, setT] = useState<{ msg: string; bad?: boolean } | null>(null);
  const timer = useRef<any>(null);
  const toast = useCallback((msg: string, bad?: boolean) => {
    setT({ msg, bad }); clearTimeout(timer.current); timer.current = setTimeout(() => setT(null), 4200);
  }, []);
  const value = useMemo(() => ({ sb, session, setSession, tick, bump: () => setTick((x) => x + 1), toast }), [sb, session, tick, toast]);
  return <AppCtx.Provider value={value}>{children}{t && <div className={'toast' + (t.bad ? ' bad' : '')} role="status">{t.msg}</div>}</AppCtx.Provider>;
}

export function useOp<T = any>(name: string, input: Record<string, unknown> = {}, opts: { skip?: boolean; context?: string | null } = {}) {
  const { sb, session, tick } = useApp();
  const [state, setState] = useState<{ data: T | null; error: ApiError | null; loading: boolean }>({ data: null, error: null, loading: true });
  const key = JSON.stringify(input);
  const ctx = opts.context !== undefined ? opts.context : session.context;
  useEffect(() => {
    if (opts.skip) return;
    let live = true;
    setState((s) => ({ ...s, loading: true }));
    sb.run(name, { userId: session.userId, context: ctx }, input)
      .then((data) => live && setState({ data: data as T, error: null, loading: false }))
      .catch((error) => live && setState({ data: null, error, loading: false }));
    return () => { live = false; };
  }, [name, key, session.userId, ctx, tick, opts.skip]);
  return state;
}

export function useAct() {
  const { sb, session, bump, toast } = useApp();
  const [busy, setBusy] = useState(false);
  const run = useCallback(async <T = any,>(name: string, input: Record<string, unknown> = {}, ok?: string): Promise<T | null> => {
    setBusy(true);
    try {
      const r = await sb.run(name, session, input);
      bump(); if (ok) toast(ok);
      return r as T;
    } catch (e: any) {
      toast(e.message ?? 'Something went wrong', true);
      return null;
    } finally { setBusy(false); }
  }, [sb, session, bump, toast]);
  const sim = useCallback(async <T = any,>(fn: () => Promise<T>, ok?: string): Promise<T | null> => {
    setBusy(true);
    try { const r = await fn(); bump(); if (ok) toast(ok); return r; }
    catch (e: any) { toast(e.message ?? 'Something went wrong', true); return null; }
    finally { setBusy(false); }
  }, [bump, toast]);
  return { run, sim, busy };
}

// ---------------------------------------------------------------- routing
export function useHash(): [string[], (to: string) => void] {
  const read = () => (location.hash.replace(/^#\/?/, '') || '').split('?')[0].split('/').filter(Boolean);
  const [parts, setParts] = useState(read);
  useEffect(() => {
    const on = () => { setParts(read()); window.scrollTo(0, 0); };
    window.addEventListener('hashchange', on);
    return () => window.removeEventListener('hashchange', on);
  }, []);
  return [parts, (to: string) => { location.hash = '#/' + to.replace(/^\//, ''); }];
}

// ---------------------------------------------------------------- money
const DEC: Record<string, number> = { NGN: 2, GHS: 2, USD: 2, USDT: 6, USDC: 6, BTC: 8, LTC: 8, DOGE: 8, BCH: 8 };
const SYM: Record<string, string> = { NGN: '₦', USD: '$', GHS: 'GH₵' };
export const decimals = (c: string) => DEC[c?.toUpperCase()] ?? 2;
/** Minor units (string/bigint) to display text. Integer maths only. */
export function fmtMoney(minor: string | number | bigint | null | undefined, currency: string, opts: { compact?: boolean; dp?: number } = {}) {
  if (minor === null || minor === undefined || minor === '') return '—';
  const d = decimals(currency);
  let v = BigInt(typeof minor === 'number' ? Math.round(minor) : minor);
  const neg = v < 0n; if (neg) v = -v;
  const base = 10n ** BigInt(d);
  const whole = v / base;
  let frac = (v % base).toString().padStart(d, '0');
  const show = opts.dp ?? (currency === 'NGN' || currency === 'USD' || currency === 'GHS' ? 2 : currency === 'BTC' ? 8 : 2);
  frac = frac.slice(0, show);
  let w = whole.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  if (opts.compact && whole >= 1_000_000n) w = (Number(whole) / 1_000_000).toFixed(Number(whole) >= 10_000_000 ? 1 : 2).replace(/\.0+$/, '') + 'm';
  else if (opts.compact && whole >= 10_000n) w = (Number(whole) / 1000).toFixed(1).replace(/\.0$/, '') + 'k';
  const num = opts.compact && whole >= 10_000n ? w : `${w}${show ? '.' + frac : ''}`;
  const s = SYM[currency];
  return (neg ? '−' : '') + (s ? s + num : `${num} ${currency}`);
}
/** Major-unit input text to minor units string; null if invalid. */
export function toMinor(text: string, currency: string): string | null {
  const t = text.replace(/[,\s₦$]/g, '');
  const d = decimals(currency);
  const m = /^(\d+)(?:\.(\d+))?$/.exec(t);
  if (!m || (m[2] && m[2].length > d)) return null;
  const v = BigInt(m[1]) * 10n ** BigInt(d) + BigInt((m[2] ?? '').padEnd(d, '0') || '0');
  return v > 0n ? v.toString() : null;
}
export const Money = ({ minor, currency, compact }: { minor: any; currency: string; compact?: boolean }) =>
  <span className="num">{fmtMoney(minor, currency, { compact })}</span>;

export const fmtDate = (s: string | null | undefined, time = true) => s ? new Date(s).toLocaleString('en-NG', time
  ? { day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' } : { day: 'numeric', month: 'short', year: 'numeric' }) : '—';
export const ago = (s: string) => {
  const m = Math.round((Date.now() - new Date(s).getTime()) / 60000);
  if (m < 1) return 'just now'; if (m < 60) return m + ' min ago';
  const h = Math.round(m / 60); if (h < 24) return h + ' h ago';
  return fmtDate(s, false);
};
export const human = (s: string | null | undefined) => (s ?? '').replace(/[._]/g, ' ').replace(/^./, (c) => c.toUpperCase());

// ---------------------------------------------------------------- status
const GOOD = ['succeeded', 'completed', 'verified', 'active', 'available', 'approved', 'processed', 'distributed', 'resolved', 'cleared', 'accepted', 'ok', 'clear'];
const WARN = ['pending', 'processing', 'confirming', 'under_review', 'pending_approval', 'reserved', 'submitting', 'held', 'awaiting_payout', 'investigating', 'info_required',
  'below_minimum', 'flagged', 'paused', 'invited', 'new', 'medium', 'warning', 'retrying', 'queued', 'open', 'escalated', 'submission_unknown', 'awaiting_provider', 'not_started', 'pending_customer', 'low'];
const BAD = ['failed', 'rejected', 'reversed', 'expired', 'restricted', 'frozen', 'suspended', 'closed_bad', 'failed_to_start', 'failed_retrying', 'high', 'critical', 'not_submitted', 'capacity_unavailable', 'disputed'];
const LABEL: Record<string, string> = { succeeded: 'Successful', under_review: 'Under review', info_required: 'More info needed', pending_approval: 'Awaiting approval',
  not_started: 'Not started', failed_to_start: 'Failed to start', failed_retrying: 'Retrying', below_minimum: 'Below minimum', awaiting_payout: 'Awaiting payout', submission_unknown: 'Checking with provider' };
export function Status({ s, label }: { s: string | null | undefined; label?: string }) {
  const v = (s ?? '').toLowerCase();
  const cls = GOOD.includes(v) ? 'good' : BAD.includes(v) ? 'bad' : WARN.includes(v) ? 'warn' : '';
  return <span className={'badge ' + cls}>{label ?? LABEL[v] ?? human(v || 'unknown')}</span>;
}

// ---------------------------------------------------------------- layout
export function Card({ title, actions, children, pad = true, className = '' }: { title?: ReactNode; actions?: ReactNode; children: ReactNode; pad?: boolean; className?: string }) {
  return <section className={'card ' + className}>
    {(title || actions) && <div className="card-h"><h2>{title}</h2><div className="spacer" />{actions}</div>}
    {pad ? <div className="card-b">{children}</div> : children}
  </section>;
}
export const Stat = ({ label, value, sub, tone }: { label: ReactNode; value: ReactNode; sub?: ReactNode; tone?: 'good' | 'warn' | 'bad' }) =>
  <div className="card stat"><div className="label">{label}</div><div className="value" style={tone ? { color: `var(--${tone === 'good' ? 'green-strong' : tone === 'warn' ? 'amber' : 'red'})` } : undefined}>{value}</div>{sub && <div className="sub">{sub}</div>}</div>;
export const Empty = ({ title, children, action }: { title: string; children?: ReactNode; action?: ReactNode }) =>
  <div className="empty"><h3>{title}</h3><div>{children}</div>{action}</div>;
export const PageHead = ({ title, sub, actions }: { title: string; sub?: ReactNode; actions?: ReactNode }) =>
  <div className="row wrap" style={{ marginBottom: 20, alignItems: 'flex-end' }}><div><h1>{title}</h1>{sub && <div className="muted" style={{ marginTop: 4 }}>{sub}</div>}</div><div className="spacer" /><div className="row wrap">{actions}</div></div>;
export function Loading({ what = 'Loading' }: { what?: string }) { return <div className="empty"><div className="spinner" />{what}…</div>; }
export function ErrorBox({ error }: { error: ApiError | null }) {
  if (!error) return null;
  return <div className={'notice ' + (error.code === 'forbidden' || error.code === 'mfa_required' ? 'warn' : 'bad')}>
    <b>{error.code === 'forbidden' ? 'No access. ' : error.code === 'mfa_required' ? 'Two-factor authentication required. ' : ''}</b>{error.message}</div>;
}
export function Gate<T>({ q, children, empty }: { q: { data: T | null; error: ApiError | null; loading: boolean }; children: (d: T) => ReactNode; empty?: ReactNode }) {
  if (q.error) return <ErrorBox error={q.error} />;
  if (q.loading && q.data === null) return <Loading />;
  if (q.data === null || (Array.isArray(q.data) && q.data.length === 0 && empty)) return <>{empty ?? <Empty title="Nothing here yet" />}</>;
  return <>{children(q.data)}</>;
}

export interface Col<R> { h: ReactNode; c: (r: R) => ReactNode; right?: boolean; w?: number | string }
export function Table<R>({ rows, cols, onRow, empty }: { rows: R[]; cols: Col<R>[]; onRow?: (r: R) => void; empty?: ReactNode }) {
  if (!rows.length) return <>{empty ?? <Empty title="No records yet" />}</>;
  return <div className="tbl-wrap"><table className="tbl"><thead><tr>{cols.map((c, i) => <th key={i} className={c.right ? 'right' : ''} style={{ width: c.w }}>{c.h}</th>)}</tr></thead>
    <tbody>{rows.map((r, i) => <tr key={i} className={onRow ? 'click' : ''} onClick={onRow ? () => onRow(r) : undefined} tabIndex={onRow ? 0 : undefined}
      onKeyDown={onRow ? (e) => { if (e.key === 'Enter') onRow(r); } : undefined}>
      {cols.map((c, j) => <td key={j} className={c.right ? 'right num' : ''}>{c.c(r)}</td>)}</tr>)}</tbody></table></div>;
}

export function Drawer({ open, onClose, title, children }: { open: boolean; onClose: () => void; title: ReactNode; children: ReactNode }) {
  useEffect(() => { const k = (e: KeyboardEvent) => e.key === 'Escape' && onClose(); window.addEventListener('keydown', k); return () => window.removeEventListener('keydown', k); }, [onClose]);
  if (!open) return null;
  return <div className="overlay" onClick={onClose}><aside className="drawer" role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()}>
    <div className="card-h" style={{ position: 'sticky', top: 0, background: 'var(--surface)', zIndex: 1 }}><h2>{title}</h2><div className="spacer" /><button className="btn ghost" onClick={onClose} aria-label="Close">✕</button></div>
    <div className="card-b">{children}</div></aside></div>;
}
export function Modal({ open, onClose, title, children }: { open: boolean; onClose: () => void; title: ReactNode; children: ReactNode }) {
  if (!open) return null;
  return <div className="overlay modal-wrap" onClick={onClose}><div className="modal" role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()}>
    <div className="card-h"><h2>{title}</h2><div className="spacer" /><button className="btn ghost" onClick={onClose} aria-label="Close">✕</button></div>
    <div className="card-b">{children}</div></div></div>;
}
export const Field = ({ label, hint, error, children }: { label: string; hint?: ReactNode; error?: string | null; children: ReactNode }) =>
  <label className="field"><span>{label}</span>{children}{error ? <div className="err">{error}</div> : hint ? <div className="hint">{hint}</div> : null}</label>;
export function Seg<T extends string>({ value, options, onChange }: { value: T; options: [T, string][]; onChange: (v: T) => void }) {
  return <div className="seg" role="tablist">{options.map(([v, l]) => <button key={v} className={v === value ? 'on' : ''} onClick={() => onChange(v)} type="button">{l}</button>)}</div>;
}
export function Tabs<T extends string>({ value, options, onChange }: { value: T; options: [T, string][]; onChange: (v: T) => void }) {
  return <div className="pill-tabs">{options.map(([v, l]) => <button key={v} className={v === value ? 'on' : ''} onClick={() => onChange(v)}>{l}</button>)}</div>;
}

// ---------------------------------------------------------------- date range
export type RangeKey = 'today' | 'yesterday' | '7d' | '30d' | '90d' | 'custom';
export function rangeOf(k: RangeKey, custom?: { from: string; to: string }) {
  const d0 = new Date(); d0.setHours(0, 0, 0, 0);
  const day = 86400_000;
  const end = new Date(d0.getTime() + day);
  switch (k) {
    case 'today': return { from: d0.toISOString(), to: end.toISOString() };
    case 'yesterday': return { from: new Date(d0.getTime() - day).toISOString(), to: d0.toISOString() };
    case '7d': return { from: new Date(d0.getTime() - 6 * day).toISOString(), to: end.toISOString() };
    case '30d': return { from: new Date(d0.getTime() - 29 * day).toISOString(), to: end.toISOString() };
    case '90d': return { from: new Date(d0.getTime() - 89 * day).toISOString(), to: end.toISOString() };
    case 'custom': return { from: new Date(custom?.from || d0).toISOString(), to: new Date(new Date(custom?.to || d0).getTime() + day).toISOString() };
  }
}
export function RangePicker({ value, onChange }: { value: { k: RangeKey; from: string; to: string }; onChange: (v: { k: RangeKey; from: string; to: string }) => void }) {
  return <div className="row wrap">
    <Seg value={value.k} onChange={(k) => onChange({ ...value, k })} options={[['today', 'Today'], ['yesterday', 'Yesterday'], ['7d', '7 days'], ['30d', '30 days'], ['90d', '90 days'], ['custom', 'Custom']]} />
    {value.k === 'custom' && <><input type="date" className="input" style={{ width: 150 }} value={value.from} onChange={(e) => onChange({ ...value, from: e.target.value })} aria-label="From" />
      <input type="date" className="input" style={{ width: 150 }} value={value.to} onChange={(e) => onChange({ ...value, to: e.target.value })} aria-label="To" /></>}
  </div>;
}
export function useRange(initial: RangeKey = '30d') {
  const today = new Date().toISOString().slice(0, 10);
  const [r, setR] = useState<{ k: RangeKey; from: string; to: string }>({ k: initial, from: today, to: today });
  return { r, setR, ...rangeOf(r.k, r) };
}

// ---------------------------------------------------------------- chart (one series, columns per day)
export function DailyBars({ series, currency, from, to }: { series: { day: string; amount: string; count: number }[]; currency: string; from: string; to: string }) {
  const [hover, setHover] = useState<number | null>(null);
  const days: { day: Date; amount: bigint; count: number }[] = [];
  const map = new Map(series.map((s) => [new Date(s.day).toDateString(), s]));
  for (let t = new Date(from).getTime(); t < new Date(to).getTime(); t += 86400_000) {
    const d = new Date(t); const s = map.get(d.toDateString());
    days.push({ day: d, amount: s ? BigInt(s.amount) : 0n, count: s?.count ?? 0 });
  }
  const max = days.reduce((m, d) => (d.amount > m ? d.amount : m), 0n);
  const W = 720, H = 180, pad = 4;
  const bw = Math.max(2, (W - pad * 2) / Math.max(days.length, 1) - 2);
  if (max === 0n) return <Empty title="No money collected in this period">Payments you receive will appear here day by day.</Empty>;
  return <div style={{ position: 'relative' }}>
    <svg viewBox={`0 0 ${W} ${H + 22}`} width="100%" role="img" aria-label={`Money collected per day in ${currency}`} onMouseLeave={() => setHover(null)}>
      <line x1={0} x2={W} y1={H} y2={H} stroke="var(--line-strong)" />
      {days.map((d, i) => {
        const h = max ? Number((d.amount * 1000n) / max) / 1000 * (H - 12) : 0;
        const x = pad + i * ((W - pad * 2) / days.length) + 1;
        return <g key={i} onMouseEnter={() => setHover(i)}>
          <rect x={x - 1} y={0} width={bw + 2} height={H} fill="transparent" />
          {h > 0 && <rect x={x} y={H - h} width={bw} height={h} rx={Math.min(4, bw / 2)} fill={hover === i ? 'var(--green-strong)' : 'var(--green)'} />}
        </g>;
      })}
      {[0, Math.floor(days.length / 2), days.length - 1].map((i) => days[i] && <text key={i} x={pad + i * ((W - pad * 2) / days.length)} y={H + 16} fontSize="11" fill="var(--ink-3)"
        textAnchor={i === 0 ? 'start' : i === days.length - 1 ? 'end' : 'middle'}>{days[i].day.toLocaleDateString('en-NG', { day: 'numeric', month: 'short' })}</text>)}
    </svg>
    {hover !== null && days[hover] && <div className="chart-tip" style={{ left: `${((hover + 0.5) / days.length) * 100}%`, top: 0 }}>
      {days[hover].day.toLocaleDateString('en-NG', { weekday: 'short', day: 'numeric', month: 'short' })}: <b>{fmtMoney(days[hover].amount, currency)}</b> · {days[hover].count} payment{days[hover].count === 1 ? '' : 's'}</div>}
  </div>;
}

export function QR({ text, size = 4 }: { text: string; size?: number }) {
  const svg = useMemo(() => { const q = qrcode(0, 'M'); q.addData(text); q.make(); return q.createSvgTag({ cellSize: size, margin: 0, scalable: true }); }, [text, size]);
  return <div className="qr" style={{ width: 150 }} dangerouslySetInnerHTML={{ __html: svg }} aria-label="QR code" />;
}

export function Copy({ text, label = 'Copy' }: { text: string; label?: string }) {
  const { toast } = useApp();
  return <button className="btn sm" type="button" onClick={() => { navigator.clipboard?.writeText(text).then(() => toast('Copied'), () => toast('Copy failed', true)); }}>{label}</button>;
}

export function downloadCsv(name: string, rows: Record<string, unknown>[]) {
  if (!rows.length) return;
  const keys = Object.keys(rows[0]);
  const esc = (v: unknown) => { const s = v === null || v === undefined ? '' : typeof v === 'object' ? JSON.stringify(v) : String(v); return /[",\n]/.test(s) || /^[=+\-@]/.test(s) ? `"${s.replace(/^([=+\-@])/, "'$1").replace(/"/g, '""')}"` : s; };
  const csv = [keys.join(','), ...rows.map((r) => keys.map((k) => esc(r[k])).join(','))].join('\n');
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv' }));
  a.download = name; a.click(); URL.revokeObjectURL(a.href);
}

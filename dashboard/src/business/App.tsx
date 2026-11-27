import { useEffect, useState } from 'react';
import { Drawer, Empty, Gate, Loading, Status, ago, useAct, useApp, useHash, useOp } from '../ui/kit.tsx';
import { Overview, Transactions, Customers, Analytics } from './pages.tsx';
import { Links, SmartSplit } from './links.tsx';
import { Crypto, Withdrawals } from './money.tsx';
import { Team, Settings, Onboarding } from './org.tsx';
import { PayPage } from './PayPage.tsx';
import { Developers } from './developers.tsx';

export interface Biz { id: string; handle: string; name: string; role: string; verification_status: string; account_status: string; permissions: string[]; country: string }
export const can = (b: Biz | null | undefined, p: string) => !!b?.permissions?.includes(p);

const NAV: [string, string, string][] = [
  ['', 'Overview', '◎'], ['transactions', 'Transactions', '⇅'], ['links', 'Payment Links', '⌁'], ['split', 'Smart Split', '⑃'],
  ['crypto', 'Crypto', '₿'], ['withdrawals', 'Withdrawals', '↗'], ['customers', 'Customers', '☺'], ['analytics', 'Analytics', '▥'],
  ['team', 'Team', '⚇'], ['developers', 'Developers', '⌘'], ['settings', 'Settings', '⚙'],
];

export function BusinessApp() {
  const [parts, go] = useHash();
  if (parts[0] === 'pay' && parts[1]) return <PayPage slug={parts[1]} paymentId={parts[2]} />;
  return <Shell parts={parts} go={go} />;
}

function Shell({ parts, go }: { parts: string[]; go: (s: string) => void }) {
  const { sb, session, setSession } = useApp();
  const mine = useOp<Biz[]>('me.businesses', {}, { context: null });
  const invites = useOp<any[]>('me.invites', {}, { context: null });
  const [menu, setMenu] = useState(false);
  const [notes, setNotes] = useState(false);
  const list = mine.data ?? [];
  const biz = list.find((b) => b.id === session.context) ?? null;
  useEffect(() => {
    if (mine.data && (!session.context || !mine.data.some((b) => b.id === session.context))) {
      setSession({ ...session, context: mine.data[0]?.id ?? null });
    }
  }, [mine.data, session.context]);
  const page = parts[0] ?? '';
  const person = Object.values(sb.people).find((p) => p.id === session.userId);

  let body;
  if (mine.loading && !mine.data) body = <Loading />;
  else if (page === 'new' || !list.length) body = <Onboarding invites={invites.data ?? []} first={!list.length} onDone={(id) => { setSession({ ...session, context: id }); go('settings/verification'); }} />;
  else if (!biz) body = <Loading />;
  else body = <>
    {biz.verification_status !== 'verified' && page !== 'settings' && <div className="notice warn" style={{ marginBottom: 16 }}>
      <b>{biz.verification_status === 'restricted' ? 'This business is restricted.' : 'Finish verification to start collecting money.'}</b>{' '}
      Status: <Status s={biz.verification_status} />. Payment links, deposits and payouts stay off until Knock verifies the business. <a href="#/settings/verification">Go to verification →</a></div>}
    {page === '' && <Overview biz={biz} />}
    {page === 'transactions' && <Transactions biz={biz} />}
    {page === 'links' && <Links biz={biz} id={parts[1]} />}
    {page === 'split' && <SmartSplit biz={biz} id={parts[1]} />}
    {page === 'crypto' && <Crypto biz={biz} />}
    {page === 'withdrawals' && <Withdrawals biz={biz} />}
    {page === 'customers' && <Customers biz={biz} />}
    {page === 'analytics' && <Analytics biz={biz} />}
    {page === 'team' && <Team biz={biz} />}
    {page === 'developers' && <Developers biz={biz} />}
    {page === 'settings' && <Settings biz={biz} tab={parts[1]} />}
  </>;

  return <div className="shell">
    <aside className={'side' + (menu ? ' open' : '')} onClick={() => setMenu(false)}>
      <div className="brand"><div className="mark">K</div><div>Knock Business<small>Collect. Move. Manage.</small></div></div>
      {list.length > 0 && <select className="input" style={{ marginBottom: 10 }} value={session.context ?? ''} onClick={(e) => e.stopPropagation()}
        onChange={(e) => { if (e.target.value === '__new') go('new'); else { setSession({ ...session, context: e.target.value }); go(''); } }} aria-label="Business">
        {list.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}<option value="__new">+ Add a business</option></select>}
      <nav className="nav">{biz && NAV.map(([k, l, i]) => <a key={k} href={'#/' + k} className={page === k ? 'on' : ''}><span aria-hidden>{i}</span>{l}</a>)}</nav>
      <div className="spacer" />
      <div className="small muted" style={{ padding: '10px' }}>Admin is a separate app: <a href="./admin.html">Knock Admin</a></div>
    </aside>
    <div className="main">
      <div className="sandbox"><b>SANDBOX</b> Real Knock database engine running in your browser on sandbox records. No real money, no Breet or bank calls.
        <span className="spacer" />Signed in as
        <select className="input" style={{ width: 'auto', padding: '3px 8px' }} value={session.userId} onChange={(e) => setSession({ userId: e.target.value, context: null })} aria-label="Sandbox user">
          {Object.values(sb.people).filter((p) => !['amaka', 'bola', 'dayo', 'ese', 'root'].includes(p.username)).map((p) => <option key={p.id} value={p.id}>@{p.username} · {p.note}</option>)}
        </select></div>
      <header className="top">
        <button className="btn ghost menu-btn" onClick={() => setMenu(true)} aria-label="Menu">☰</button>
        <div><b>{biz?.name ?? 'Knock Business'}</b>{biz && <span className="muted small"> · @{biz.handle} · {biz.role.replace('_', ' ')}</span>}</div>
        <div className="spacer" />
        {biz && <Status s={biz.verification_status} />}
        {biz && <button className="btn" onClick={() => setNotes(true)} aria-label="Notifications">🔔</button>}
        <span className="small muted">{person?.name}</span>
      </header>
      <div className="content">{body}</div>
    </div>
    {biz && <Notifications open={notes} onClose={() => setNotes(false)} />}
  </div>;
}

function Notifications({ open, onClose }: { open: boolean; onClose: () => void }) {
  const q = useOp<any[]>('biz.notifications', {}, { skip: !open });
  const { run } = useAct();
  return <Drawer open={open} onClose={onClose} title="Notifications">
    <div className="row" style={{ marginBottom: 12 }}><span className="muted small">Business notifications, newest first.</span><div className="spacer" /><button className="btn sm" onClick={() => run('biz.mark_read')}>Mark all read</button></div>
    <Gate q={q} empty={<Empty title="No notifications" />}>{(rows) => <div className="stack tight">{rows.map((n) =>
      <div key={n.id} className="card" style={{ padding: 12, opacity: n.read_at ? 0.7 : 1 }}><div className="row"><b>{n.title}</b><div className="spacer" /><span className="small muted">{ago(n.created_at)}</span></div><div className="muted">{n.body}</div></div>)}</div>}</Gate>
  </Drawer>;
}

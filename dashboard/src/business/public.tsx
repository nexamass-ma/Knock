import { useState, type ReactNode } from 'react';
import { Field, useApp, useOp } from '../ui/kit.tsx';
import { DEMO_ACCOUNTS, DEMO_PASSWORD } from '../data/seed.ts';

// Public pages of Knock Business: homepage, sign-up and log-in. Sign-up is
// for business owners only and is deliberately short: the owner gets into
// the dashboard straight away, and verification (CAC, MEMAT, directors' NIN
// and BVN) happens afterwards from Settings > Verification. Money features
// stay locked until Knock verifies the business.

function Logo({ light }: { light?: boolean }) {
  return <a href="#/" className={'pub-logo' + (light ? ' light' : '')}><span className="pub-mark">K</span><span>Knock <b>Business</b></span></a>;
}

function Nav() {
  return <header className="pub-nav">
    <div className="pub-wrap pub-row">
      <Logo />
      <nav className="pub-links"><a href="#/" onClick={(e) => { e.preventDefault(); document.getElementById('features')?.scrollIntoView({ behavior: 'smooth' }); }}>Features</a>
        <a href="#/" onClick={(e) => { e.preventDefault(); document.getElementById('how')?.scrollIntoView({ behavior: 'smooth' }); }}>How it works</a>
        <a href="#/" onClick={(e) => { e.preventDefault(); document.getElementById('trust')?.scrollIntoView({ behavior: 'smooth' }); }}>Security</a></nav>
      <div className="pub-row" style={{ gap: 8 }}><a className="pub-btn ghost" href="#/login">Log in</a><a className="pub-btn" href="#/signup">Get started</a></div>
    </div>
  </header>;
}

const FEATURES: [string, string, string][] = [
  ['⌁', 'Payment links', 'Create a link in seconds and share it on WhatsApp, Instagram or an invoice. Fixed or open amounts, targets and expiry dates.'],
  ['◎', 'Hosted checkout', 'Customers pay from any crypto wallet to a one-time address with the exact amount, network and QR code. You see it confirm live.'],
  ['⑃', 'Smart Split', 'One payment, shared automatically between partners, vendors or your crew, by percentage or fixed amounts.'],
  ['⚇', 'Team and approvals', 'Invite your finance and support staff with the right role. Large withdrawals need a second approver.'],
  ['⌘', 'Webhooks for developers', 'Signed events to your server when a payment succeeds, so your shop updates orders by itself.'],
  ['✓', 'Verified business badge', 'Customers see your verified name on every payment page, so they know exactly who they are paying.'],
];

export function Home() {
  return <div className="pub">
    <Nav />
    <section className="pub-hero">
      <div className="pub-wrap pub-hero-grid">
        <div>
          <div className="pub-eyebrow">For Nigerian businesses</div>
          <h1>Get paid by anyone, <span className="pub-accent">in one link.</span></h1>
          <p className="pub-lead">Knock Business gives you payment links, a hosted checkout, automatic splits and a team dashboard. Sign up in two minutes and explore everything. Verify when you're ready to collect.</p>
          <div className="pub-row" style={{ gap: 10, flexWrap: 'wrap' }}>
            <a className="pub-btn lg" href="#/signup">Create your business account</a>
            <a className="pub-btn ghost lg" href="#/login">Log in</a>
          </div>
          <ul className="pub-ticks"><li>No paperwork to sign up</li><li>Verify with CAC and your directors' details later</li><li>Business owners only</li></ul>
        </div>
        <HeroArt />
      </div>
    </section>

    <section id="features" className="pub-section">
      <div className="pub-wrap">
        <h2 className="pub-h2">Everything you need to collect and manage money</h2>
        <p className="pub-sub">One account for your business, your team and your customers' payments.</p>
        <div className="pub-grid3">{FEATURES.map(([i, t, d]) => <div key={t} className="pub-card"><div className="pub-icon" aria-hidden>{i}</div><h3>{t}</h3><p>{d}</p></div>)}</div>
      </div>
    </section>

    <section id="how" className="pub-section alt">
      <div className="pub-wrap">
        <h2 className="pub-h2">Start today, verify when you're ready</h2>
        <div className="pub-steps">
          <div><span>1</span><h3>Sign up</h3><p>Your name, business name, email and phone. That's it. You're in your dashboard straight away.</p></div>
          <div><span>2</span><h3>Explore and set up</h3><p>Look around, invite your team, prepare payment links and connect your webhooks.</p></div>
          <div><span>3</span><h3>Verify and go live</h3><p>Add your CAC details, MEMAT and one or two directors with NIN and BVN. Once Knock approves, you can collect and withdraw.</p></div>
        </div>
      </div>
    </section>

    <section id="trust" className="pub-section">
      <div className="pub-wrap pub-trust">
        <div>
          <h2 className="pub-h2" style={{ textAlign: 'left' }}>Built for trust from day one</h2>
          <p className="pub-sub" style={{ textAlign: 'left', margin: 0 }}>Money only moves for verified businesses, and every naira and coin is recorded in a double-entry ledger.</p>
        </div>
        <ul className="pub-list">
          <li><b>Verified before money moves.</b> Collections and withdrawals unlock only after Knock reviews your business and directors.</li>
          <li><b>Two people for big withdrawals.</b> Set your own limit; above it, a second team member must approve.</li>
          <li><b>Confirmed with the provider.</b> A payment counts only after the payment provider confirms it. Pending or flagged payments are never credited.</li>
          <li><b>Licensed partners.</b> Crypto payments are processed by Breet. Naira collections are coming with our banking partner.</li>
        </ul>
      </div>
    </section>

    <section className="pub-cta">
      <div className="pub-wrap pub-row" style={{ justifyContent: 'space-between', flexWrap: 'wrap', gap: 16 }}>
        <div><h2>Ready to get paid?</h2><p>Open your business account in two minutes.</p></div>
        <a className="pub-btn white lg" href="#/signup">Create your business account</a>
      </div>
    </section>

    <footer className="pub-foot">
      <div className="pub-wrap pub-row" style={{ justifyContent: 'space-between', flexWrap: 'wrap', gap: 10 }}>
        <Logo /><span>Sandbox preview. No real money moves here.</span><span>© {new Date().getFullYear()} Knock</span>
      </div>
    </footer>
  </div>;
}

function HeroArt() {
  return <div className="pub-art" aria-hidden>
    <div className="pub-phone">
      <div className="pub-merchant"><span className="pub-mark sm">M</span><div><b>Mama Put Foods</b><div className="pub-verified">✓ Verified business</div></div></div>
      <div className="pub-muted">Wedding catering deposit</div>
      <div className="pub-amount">250.00 <small>USDT</small></div>
      <div className="pub-qr">{Array.from({ length: 49 }, (_, i) => <i key={i} className={[0, 1, 2, 7, 9, 14, 15, 16, 4, 5, 6, 11, 13, 18, 19, 20, 24, 30, 32, 34, 36, 38, 40, 42, 44, 46, 48, 22, 26, 28].includes(i) ? 'on' : ''} />)}</div>
      <div className="pub-status"><span className="dot" /> Payment detected · confirming</div>
    </div>
    <div className="pub-float one"><div className="pub-muted">Received today</div><b>₦ 1,284,500</b><div className="pub-up">12 payments</div></div>
    <div className="pub-float two"><span className="tick">✓</span> Split sent to 4 partners</div>
  </div>;
}

// ---------------------------------------------------------------- auth pages
function AuthShell({ title, sub, children, side }: { title: string; sub: ReactNode; children: ReactNode; side: ReactNode }) {
  return <div className="pub auth">
    <aside className="auth-side"><Logo light />{side}<div className="auth-note">Sandbox preview. Accounts live in this browser tab only.</div></aside>
    <main className="auth-main"><div className="auth-box">
      <div className="auth-mobile-logo"><Logo /></div>
      <h1>{title}</h1><p className="muted">{sub}</p>{children}</div></main>
  </div>;
}

const strength = (p: string) => (p.length >= 8 ? 1 : 0) + (/[a-z]/i.test(p) && /[0-9]/.test(p) ? 1 : 0) + (p.length >= 12 || /[^a-z0-9]/i.test(p) ? 1 : 0);

export function Signup({ onSignedIn }: { onSignedIn: (userId: string, businessId: string) => void }) {
  const { sb } = useApp();
  const cats = useOp<any[]>('pub.categories', {}, { context: null });
  const [f, setF] = useState({ full_name: '', business_name: '', category: '', email: '', phone: '', password: '' });
  const [agree, setAgree] = useState(false);
  const [show, setShow] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [touched, setTouched] = useState(false);
  const set = (k: keyof typeof f) => (e: any) => setF({ ...f, [k]: e.target.value });
  const emailOk = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(f.email.trim());
  const phoneOk = /^\+?[0-9 ]{10,16}$/.test(f.phone.trim());
  const s = strength(f.password);
  const ok = f.full_name.trim().split(/\s+/).length >= 2 && f.business_name.trim().length >= 2 && emailOk && phoneOk && s >= 2 && agree;
  const submit = async (e: React.FormEvent) => {
    e.preventDefault(); setTouched(true);
    if (!ok || busy) return;
    setBusy(true); setErr(null);
    try {
      const userId = await sb.auth.signUp(f.email, f.password);
      const r = await sb.run('me.register_business', { userId, context: null }, { signup: { full_name: f.full_name, business_name: f.business_name, email: f.email, phone: f.phone, category: f.category || null, country: 'NG' } });
      onSignedIn(userId, (r as any).id);
    } catch (x: any) { setErr(x.message ?? 'Something went wrong. Please try again.'); }
    finally { setBusy(false); }
  };
  return <AuthShell title="Create your business account" sub={<>Already have one? <a href="#/login">Log in</a></>}
    side={<div className="auth-pitch"><h2>Two minutes to sign up.<br />Verify when you're ready.</h2>
      <ul><li>Explore the full dashboard right away</li><li>Set up payment links, your team and webhooks</li><li>Then verify with your CAC details, MEMAT and one or two directors' NIN and BVN to start collecting</li></ul></div>}>
    <form className="stack" onSubmit={submit} noValidate>
      <Field label="Your full name" error={touched && f.full_name.trim().split(/\s+/).length < 2 ? 'Enter your first and last name' : null}><input className="input" value={f.full_name} onChange={set('full_name')} autoComplete="name" autoFocus /></Field>
      <div className="grid g2">
        <Field label="Business name" error={touched && f.business_name.trim().length < 2 ? 'Enter your business name' : null}><input className="input" value={f.business_name} onChange={set('business_name')} autoComplete="organization" /></Field>
        <Field label="What do you sell? (optional)"><select className="input" value={f.category} onChange={set('category')}><option value="">Choose…</option>{(cats.data ?? []).map((c) => <option key={c.code} value={c.code}>{c.label}</option>)}</select></Field>
      </div>
      <div className="grid g2">
        <Field label="Work email" error={touched && !emailOk ? 'Enter a valid email' : null}><input className="input" type="email" value={f.email} onChange={set('email')} autoComplete="email" /></Field>
        <Field label="Phone number" error={touched && !phoneOk ? 'Enter a valid phone number' : null}><input className="input" type="tel" value={f.phone} onChange={set('phone')} autoComplete="tel" placeholder="+234 803 000 0000" /></Field>
      </div>
      <Field label="Password" hint={<span className="row" style={{ gap: 8 }}><span className="meter" data-s={f.password ? s : 0}><i /><i /><i /></span>{['At least 8 characters, letters and numbers', 'Too weak', 'Good', 'Strong'][f.password ? s : 0]}</span>}>
        <div className="row" style={{ gap: 6 }}><input className="input" type={show ? 'text' : 'password'} value={f.password} onChange={set('password')} autoComplete="new-password" />
          <button type="button" className="btn sm ghost" onClick={() => setShow(!show)}>{show ? 'Hide' : 'Show'}</button></div></Field>
      <label className="check small"><input type="checkbox" checked={agree} onChange={(e) => setAgree(e.target.checked)} /> I own or run this business and agree to Knock's terms and privacy policy.</label>
      {err && <div className="notice bad" role="alert">{err}</div>}
      <button className="btn primary lg-btn" disabled={busy || (touched && !ok)}>{busy ? 'Creating your account…' : 'Create account'}</button>
      <div className="small muted">Knock Business is for business owners. Personal accounts use the Knock app. In production you'll confirm your email before your first log-in.</div>
    </form>
  </AuthShell>;
}

export function Login({ onSignedIn }: { onSignedIn: (userId: string) => void }) {
  const { sb } = useApp();
  const [f, setF] = useState({ email: '', password: '' });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [forgot, setForgot] = useState(false);
  const submit = async (e: React.FormEvent) => {
    e.preventDefault(); if (busy) return;
    setBusy(true); setErr(null);
    try {
      const userId = await sb.auth.signIn(f.email, f.password);
      const a: any = await sb.run('me.app_access', { userId, context: null });
      if (!a.allowed && !a.invited) throw new Error('This account isn\'t linked to a business. Knock Business is for business owners and their teams. Create a business account, or use the Knock app for personal payments.');
      onSignedIn(userId);
    } catch (x: any) { setErr(x.message ?? 'Something went wrong. Please try again.'); }
    finally { setBusy(false); }
  };
  return <AuthShell title="Log in to Knock Business" sub={<>New here? <a href="#/signup">Create a business account</a></>}
    side={<div className="auth-pitch"><h2>Welcome back.</h2><ul><li>See today's payments at a glance</li><li>Approve withdrawals with your team</li><li>Track verification and settlements</li></ul></div>}>
    <form className="stack" onSubmit={submit}>
      <Field label="Email"><input className="input" type="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} autoComplete="username" autoFocus /></Field>
      <Field label="Password"><input className="input" type="password" value={f.password} onChange={(e) => setF({ ...f, password: e.target.value })} autoComplete="current-password" /></Field>
      <div className="row"><span className="spacer" /><button type="button" className="linkbtn small" onClick={() => setForgot(!forgot)}>Forgot password?</button></div>
      {forgot && <div className="notice small">Password reset links are sent by email through Supabase Auth. Email isn't connected in this sandbox, so no message can be sent from here.</div>}
      {err && <div className="notice bad" role="alert">{err}</div>}
      <button className="btn primary lg-btn" disabled={busy || !f.email || !f.password}>{busy ? 'Logging in…' : 'Log in'}</button>
    </form>
    <div className="card card-b stack tight demo" style={{ marginTop: 20 }}>
      <b className="small">Sandbox accounts</b>
      <div className="small muted">Password for all: <span className="mono">{DEMO_PASSWORD}</span></div>
      {DEMO_ACCOUNTS.map((d) => <button key={d.email} type="button" className="demo-row" onClick={() => setF({ email: d.email, password: DEMO_PASSWORD })}>
        <span className="mono small">{d.email}</span><span className="small muted">{d.who}</span></button>)}
    </div>
  </AuthShell>;
}

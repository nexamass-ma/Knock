import { useEffect, useState, type ReactNode } from 'react';
import { createRoot } from 'react-dom/client';
import { boot } from './data/boot.ts';
import type { Sandbox } from './data/sandbox.ts';
import './ui/styles.css';

// Shared start-up for both apps: boot the in-browser Postgres, apply the real
// migrations, seed through the engine, then render the app.
export function start(render: (sb: Sandbox) => ReactNode) {
  function Boot() {
    const [sb, setSb] = useState<Sandbox | null>(null);
    const [msg, setMsg] = useState('Starting');
    const [err, setErr] = useState<string | null>(null);
    useEffect(() => { boot(setMsg).then(setSb).catch((e) => setErr(String(e?.message ?? e))); }, []);
    if (err) return <div className="boot"><div className="mark">K</div><h2>The sandbox could not start</h2><p className="muted">{err}</p><button className="btn" onClick={() => location.reload()}>Try again</button></div>;
    if (!sb) return <div className="boot"><div className="mark">K</div><div className="spinner" /><div>{msg}…</div><div className="small muted">Loading the real Knock database engine in your browser. This takes a few seconds.</div></div>;
    return <>{render(sb)}</>;
  }
  createRoot(document.getElementById('root')!).render(<Boot />);
}

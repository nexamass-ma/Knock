import { useState } from 'react';
import { Card, Empty, Field, Gate, Modal, Money, PageHead, Status, Table, Tabs, ago, fmtDate, human, toMinor, useAct, useApp, useHash, useOp } from '../ui/kit.tsx';
import { can, type Biz } from './App.tsx';

const ROLES: [string, string, string][] = [
  ['administrator', 'Administrator', 'Everything except changing the owner.'],
  ['finance_manager', 'Finance manager', 'Withdrawals, approvals, reports.'],
  ['operations_manager', 'Operations manager', 'Payment links, Smart Split, customers.'],
  ['accountant', 'Accountant', 'Read transactions and export reports.'],
  ['support', 'Support', 'Look up customers and payments.'],
  ['read_only', 'Read only', 'View the dashboard.'],
];
const PERM_LABEL: Record<string, string> = {
  'dashboard.view': 'View dashboard', 'transactions.view': 'View transactions', 'customers.view': 'View customers', 'reports.view': 'Reports and exports',
  'links.create': 'Create payment links', 'links.manage': 'Pause and close links', 'splits.manage': 'Manage Smart Split', 'crypto.receive': 'Crypto deposit addresses',
  'withdrawals.initiate': 'Request withdrawals', 'withdrawals.approve': 'Approve withdrawals', 'team.manage': 'Manage team', 'settings.manage': 'Business settings',
  'verification.manage': 'Verification documents',
};
const roleLabel = (r: string) => r === 'owner' ? 'Owner' : ROLES.find((x) => x[0] === r)?.[1] ?? human(r);

// ---------------------------------------------------------------- Team
export function Team({ biz }: { biz: Biz }) {
  const q = useOp<any[]>('biz.team');
  const rp = useOp<any[]>('biz.role_permissions');
  const { run, busy } = useAct();
  const [invite, setInvite] = useState(false);
  const [edit, setEdit] = useState<any>(null);
  const manage = can(biz, 'team.manage');
  return <>
    <PageHead title="Team" sub="Give each person only the access they need. Every change is recorded in the audit log."
      actions={manage && <button className="btn primary" onClick={() => setInvite(true)}>Invite a team member</button>} />
    <Card pad={false}><Gate q={q}>{(rows) => <Table rows={rows} cols={[
      { h: 'Member', c: (m) => <div><div><b>{m.display_name}</b></div><div className="small muted">@{m.username}</div></div> },
      { h: 'Role', c: (m) => <div>{roleLabel(m.role)}{Object.keys(m.overrides).length > 0 && <div className="small muted">{Object.keys(m.overrides).length} custom permission(s)</div>}</div> },
      { h: 'Status', c: (m) => <Status s={m.status} /> },
      { h: 'Joined', c: (m) => <span className="small">{m.joined_at ? fmtDate(m.joined_at, false) : `Invited ${ago(m.created_at)}${m.invited_by ? ' by @' + m.invited_by : ''}`}</span> },
      { h: '', right: true, c: (m) => manage && m.role !== 'owner' ? <button className="btn sm" onClick={() => setEdit(m)}>Manage</button> : null },
    ]} />}</Gate></Card>
    <Card title="What each role can do" pad={false}>
      <Gate q={rp}>{(rows) => { const perms = Object.keys(PERM_LABEL); const by = Object.fromEntries(rows.map((r) => [r.role, new Set(r.permissions)]));
        const order = ['owner', ...ROLES.map((r) => r[0])];
        return <div className="table-wrap"><table className="table"><thead><tr><th>Permission</th>{order.map((r) => <th key={r} style={{ textAlign: 'center' }}>{roleLabel(r)}</th>)}</tr></thead>
          <tbody>{perms.map((p) => <tr key={p}><td>{PERM_LABEL[p]}</td>{order.map((r) => <td key={r} style={{ textAlign: 'center' }} aria-label={by[r]?.has(p) ? 'yes' : 'no'}>{by[r]?.has(p) ? <span style={{ color: 'var(--green-strong)' }}>✓</span> : <span className="muted">·</span>}</td>)}</tr>)}</tbody></table></div>; }}</Gate>
    </Card>
    <InviteModal open={invite} onClose={() => setInvite(false)} />
    <Modal open={!!edit} onClose={() => setEdit(null)} title={edit ? `Manage @${edit.username}` : ''}>
      {edit && <MemberEditor m={edit} isOwner={biz.role === 'owner'} busy={busy} onSave={async (change) => { const r = await run('biz.update_member', { user_id: edit.user_id, change }, change.remove ? 'Member removed' : 'Access updated'); if (r) setEdit(null); }} />}
    </Modal>
  </>;
}

function InviteModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { run, busy } = useAct();
  const { sb, session } = useApp();
  const [u, setU] = useState(''); const [role, setRole] = useState('read_only'); const [who, setWho] = useState<any>(undefined);
  const look = async () => { const name = u.replace(/^@/, '').trim().toLowerCase(); if (!name) return setWho(undefined);
    try { setWho(await sb.run('biz.lookup_user', session, { username: name })); } catch { setWho(null); } };
  return <Modal open={open} onClose={onClose} title="Invite a team member">
    <div className="stack">
      <Field label="Knock username" hint="They accept the invite from their own Knock account." error={who === null ? 'No Knock user with that username.' : who && !who.verified ? 'They must verify their Knock account first.' : null}>
        <input className="input" value={u} onChange={(e) => { setU(e.target.value); setWho(undefined); }} onBlur={look} placeholder="@username" /></Field>
      {who && <div className="small" style={{ color: 'var(--green-strong)' }}>✓ {who.display_name}</div>}
      <Field label="Role">{ROLES.map(([k, l, d]) => <label key={k} className="check" style={{ alignItems: 'flex-start', marginBottom: 6 }}><input type="radio" name="role" checked={role === k} onChange={() => setRole(k)} /><span><b>{l}</b><div className="small muted">{d}</div></span></label>)}</Field>
      <div className="row"><div className="spacer" /><button className="btn" onClick={onClose}>Cancel</button>
        <button className="btn primary" disabled={busy || !who?.verified} onClick={async () => { const r = await run('biz.invite', { username: who.username, role }, `Invite sent to @${who.username}`); if (r) { onClose(); setU(''); setWho(undefined); } }}>Send invite</button></div>
    </div>
  </Modal>;
}

function MemberEditor({ m, isOwner, busy, onSave }: { m: any; isOwner: boolean; busy: boolean; onSave: (c: any) => void }) {
  const [role, setRole] = useState(m.role);
  const [ov, setOv] = useState<Record<string, boolean>>(m.overrides ?? {});
  const [rm, setRm] = useState(false);
  return <div className="stack">
    <Field label="Role"><select className="input" value={role} onChange={(e) => setRole(e.target.value)}>{ROLES.map(([k, l]) => <option key={k} value={k} disabled={!isOwner && k === 'administrator'}>{l}</option>)}</select></Field>
    {isOwner ? <div className="stack tight"><b>Custom permissions</b><div className="small muted">Override the role for this person only. Only the owner can do this.</div>
      {Object.entries(PERM_LABEL).map(([p, l]) => <div key={p} className="row small"><span style={{ flex: 1 }}>{l}</span>
        <select className="input" style={{ width: 130, padding: '3px 6px' }} value={p in ov ? String(ov[p]) : ''} onChange={(e) => { const n = { ...ov }; if (e.target.value === '') delete n[p]; else n[p] = e.target.value === 'true'; setOv(n); }}>
          <option value="">Role default</option><option value="true">Allow</option><option value="false">Deny</option></select></div>)}</div>
      : <div className="small muted">Only the owner can set custom permissions or manage administrators.</div>}
    <div className="row"><button className="btn danger" onClick={() => setRm(true)}>Remove from team</button><div className="spacer" />
      <button className="btn primary" disabled={busy} onClick={() => onSave(isOwner ? { role, permissions: ov } : { role })}>Save</button></div>
    {rm && <div className="notice bad">Remove @{m.username}? They lose access immediately. <button className="btn sm danger" disabled={busy} onClick={() => onSave({ remove: true })}>Yes, remove</button> <button className="btn sm" onClick={() => setRm(false)}>Cancel</button></div>}
  </div>;
}

// ---------------------------------------------------------------- Settings
export function Settings({ biz, tab }: { biz: Biz; tab?: string }) {
  const [, go] = useHash();
  const t = (tab ?? 'profile') as any;
  const q = useOp<any>('biz.settings');
  const tabs: [string, string][] = [['profile', 'Business profile'], ['verification', 'Verification'], ['notifications', 'Notifications'], ['payouts', 'Payout rules'], ['support', 'Support'], ...(can(biz, 'team.manage') ? [['audit', 'Audit log'] as [string, string]] : [])];
  return <>
    <PageHead title="Settings" sub={`@${biz.handle}`} />
    <Tabs value={t} onChange={(v) => go('settings/' + v)} options={tabs as any} />
    <div style={{ height: 16 }} />
    <Gate q={q}>{(s) => <>
      {t === 'profile' && <Profile biz={biz} s={s} />}
      {t === 'verification' && <Verification biz={biz} s={s} />}
      {t === 'notifications' && <Prefs biz={biz} s={s} />}
      {t === 'payouts' && <PayoutRules biz={biz} s={s} />}
      {t === 'support' && <Support />}
      {t === 'audit' && <Audit />}
    </>}</Gate>
  </>;
}

function Profile({ biz, s }: { biz: Biz; s: any }) {
  const { run, busy } = useAct();
  const cats = useOp<any[]>('me.categories', {}, { context: null });
  const locked = ['pending', 'under_review', 'verified'].includes(s.verification_status);
  const [f, setF] = useState({ legal_name: s.legal_name ?? '', trading_name: s.trading_name ?? '', description: s.description ?? '', category: s.category ?? '', email: s.email ?? '', phone: s.phone ?? '', website: s.website ?? '', registration_number: s.registration_number ?? '' });
  const set = (k: string) => (e: any) => setF({ ...f, [k]: e.target.value });
  const editable = can(biz, 'settings.manage');
  const save = () => { const c: any = { trading_name: f.trading_name, description: f.description, email: f.email, phone: f.phone, website: f.website };
    if (!locked) Object.assign(c, { legal_name: f.legal_name, category: f.category, registration_number: f.registration_number });
    run('biz.update_profile', { changes: c }, 'Profile saved'); };
  return <Card><div className="stack">
    {locked && <div className="notice">Legal details are locked while Knock reviews or after verification. Contact support to change them.{s.verification_status === 'verified' && ' Changing the contact email of a verified business is reviewed by Knock.'}</div>}
    <div className="grid g2">
      <Field label="Legal name"><input className="input" value={f.legal_name} onChange={set('legal_name')} disabled={locked || !editable} /></Field>
      <Field label="Trading name"><input className="input" value={f.trading_name} onChange={set('trading_name')} disabled={!editable} /></Field>
      <Field label="Category"><select className="input" value={f.category} onChange={set('category')} disabled={locked || !editable}>{(cats.data ?? []).map((c) => <option key={c.code} value={c.code}>{c.label}</option>)}</select></Field>
      <Field label="Registration number (CAC)"><input className="input" value={f.registration_number} onChange={set('registration_number')} disabled={locked || !editable} /></Field>
      <Field label="Contact email"><input className="input" type="email" value={f.email} onChange={set('email')} disabled={!editable} /></Field>
      <Field label="Phone"><input className="input" value={f.phone} onChange={set('phone')} disabled={!editable} /></Field>
      <Field label="Website"><input className="input" value={f.website} onChange={set('website')} disabled={!editable} /></Field>
      <Field label="Country"><input className="input" value={s.country} disabled /></Field>
    </div>
    <Field label="Description"><textarea className="input" rows={3} value={f.description} onChange={set('description')} disabled={!editable} maxLength={500} /></Field>
    {editable && <div className="row"><div className="spacer" /><button className="btn primary" disabled={busy} onClick={save}>Save changes</button></div>}
  </div></Card>;
}

async function sha256(file: File) {
  const buf = await crypto.subtle.digest('SHA-256', await file.arrayBuffer());
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

function Verification({ biz, s }: { biz: Biz; s: any }) {
  const { run, busy } = useAct();
  const [rep, setRep] = useState({ full_name: '', role_title: 'Director', ownership: '', email: '', username: '' });
  const ck = s.checklist;
  const editable = can(biz, 'verification.manage') && !['under_review', 'verified', 'restricted'].includes(s.verification_status);
  const upload = async (doc_type: string, file: File | undefined) => {
    if (!file) return;
    if (file.size > 10 * 1024 * 1024) return alertBad('Files must be 10 MB or smaller.');
    // Sandbox keeps only the file's metadata and SHA-256. Production uploads
    // the bytes to a private Supabase Storage bucket with a signed URL first.
    await run('biz.add_document', { doc: { doc_type, file_name: file.name, storage_path: `sandbox/${biz.id}/${doc_type}/${file.name}`, mime_type: file.type || 'application/octet-stream', size_bytes: file.size, sha256: await sha256(file) } }, 'Document added');
  };
  const { toast } = useApp();
  const alertBad = (m: string) => toast(m, true);
  return <div className="stack">
    <Card><div className="row wrap"><div><div className="small muted">Verification status</div><div style={{ marginTop: 4 }}><Status s={s.verification_status} /></div></div><div className="spacer" />
      {editable && <button className="btn primary" disabled={busy || !ck.ready || !ck.profile_complete} onClick={() => run('biz.submit_verification', {}, 'Submitted. Knock will review your business.')}>Submit for review</button>}</div>
      {s.verification_status === 'not_started' && <p className="muted small">Add the documents and people below, then submit. You can't collect money until Knock verifies the business.</p>}
      {s.verification_status === 'action_required' && <div className="notice warn" style={{ marginTop: 10 }}>Knock needs more information. See the note in the history below, update your documents and submit again.</div>}
      {s.verification_status === 'under_review' && <p className="muted small">Knock is reviewing your documents. You'll get a notification when it's done.</p>}
    </Card>
    <Card title="Documents" pad={false}><Table rows={ck.documents} cols={[
      { h: 'Document', c: (d: any) => <div>{d.label}{!d.required && <span className="small muted"> · optional</span>}</div> },
      { h: 'Status', c: (d: any) => d.doc_status ? <Status s={d.doc_status} /> : <span className="small muted">Not provided</span> },
      { h: '', right: true, c: (d: any) => editable ? <label className="btn sm">{d.provided ? 'Replace' : 'Upload'}<input type="file" hidden accept="application/pdf,image/png,image/jpeg" onChange={(e) => upload(d.doc_type, e.target.files?.[0])} /></label> : null },
    ]} /></Card>
    <Card title={`Representatives (${ck.representatives} of ${ck.representatives_required} required)`} pad={false}>
      <Table rows={s.representatives} cols={[{ h: 'Name', c: (r: any) => r.full_name }, { h: 'Role', c: (r: any) => r.role_title }, { h: 'Ownership', right: true, c: (r: any) => r.ownership_bps != null ? (r.ownership_bps / 100).toFixed(2) + '%' : '—' }]}
        empty={<div className="card-b muted">Add every director or owner with 25% or more.</div>} />
      {editable && <div className="card-b row wrap" style={{ borderTop: '1px solid var(--line)' }}>
        <input className="input" style={{ flex: 2, minWidth: 160 }} placeholder="Full legal name" value={rep.full_name} onChange={(e) => setRep({ ...rep, full_name: e.target.value })} />
        <input className="input" style={{ flex: 1, minWidth: 110 }} placeholder="Role" value={rep.role_title} onChange={(e) => setRep({ ...rep, role_title: e.target.value })} />
        <input className="input num" style={{ width: 100 }} placeholder="Owns %" value={rep.ownership} onChange={(e) => setRep({ ...rep, ownership: e.target.value })} />
        <input className="input" style={{ flex: 1, minWidth: 120 }} placeholder="@knock user (optional)" value={rep.username} onChange={(e) => setRep({ ...rep, username: e.target.value })} />
        <button className="btn" disabled={busy || rep.full_name.trim().length < 3} onClick={async () => { const r = await run('biz.add_representative', { rep: { full_name: rep.full_name.trim(), role_title: rep.role_title, ownership_bps: rep.ownership ? Math.round(Number(rep.ownership) * 100) : null, username: rep.username.replace(/^@/, '') || null } }, 'Representative added');
          if (r) setRep({ full_name: '', role_title: 'Director', ownership: '', email: '', username: '' }); }}>Add</button></div>}
    </Card>
    <Card title="History" pad={false}><Table rows={s.history} cols={[{ h: 'When', c: (h: any) => <span className="small">{fmtDate(h.at)}</span> }, { h: 'Status', c: (h: any) => <Status s={h.to} /> }, { h: 'Note from Knock', c: (h: any) => h.note ?? '' }]} empty={<div className="card-b muted">Nothing yet.</div>} /></Card>
  </div>;
}

const PREFS: [string, string][] = [['payments', 'Payment received'], ['payouts', 'Withdrawals and approvals'], ['deposits', 'Crypto deposits'], ['team', 'Team changes'], ['security', 'Security alerts']];
function Prefs({ biz, s }: { biz: Biz; s: any }) {
  const { run, busy } = useAct();
  const flags = useOp<any[]>('biz.flags');
  const emailOn = flags.data?.find((f) => f.key === 'notifications.email')?.enabled;
  const [p, setP] = useState<Record<string, { in_app: boolean; email: boolean }>>(() => Object.fromEntries(PREFS.map(([k]) => [k, { in_app: true, email: true, ...(s.notification_prefs?.[k] ?? {}) }])));
  return <Card><div className="stack">
    {!emailOn && <div className="notice">Email delivery is not connected yet, so only in-app notifications are sent for now. Your email choices are saved for when it is.</div>}
    <table className="table"><thead><tr><th>Event</th><th style={{ textAlign: 'center' }}>In app</th><th style={{ textAlign: 'center' }}>Email</th></tr></thead>
      <tbody>{PREFS.map(([k, l]) => <tr key={k}><td>{l}{k === 'security' && <div className="small muted">Always sent.</div>}</td>
        {(['in_app', 'email'] as const).map((ch) => <td key={ch} style={{ textAlign: 'center' }}><input type="checkbox" aria-label={`${l} ${ch}`} checked={k === 'security' || p[k][ch]} disabled={k === 'security' || !can(biz, 'settings.manage')} onChange={(e) => setP({ ...p, [k]: { ...p[k], [ch]: e.target.checked } })} /></td>)}</tr>)}</tbody></table>
    {can(biz, 'settings.manage') && <div className="row"><div className="spacer" /><button className="btn primary" disabled={busy} onClick={() => run('biz.update_profile', { changes: { notification_prefs: p } }, 'Preferences saved')}>Save</button></div>}
  </div></Card>;
}

function PayoutRules({ biz, s }: { biz: Biz; s: any }) {
  const { run, busy } = useAct();
  const [v, setV] = useState((Number(BigInt(s.payout_dual_approval_above ?? '0') / 100n)).toString());
  const owner = biz.role === 'owner' || biz.role === 'administrator';
  return <Card><div className="stack">
    <p>Withdrawals above this amount need a second team member with approval rights. Set it to 0 to require two people for every withdrawal.</p>
    <Field label="Second approval above (NGN)" hint={<>Current: <Money minor={s.payout_dual_approval_above} currency="NGN" /></>}><input className="input num" style={{ maxWidth: 220 }} value={v} onChange={(e) => setV(e.target.value.replace(/[^\d.]/g, ''))} disabled={!owner} /></Field>
    {owner ? <div className="row"><div className="spacer" /><button className="btn primary" disabled={busy || toMinor(v || '0', 'NGN') === null} onClick={() => run('biz.update_profile', { changes: { payout_dual_approval_above: toMinor(v || '0', 'NGN') ?? '0' } }, 'Payout rule saved')}>Save</button></div>
      : <div className="small muted">Only the owner or an administrator can change this.</div>}
  </div></Card>;
}

function Support() {
  const q = useOp<any[]>('biz.tickets');
  const { run, busy } = useAct();
  const [f, setF] = useState({ subject: '', category: 'payments', body: '', related_reference: '' });
  const [open, setOpen] = useState(false);
  return <div className="stack">
    <div className="row"><div className="spacer" /><button className="btn primary" onClick={() => setOpen(true)}>Contact Knock support</button></div>
    <Gate q={q} empty={<Card><Empty title="No support requests">Ask about a payment, a payout or your verification. Knock replies here.</Empty></Card>}>{(rows) => <div className="stack">{rows.map((t) =>
      <Card key={t.id} title={<span>{t.subject} <span className="small muted mono">{t.reference}</span></span>} actions={<Status s={t.status} />}>
        <div className="stack tight">{(t.messages ?? []).map((m: any, i: number) => <div key={i} className="card" style={{ padding: 10, background: m.author_kind === 'staff' ? 'var(--green-soft)' : undefined }}>
          <div className="small muted">{m.author_kind === 'staff' ? 'Knock support' : 'You'} · {ago(m.at)}</div><div>{m.body}</div></div>)}</div>
      </Card>)}</div>}</Gate>
    <Modal open={open} onClose={() => setOpen(false)} title="Contact Knock support"><div className="stack">
      <Field label="Subject"><input className="input" value={f.subject} maxLength={120} onChange={(e) => setF({ ...f, subject: e.target.value })} /></Field>
      <Field label="Topic"><select className="input" value={f.category} onChange={(e) => setF({ ...f, category: e.target.value })}>{['payments', 'withdrawals', 'verification', 'account', 'general'].map((c) => <option key={c} value={c}>{human(c)}</option>)}</select></Field>
      <Field label="Related reference (optional)"><input className="input mono" value={f.related_reference} onChange={(e) => setF({ ...f, related_reference: e.target.value })} /></Field>
      <Field label="Message" hint="Never share your PIN or password. Knock will never ask for them."><textarea className="input" rows={4} value={f.body} maxLength={4000} onChange={(e) => setF({ ...f, body: e.target.value })} /></Field>
      <div className="row"><div className="spacer" /><button className="btn" onClick={() => setOpen(false)}>Cancel</button>
        <button className="btn primary" disabled={busy || f.subject.trim().length < 3 || f.body.trim().length < 5} onClick={async () => { const r = await run('biz.open_ticket', { ticket: f }, 'Request sent'); if (r) { setOpen(false); setF({ subject: '', category: 'payments', body: '', related_reference: '' }); } }}>Send</button></div>
    </div></Modal>
  </div>;
}

function Audit() {
  const q = useOp<any[]>('biz.audit');
  return <Card pad={false}><Gate q={q} empty={<Empty title="No activity yet" />}>{(rows) => <Table rows={rows} cols={[
    { h: 'When', c: (a) => <span className="small">{fmtDate(a.at)}</span> }, { h: 'Who', c: (a) => a.actor ? '@' + a.actor : 'System' },
    { h: 'Action', c: (a) => human(a.action.replace(/^business\./, '')) },
    { h: 'Detail', c: (a) => <span className="small mono muted">{Object.entries(a.detail ?? {}).filter(([k]) => !/sha|secret|token/i.test(k)).map(([k, v]) => `${k}: ${typeof v === 'object' ? JSON.stringify(v) : v}`).join(' · ')}</span> },
  ]} />}</Gate></Card>;
}

// ---------------------------------------------------------------- Onboarding
export function Onboarding({ invites, first, onDone }: { invites: any[]; first: boolean; onDone: (id: string) => void }) {
  const { run, busy } = useAct();
  const cats = useOp<any[]>('me.categories', {}, { context: null });
  const me = useOp<any>('me.profile', {}, { context: null });
  const [f, setF] = useState({ handle: '', legal_name: '', trading_name: '', category: '', country: 'NG', email: '', phone: '', website: '', registration_number: '', description: '' });
  const set = (k: string) => (e: any) => setF({ ...f, [k]: e.target.value });
  const ok = /^[a-z0-9_]{3,30}$/.test(f.handle) && f.legal_name.trim().length >= 2 && f.category && /.+@.+\..+/.test(f.email);
  return <div className="stack" style={{ maxWidth: 760 }}>
    <PageHead title={first ? 'Set up Knock Business' : 'Add a business'} sub="Your business uses the same Knock account and security you already have. Each business gets its own balance, team and records." />
    {invites.length > 0 && <Card title="Invitations">{invites.map((i) => <div key={i.business_id} className="row" style={{ marginBottom: 8 }}>
      <div><b>{i.name}</b> invited you as <b>{roleLabel(i.role)}</b>{i.invited_by && <span className="muted"> · from @{i.invited_by}</span>}</div><div className="spacer" />
      <button className="btn sm" disabled={busy} onClick={() => run('me.respond_invite', { business_id: i.business_id, accept: false }, 'Invite declined')}>Decline</button>
      <button className="btn sm primary" disabled={busy} onClick={async () => { const r = await run('me.respond_invite', { business_id: i.business_id, accept: true }, `You joined ${i.name}`); if (r) onDone(i.business_id); }}>Accept</button></div>)}</Card>}
    {me.data && me.data.kyc_tier < 1 && <div className="notice warn">Verify your personal Knock account first. Business owners must be verified.</div>}
    <Card title="Business details"><div className="stack">
      <div className="grid g2">
        <Field label="Business handle" hint="Customers see this on your payment pages. Letters, numbers and _ only."><input className="input" value={f.handle} onChange={(e) => setF({ ...f, handle: e.target.value.toLowerCase().replace(/[^a-z0-9_]/g, '') })} placeholder="e.g. mamaputfoods" /></Field>
        <Field label="Country"><select className="input" value={f.country} onChange={set('country')}><option value="NG">Nigeria</option><option value="GH">Ghana</option></select></Field>
        <Field label="Legal name" hint="As on your registration certificate."><input className="input" value={f.legal_name} onChange={set('legal_name')} /></Field>
        <Field label="Trading name (optional)"><input className="input" value={f.trading_name} onChange={set('trading_name')} /></Field>
        <Field label="Category"><select className="input" value={f.category} onChange={set('category')}><option value="">Choose…</option>{(cats.data ?? []).map((c) => <option key={c.code} value={c.code}>{c.label}</option>)}</select></Field>
        <Field label="Registration number (optional)"><input className="input" value={f.registration_number} onChange={set('registration_number')} /></Field>
        <Field label="Business email"><input className="input" type="email" value={f.email} onChange={set('email')} /></Field>
        <Field label="Phone (optional)"><input className="input" value={f.phone} onChange={set('phone')} /></Field>
      </div>
      <Field label="What does the business do? (optional)"><textarea className="input" rows={2} value={f.description} onChange={set('description')} maxLength={500} /></Field>
      <div className="row"><span className="small muted">Next you'll add documents for verification.</span><div className="spacer" />
        <button className="btn primary" disabled={!ok || busy} onClick={async () => { const r = await run<any>('me.create_business', { business: f }, 'Business created'); if (r?.id) onDone(r.id); }}>Create business</button></div>
    </div></Card>
  </div>;
}

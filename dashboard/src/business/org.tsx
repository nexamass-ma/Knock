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

// "Complete your profile": shown across the dashboard until Knock verifies.
export function VerifyCard({ biz }: { biz: Biz }) {
  const q = useOp<any>('biz.settings');
  const s = q.data;
  if (!s) return null;
  const ck = s.checklist;
  const docsReq = ck.documents.filter((d: any) => d.required);
  const steps: [string, boolean, string][] = [
    ['Account created', true, ''],
    ['Registration details', ck.registration_complete, 'Business type and CAC number'],
    [`Documents (${docsReq.filter((d: any) => d.provided).length}/${docsReq.length})`, docsReq.every((d: any) => d.provided), 'CAC certificate, MEMAT, address, director ID'],
    [`Directors (${ck.representatives}/${ck.representatives_required})`, ck.representatives >= ck.representatives_required, 'One or two directors with NIN and BVN'],
    ['Knock review', s.verification_status === 'verified', s.verification_status === 'not_started' ? 'Submit when ready' : human(s.verification_status)],
  ];
  const submitted = ['pending', 'under_review'].includes(s.verification_status);
  const restricted = ['restricted', 'rejected'].includes(s.verification_status);
  return <div className={'card verify-card' + (restricted ? ' bad' : '')} style={{ marginBottom: 16 }}>
    <div className="row wrap" style={{ alignItems: 'flex-start' }}>
      <div style={{ flex: 1, minWidth: 240 }}>
        <b>{restricted ? 'Your business account is restricted' : submitted ? 'Verification submitted. Knock is reviewing your business.' : 'Complete your profile to start collecting money'}</b>
        <div className="small muted" style={{ marginTop: 4 }}>{submitted ? "We'll notify you when it's done. You can keep setting things up meanwhile." : restricted ? 'Contact support from Settings > Support.' : 'You can explore everything now. Payment links, deposits and withdrawals unlock once Knock verifies the business.'}</div>
      </div>
      {can(biz, 'verification.manage') && !submitted && <a className="btn primary" href="#/settings/verification">{s.verification_status === 'not_started' ? 'Complete verification' : 'Continue verification'}</a>}
    </div>
    <ol className="vsteps">{steps.map(([t, done, sub]) => <li key={t} className={done ? 'done' : ''}><span className="dot" aria-hidden>{done ? '✓' : ''}</span><div><div className="small"><b>{t}</b></div>{sub && <div className="small muted">{sub}</div>}</div></li>)}</ol>
  </div>;
}

const ENTITY: [string, string, string][] = [
  ['business_name', 'Business name (BN)', 'Sole proprietor or partnership registered with CAC'],
  ['limited_company', 'Limited company (RC)', 'Ltd or PLC; MEMAT required'],
  ['incorporated_trustees', 'Incorporated trustees (IT)', 'NGOs, associations, churches'],
];

function Verification({ biz, s }: { biz: Biz; s: any }) {
  const { run, busy } = useAct();
  const { toast } = useApp();
  const ck = s.checklist;
  const editable = can(biz, 'verification.manage') && ['not_started', 'info_required', 'action_required', 'rejected'].includes(s.verification_status);
  const [reg, setReg] = useState({ entity_type: s.entity_type ?? '', registration_number: s.registration_number ?? '', legal_name: s.legal_name ?? '' });
  const blank = { full_name: '', role_title: 'Director', date_of_birth: '', phone: '', email: '', nin: '', bvn: '', ownership: '' };
  const [d, setD] = useState(blank);
  const [adding, setAdding] = useState(false);
  const setd = (k: keyof typeof blank) => (e: any) => setD({ ...d, [k]: k === 'nin' || k === 'bvn' ? e.target.value.replace(/\D/g, '').slice(0, 11) : e.target.value });
  const upload = async (doc_type: string, file: File | undefined) => {
    if (!file) return;
    if (file.size > 10 * 1024 * 1024) return toast('Files must be 10 MB or smaller.', true);
    // Sandbox keeps only the file's metadata and SHA-256. Production uploads
    // the bytes to a private Supabase Storage bucket with a signed URL first.
    await run('biz.add_document', { doc: { doc_type, file_name: file.name, storage_path: `sandbox/${biz.id}/${doc_type}/${file.name}`, mime_type: file.type || 'application/octet-stream', size_bytes: file.size, sha256: await sha256(file) } }, 'Document added');
  };
  const dirOk = d.full_name.trim().split(/\s+/).length >= 2 && d.nin.length === 11 && d.bvn.length === 11 && d.date_of_birth && /^\+?[0-9 ]{10,16}$/.test(d.phone);
  const full = ck.representatives >= ck.representatives_max;
  return <div className="stack">
    <VerifyCard biz={biz} />
    <Card title="1. Registration details">
      {editable ? <div className="stack">
        <div className="methods three">{ENTITY.map(([k, l, h]) => <label key={k} className={'method' + (reg.entity_type === k ? ' on' : '')}>
          <input type="radio" name="entity" checked={reg.entity_type === k} onChange={() => setReg({ ...reg, entity_type: k })} /><span><b>{l}</b><br /><span className="small muted">{h}</span></span></label>)}</div>
        <div className="grid g2">
          <Field label="CAC number" hint="As on your certificate, e.g. RC1234567 or BN1234567."><input className="input mono" value={reg.registration_number} onChange={(e) => setReg({ ...reg, registration_number: e.target.value.toUpperCase() })} /></Field>
          <Field label="Registered name" hint="Exactly as on your CAC certificate."><input className="input" value={reg.legal_name} onChange={(e) => setReg({ ...reg, legal_name: e.target.value })} /></Field>
        </div>
        <div className="row"><span className="small muted">{ck.registration_complete ? '✓ Saved' : 'Not saved yet'}</span><div className="spacer" />
          <button className="btn primary" disabled={busy || !reg.entity_type || reg.registration_number.trim().length < 5} onClick={() => run('biz.set_registration', { registration: reg }, 'Registration details saved')}>Save details</button></div>
      </div> : <div className="kv small"><div>Type</div><div>{ENTITY.find((e) => e[0] === s.entity_type)?.[1] ?? '—'}</div><div>CAC number</div><div className="mono">{s.registration_number ?? '—'}</div><div>Registered name</div><div>{s.legal_name}</div></div>}
    </Card>
    <Card title="2. Documents" pad={false}>
      {!ck.registration_complete && <div className="notice" style={{ margin: 12 }}>Save your registration details first: the documents you need depend on how the business is registered.</div>}
      <Table rows={ck.documents} cols={[
        { h: 'Document', c: (x: any) => <div>{x.label}{!x.required && <span className="small muted"> · optional</span>}</div> },
        { h: 'Status', c: (x: any) => x.doc_status ? <Status s={x.doc_status} /> : <span className="small muted">Not provided</span> },
        { h: '', right: true, c: (x: any) => editable ? <label className="btn sm">{x.provided ? 'Replace' : 'Upload'}<input type="file" hidden accept="application/pdf,image/png,image/jpeg" onChange={(e) => upload(x.doc_type, e.target.files?.[0])} /></label> : null },
      ]} />
      <div className="card-b small muted" style={{ borderTop: '1px solid var(--line)' }}>PDF, PNG or JPG, up to 10 MB each. Stored privately; only Knock's verification team can open them.</div>
    </Card>
    <Card title={`3. Directors (${ck.representatives} of ${ck.representatives_required}${ck.representatives_max > ck.representatives_required ? `, up to ${ck.representatives_max}` : ''})`} pad={false}
      actions={editable && !full && !adding && <button className="btn sm primary" onClick={() => setAdding(true)}>Add director</button>}>
      <Table rows={s.representatives} cols={[
        { h: 'Director', c: (r: any) => <div><b>{r.full_name}</b><div className="small muted">{r.role_title}{r.ownership_bps != null ? ` · owns ${(r.ownership_bps / 100).toFixed(0)}%` : ''}</div></div> },
        { h: 'NIN', c: (r: any) => r.nin_last4 ? <span className="mono small">•••••••{r.nin_last4}</span> : <span className="small muted">Missing</span> },
        { h: 'BVN', c: (r: any) => r.bvn_last4 ? <span className="mono small">•••••••{r.bvn_last4}</span> : <span className="small muted">Missing</span> },
        { h: 'Identity check', c: (r: any) => <Status s={r.identity_check === 'awaiting_provider' ? 'pending' : r.identity_check} label={r.identity_check === 'awaiting_provider' ? 'Awaiting check' : undefined} /> },
        { h: '', right: true, c: (r: any) => editable ? <button className="btn sm ghost" disabled={busy} onClick={() => run('biz.remove_representative', { representative_id: r.id }, 'Director removed')}>Remove</button> : null },
      ]} empty={<div className="card-b muted">Add one or two directors as shown on your CAC records. Each needs their NIN and BVN.</div>} />
      {adding && <div className="card-b stack" style={{ borderTop: '1px solid var(--line)' }}>
        <div className="grid g2">
          <Field label="Full legal name"><input className="input" value={d.full_name} onChange={setd('full_name')} autoFocus /></Field>
          <Field label="Role"><input className="input" value={d.role_title} onChange={setd('role_title')} /></Field>
          <Field label="Date of birth"><input className="input" type="date" value={d.date_of_birth} onChange={setd('date_of_birth')} /></Field>
          <Field label="Phone"><input className="input" type="tel" value={d.phone} onChange={setd('phone')} placeholder="+234 803 000 0000" /></Field>
          <Field label="NIN" hint="11 digits" error={d.nin && d.nin.length !== 11 ? 'NIN is 11 digits' : null}><input className="input mono" inputMode="numeric" autoComplete="off" value={d.nin} onChange={setd('nin')} /></Field>
          <Field label="BVN" hint="11 digits. Dial *565*0# to check." error={d.bvn && d.bvn.length !== 11 ? 'BVN is 11 digits' : null}><input className="input mono" inputMode="numeric" autoComplete="off" value={d.bvn} onChange={setd('bvn')} /></Field>
          <Field label="Email (optional)"><input className="input" type="email" value={d.email} onChange={setd('email')} /></Field>
          <Field label="Ownership % (optional)"><input className="input num" value={d.ownership} onChange={(e) => setD({ ...d, ownership: e.target.value.replace(/[^\d.]/g, '') })} /></Field>
        </div>
        <div className="small muted">Knock checks NIN and BVN with an identity provider and keeps only the last 4 digits and the result. We never show these numbers in full.</div>
        <div className="row"><div className="spacer" /><button className="btn ghost" onClick={() => { setAdding(false); setD(blank); }}>Cancel</button>
          <button className="btn primary" disabled={busy || !dirOk} onClick={async () => {
            const r = await run('biz.add_director', { director: { full_name: d.full_name, role_title: d.role_title, date_of_birth: d.date_of_birth, phone: d.phone, email: d.email, nin: d.nin, bvn: d.bvn, ownership_bps: d.ownership ? Math.round(Number(d.ownership) * 100) : null } }, 'Director added');
            if (r) { setD(blank); setAdding(false); }
          }}>Save director</button></div>
      </div>}
    </Card>
    <Card title="4. Submit for review">
      <div className="row wrap"><div style={{ flex: 1 }}><div className="small muted">Status</div><div style={{ marginTop: 4 }}><Status s={s.verification_status} /></div>
        {['info_required', 'action_required'].includes(s.verification_status) && <div className="notice warn" style={{ marginTop: 10 }}>Knock needs more information. See the note in the history below, update your details and submit again.</div>}
        {s.verification_status === 'pending' && <p className="muted small">Submitted. Knock usually reviews within 1 to 2 business days.</p>}</div>
        {editable && <button className="btn primary" disabled={busy || !ck.ready} onClick={() => run('biz.submit_verification', {}, 'Submitted. Knock will review your business.')}>Submit for review</button>}</div>
      {editable && !ck.ready && <div className="small muted" style={{ marginTop: 8 }}>Finish steps 1 to 3 to submit.</div>}
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
  const [f, setF] = useState({ handle: '', legal_name: '', trading_name: '', category: '', country: 'NG', email: '', phone: '', website: '', registration_number: '', description: '' });
  const set = (k: string) => (e: any) => setF({ ...f, [k]: e.target.value });
  const ok = /^[a-z0-9_]{3,30}$/.test(f.handle) && f.legal_name.trim().length >= 2 && f.category && /.+@.+\..+/.test(f.email);
  return <div className="stack" style={{ maxWidth: 760 }}>
    <PageHead title={first ? 'Set up Knock Business' : 'Add a business'} sub="Your business uses the same Knock account and security you already have. Each business gets its own balance, team and records." />
    {invites.length > 0 && <Card title="Invitations">{invites.map((i) => <div key={i.business_id} className="row" style={{ marginBottom: 8 }}>
      <div><b>{i.name}</b> invited you as <b>{roleLabel(i.role)}</b>{i.invited_by && <span className="muted"> · from @{i.invited_by}</span>}</div><div className="spacer" />
      <button className="btn sm" disabled={busy} onClick={() => run('me.respond_invite', { business_id: i.business_id, accept: false }, 'Invite declined')}>Decline</button>
      <button className="btn sm primary" disabled={busy} onClick={async () => { const r = await run('me.respond_invite', { business_id: i.business_id, accept: true }, `You joined ${i.name}`); if (r) onDone(i.business_id); }}>Accept</button></div>)}</Card>}
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

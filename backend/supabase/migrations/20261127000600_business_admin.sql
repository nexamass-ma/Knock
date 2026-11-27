-- KNOCK Business: staff actions used by the admin dashboard, support tickets.
-- Additive. Every function checks the staff permission and MFA level first.
set search_path = knock, public;

-- Link review by risk/compliance staff (the older set_link_status only knows
-- the 'compliance'/'admin' roles).
create or replace function knock.staff_link_review(p_staff uuid, p_aal text, p_link uuid, p_action text, p_note text) returns text
language plpgsql as $$
declare v_link knock.payment_links; v_new text; v_pay uuid;
begin
  perform knock.require_staff_perm(p_staff, 'links.review', p_aal);
  select * into v_link from knock.payment_links where id = p_link for update;
  if not found then perform knock.fail('not_found', 'link not found'); end if;
  if p_action = 'review' then
    if v_link.status in ('closed','under_review') then perform knock.fail('invalid_state', 'link is ' || v_link.status); end if;
    if coalesce(trim(p_note), '') = '' then perform knock.fail('note_required', 'say why the link is under review'); end if;
    v_new := 'under_review';
  elsif p_action = 'clear_review' then
    if v_link.status <> 'under_review' then perform knock.fail('invalid_state', 'link is not under review'); end if;
    v_new := 'active';
  else
    perform knock.fail('bad_request', 'unknown action');
  end if;
  update knock.payment_links set status = v_new, updated_at = now() where id = p_link;
  perform knock.saudit(p_staff, 'link.' || p_action, case when exists (select 1 from knock.businesses where id = v_link.creator_id) then v_link.creator_id end,
                       jsonb_build_object('link_id', p_link, 'note', p_note, 'from', v_link.status));
  perform knock.notify(v_link.creator_id, 'link_review', case when v_new = 'under_review' then 'Payment link paused for review' else 'Payment link active again' end,
    format('"%s" (%s) is %s.', v_link.title, v_link.reference, case when v_new = 'under_review' then 'under review; payments are held' else 'active again' end), p_link, null);
  if p_action = 'clear_review' and v_link.settlement_mode = 'each_payment' then
    for v_pay in select id from knock.payments where link_id = p_link and status = 'succeeded' and distribution_status = 'held' loop
      perform knock.try_distribute(v_pay, p_staff);
    end loop;
  end if;
  return v_new;
end $$;

create or replace function knock.staff_set_flag(p_staff uuid, p_aal text, p_key text, p_enabled boolean) returns void
language plpgsql as $$
begin
  perform knock.require_staff_perm(p_staff, 'settings.manage', p_aal);
  update knock.feature_flags set enabled = p_enabled, updated_by = p_staff, updated_at = now() where key = p_key;
  if not found then perform knock.fail('not_found', 'unknown flag'); end if;
  perform knock.saudit(p_staff, 'feature_flag.' || case when p_enabled then 'enabled' else 'disabled' end, null, jsonb_build_object('key', p_key));
end $$;

create or replace function knock.staff_ack_alert(p_staff uuid, p_aal text, p_alert uuid) returns void
language plpgsql as $$
begin
  perform knock.require_staff_perm(p_staff, 'notifications.view', p_aal);
  update knock.admin_alerts set acknowledged_by = p_staff, acknowledged_at = now() where id = p_alert and acknowledged_at is null;
  perform knock.saudit(p_staff, 'alert.acknowledged', null, jsonb_build_object('alert_id', p_alert));
end $$;

-- Support: a business member (support permission not needed: any active
-- member can ask for help) opens a ticket; staff reply.
create or replace function knock.business_open_ticket(p_user uuid, p_business uuid, p jsonb) returns jsonb
language plpgsql as $$
declare v_id uuid; v_ref text;
begin
  perform knock.require_business(p_user, p_business, 'dashboard.view');
  insert into knock.support_tickets (holder_id, opened_by, subject, category, priority, related_reference)
  values (p_business, p_user, p->>'subject', coalesce(p->>'category', 'general'),
          case when p->>'priority' in ('low','normal','high') then p->>'priority' else 'normal' end, nullif(p->>'related_reference', ''))
  returning id, reference into v_id, v_ref;
  insert into knock.support_messages (ticket_id, author_id, author_kind, body) values (v_id, p_user, 'customer', p->>'body');
  perform knock.baudit(p_user, p_business, 'support.ticket.opened', jsonb_build_object('ticket', v_ref));
  return jsonb_build_object('id', v_id, 'reference', v_ref);
end $$;

create or replace function knock.staff_ticket_reply(p_staff uuid, p_aal text, p_ticket uuid, p jsonb) returns void
language plpgsql as $$
declare t record;
begin
  perform knock.require_staff_perm(p_staff, 'support.manage', p_aal);
  select * into t from knock.support_tickets where id = p_ticket for update;
  if not found then perform knock.fail('not_found', 'ticket not found'); end if;
  if coalesce(p->>'body', '') <> '' then
    insert into knock.support_messages (ticket_id, author_id, author_kind, body, internal)
    values (p_ticket, p_staff, 'staff', p->>'body', coalesce((p->>'internal')::boolean, false));
    if not coalesce((p->>'internal')::boolean, false) then
      perform knock.notify(t.holder_id, 'support', 'Support replied', 'There is a new reply on ' || t.reference || '.', null, null, jsonb_build_object('ticket', t.reference));
    end if;
  end if;
  update knock.support_tickets set
    status = coalesce(p->>'status', status),
    assigned_to = case when p ? 'assign_to_me' then p_staff else assigned_to end,
    updated_at = now()
  where id = p_ticket;
  perform knock.saudit(p_staff, 'support.ticket.updated', case when exists (select 1 from knock.businesses where id = t.holder_id) then t.holder_id end,
                       jsonb_build_object('ticket', t.reference, 'status', p->>'status', 'internal', p->>'internal'));
end $$;

-- Business-side notification read state.
create or replace function knock.business_mark_notifications_read(p_user uuid, p_business uuid) returns int
language plpgsql as $$
declare n int;
begin
  perform knock.require_business(p_user, p_business, 'dashboard.view');
  update knock.notifications set read_at = now() where user_id = p_business and read_at is null;
  get diagnostics n = row_count;
  return n;
end $$;

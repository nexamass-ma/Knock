// Reconciliation between Knock's records and the provider's. It only REPORTS:
// every difference becomes a provider_reconciliation_records row for Finance.
// It never changes balances or statuses to make the two sides agree.
import type { Db } from '../db.ts';
import { toJson } from './json.ts';
import type { CryptoProvider, Page } from './provider.ts';

interface Finding {
  check: string;
  kind: string;
  ref: string;
  expected: unknown;
  actual: unknown;
}

export class Reconciler {
  private db: Db;
  private provider: CryptoProvider;
  private pageSize: number;
  private maxPages: number;
  constructor(db: Db, provider: CryptoProvider, opts: { pageSize?: number; maxPages?: number } = {}) {
    this.db = db;
    this.provider = provider;
    this.pageSize = opts.pageSize ?? 100;
    this.maxPages = opts.maxPages ?? 1000;
  }

  /** Read every page; never assume page one is complete. */
  private async all<T>(fetch: (page: number, size: number) => Promise<Page<T>>, onPage: () => void) {
    const out: T[] = [];
    for (let page = 1; page <= this.maxPages; page++) {
      const p = await fetch(page, this.pageSize);
      onPage();
      out.push(...p.items);
      if (!p.hasNextPage || p.items.length === 0) break;
    }
    return out;
  }

  async run(trigger: 'scheduled' | 'manual', requestedBy: string | null = null, scope: 'full' | 'deposits' | 'withdrawals' | 'addresses' | 'ledger' = 'full') {
    const prov = this.provider.name;
    const [run] = await this.db.query<{ id: string }>(
      `insert into knock.provider_reconciliation_runs (provider, scope, trigger, requested_by) values ($1,$2,$3,$4) returning id`, [prov, scope, trigger, requestedBy]);
    let pages = 0;
    let records = 0;
    const findings: Finding[] = [];
    try {
      if (scope === 'full' || scope === 'deposits') {
        const remote = await this.all((p, s) => this.provider.listDeposits(p, s), () => pages++);
        records += remote.length;
        const local = new Map((await this.db.query<any>('select * from knock.crypto_deposits where provider = $1', [prov])).map((d) => [d.provider_trade_id, d]));
        for (const r of remote) {
          const l = local.get(r.tradeId);
          if (r.status === 'completed' && (!l || l.status !== 'completed')) {
            findings.push({ check: 'deposit_completed_not_credited', kind: 'deposit', ref: r.tradeId, expected: { status: 'completed', amount: r.amountCredited, currency: r.currency }, actual: l ? { status: l.status } : null });
          } else if (l && l.status === 'completed' && r.status !== 'completed') {
            findings.push({ check: 'deposit_credited_not_completed', kind: 'deposit', ref: r.tradeId, expected: { status: r.status }, actual: { status: l.status, credited_minor: l.credited_minor } });
          }
          if (l && l.status === 'completed' && r.status === 'completed' && l.sub_status !== 'settled_in_batch') {
            if (r.amountCredited && l.amount_credited !== null && Number(r.amountCredited) !== Number(l.amount_credited)) {
              findings.push({ check: 'deposit_amount_mismatch', kind: 'deposit', ref: r.tradeId, expected: r.amountCredited, actual: l.amount_credited });
            }
            if (r.currency && l.credited_currency && r.currency !== l.credited_currency) {
              findings.push({ check: 'deposit_currency_mismatch', kind: 'deposit', ref: r.tradeId, expected: r.currency, actual: l.credited_currency });
            }
          }
          if (l && r.status === 'failed' && l.status !== 'failed' && l.status !== 'completed') {
            findings.push({ check: 'deposit_state_mismatch', kind: 'deposit', ref: r.tradeId, expected: r.status, actual: l.status });
          }
          local.delete(r.tradeId);
        }
        if (scope === 'full' || scope === 'deposits') {
          for (const l of local.values()) findings.push({ check: 'deposit_missing_at_provider', kind: 'deposit', ref: l.provider_trade_id, expected: null, actual: { status: l.status } });
        }
      }

      if (scope === 'full' || scope === 'withdrawals') {
        const remote = await this.all((p, s) => this.provider.listWithdrawals(p, s), () => pages++);
        records += remote.length;
        const local = await this.db.query<any>('select * from knock.provider_withdrawals where provider = $1', [prov]);
        const byPid = new Map(local.filter((w) => w.provider_withdrawal_id).map((w) => [w.provider_withdrawal_id, w]));
        const byRef = new Map(local.map((w) => [w.knock_reference, w]));
        const seenExternal = new Map<string, string[]>();
        for (const r of remote) {
          if (r.externalId) seenExternal.set(r.externalId, [...(seenExternal.get(r.externalId) ?? []), r.id]);
          const l = byPid.get(r.id) ?? (r.externalId ? byRef.get(r.externalId) : undefined);
          if (!l) {
            // Payouts started from the provider dashboard, or auto-settlements not yet seen.
            if (!r.trade) findings.push({ check: 'withdrawal_unknown_to_knock', kind: 'withdrawal', ref: r.id, expected: null, actual: { status: r.status, amount: r.amount, currency: r.currency } });
            continue;
          }
          const lt = ['completed', 'reversed', 'rejected'].includes(l.status);
          const rt = ['completed', 'reversed', 'rejected'].includes(r.status);
          if ((lt || rt) && l.status !== r.status) {
            findings.push({ check: 'withdrawal_state_mismatch', kind: 'withdrawal', ref: r.id, expected: r.status, actual: l.status });
          }
        }
        for (const [ext, ids] of seenExternal) {
          if (ids.length > 1) findings.push({ check: 'duplicate_payout', kind: 'withdrawal', ref: ext, expected: 1, actual: ids });
        }
        for (const l of local) {
          if (l.status === 'submission_unknown') findings.push({ check: 'withdrawal_submission_unresolved', kind: 'withdrawal', ref: l.knock_reference, expected: 'resolved', actual: l.status });
        }
      }

      if (scope === 'full' || scope === 'addresses') {
        const remote = await this.all((p, s) => this.provider.listAddresses(p, s), () => pages++);
        records += remote.length;
        const known = new Set((await this.db.query<any>('select provider_address_id from knock.provider_wallet_addresses where provider = $1 and provider_address_id is not null', [prov])).map((r) => r.provider_address_id));
        for (const r of remote) if (!known.has(r.providerAddressId)) findings.push({ check: 'address_missing_in_knock', kind: 'address', ref: r.providerAddressId, expected: { label: r.label, asset: r.asset }, actual: null });
      }

      if (scope === 'full' || scope === 'ledger') findings.push(...(await this.ledgerChecks()));

      let opened = 0;
      for (const f of findings) {
        const fp = `${prov}:${f.check}:${f.ref}`;
        const ins = await this.db.query(
          `insert into knock.provider_reconciliation_records (run_id, provider, check_name, subject_kind, subject_ref, expected, actual, fingerprint)
           values ($1,$2,$3,$4,$5,$6,$7,$8) on conflict (fingerprint) where status <> 'resolved' do update set updated_at = now() returning (xmax = 0) as inserted`,
          [run.id, prov, f.check, f.kind, f.ref, toJson(f.expected ?? null), toJson(f.actual ?? null), fp]);
        if ((ins[0] as any)?.inserted) opened++;
      }
      await this.db.query(`update knock.provider_reconciliation_runs set status = 'completed', pages_read = $2, provider_records = $3, discrepancies = $4, finished_at = now() where id = $1`,
        [run.id, pages, records, findings.length]);
      return { runId: run.id, pages, records, discrepancies: findings, newRecords: opened };
    } catch (e) {
      await this.db.query(`update knock.provider_reconciliation_runs set status = 'failed', error = $2, pages_read = $3, finished_at = now() where id = $1`,
        [run.id, String((e as Error).message ?? e).slice(0, 500), pages]);
      throw e;
    }
  }

  /** Knock-internal consistency of the crypto ledger. */
  private async ledgerChecks(): Promise<Finding[]> {
    const prov = this.provider.name;
    const out: Finding[] = [];
    // Each completed (non-batch) deposit credited exactly its amount, once.
    for (const r of await this.db.query<any>(
      `select d.provider_trade_id, d.credited_minor, count(e.id) as entries,
              coalesce(sum(l.amount) filter (where a.purpose = 'provider_wallet'), 0) as wallet_debit
       from knock.crypto_deposits d
       left join knock.journal_entries e on e.idempotency_key = 'crypto:' || d.provider || ':deposit:' || d.provider_trade_id || ':credit'
       left join knock.journal_lines l on l.entry_id = e.id left join knock.ledger_accounts a on a.id = l.account_id
       where d.provider = $1 and d.status = 'completed' and coalesce(d.sub_status, '') <> 'settled_in_batch'
       group by d.id having count(distinct e.id) <> 1 or coalesce(sum(l.amount) filter (where a.purpose = 'provider_wallet'), 0) <> d.credited_minor`, [prov])) {
      out.push({ check: 'deposit_ledger_mismatch', kind: 'deposit', ref: r.provider_trade_id, expected: r.credited_minor, actual: r.wallet_debit });
    }
    // Pending / flagged / failed deposits must have no credit.
    for (const r of await this.db.query<any>(
      `select d.provider_trade_id from knock.crypto_deposits d join knock.journal_entries e on e.idempotency_key = 'crypto:' || d.provider || ':deposit:' || d.provider_trade_id || ':credit'
       where d.provider = $1 and d.status <> 'completed'`, [prov])) {
      out.push({ check: 'uncompleted_deposit_credited', kind: 'deposit', ref: r.provider_trade_id, expected: 0, actual: 'credited' });
    }
    // Withdrawal-reserved balances equal in-flight customer withdrawals.
    for (const r of await this.db.query<any>(
      `with inflight as (select user_id, currency, sum(amount_minor + knock_fee_minor) as amt from knock.provider_withdrawals
                         where provider = $1 and purpose = 'customer' and status in ('reserved','submitting','submission_unknown','pending','processing') group by 1,2),
            bal as (select owner_id as user_id, currency, balance from knock.account_balances where purpose = 'user_withdrawal_reserved')
       select coalesce(i.user_id, b.user_id) as user_id, coalesce(i.currency, b.currency) as currency, coalesce(i.amt,0) as expected, coalesce(b.balance,0) as actual
       from inflight i full join bal b on b.user_id = i.user_id and b.currency = i.currency
       where coalesce(i.amt,0) <> coalesce(b.balance,0)`, [prov])) {
      out.push({ check: 'withdrawal_reserve_mismatch', kind: 'ledger', ref: `${r.user_id}:${r.currency}`, expected: r.expected, actual: r.actual });
    }
    // Settlement-reserved balances equal open settlements (never also spendable).
    for (const r of await this.db.query<any>(
      `with open as (select user_id, currency, sum(reserved_minor) as amt from knock.settlements where provider = $1
                     and status in ('awaiting_payout','processing','failed_to_start','needs_review') group by 1,2),
            bal as (select owner_id as user_id, currency, balance from knock.account_balances where purpose = 'user_settlement_reserved')
       select coalesce(o.user_id, b.user_id) as user_id, coalesce(o.currency, b.currency) as currency, coalesce(o.amt,0) as expected, coalesce(b.balance,0) as actual
       from open o full join bal b on b.user_id = o.user_id and b.currency = o.currency where coalesce(o.amt,0) <> coalesce(b.balance,0)`, [prov])) {
      out.push({ check: 'settlement_reserve_mismatch', kind: 'ledger', ref: `${r.user_id}:${r.currency}`, expected: r.expected, actual: r.actual });
    }
    // Non-zero settlement variance needs a Finance explanation.
    for (const r of await this.db.query<any>(`select b.currency, b.balance from knock.account_balances b join knock.ledger_accounts a on a.id = b.account_id where a.purpose = 'settlement_variance' and a.provider = $1 and b.balance <> 0`, [prov])) {
      out.push({ check: 'settlement_variance', kind: 'ledger', ref: r.currency, expected: 0, actual: r.balance });
    }
    for (const r of await this.db.query<any>(`select id, trade_id, status from knock.settlement_exceptions where provider = $1 and status <> 'resolved'`, [prov])) {
      out.push({ check: 'settlement_failed_open', kind: 'settlement', ref: r.trade_id, expected: 'resolved', actual: r.status });
    }
    for (const r of await this.db.query<any>(`select check_name, coalesce(payment_id::text, link_id::text, '') as ref, expected, actual from knock.reconcile(null) where check_name in ('entry_balanced','negative_balance')`)) {
      out.push({ check: 'ledger_' + r.check_name, kind: 'ledger', ref: r.ref, expected: r.expected, actual: r.actual });
    }
    return out;
  }
}

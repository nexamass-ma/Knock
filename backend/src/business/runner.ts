// Runs one catalogue op inside one transaction: permission guard first, then
// the op's SQL with bound parameters. Shared by the HTTP API and the sandbox.
// No Node imports: the browser bundles this file too.
import { OPS, bindParams, guardSql, shapeResult, type Op } from './ops.ts';

export type Query = (sql: string, params: unknown[]) => Promise<any[]>;
export interface Identity { userId: string; context?: string | null }

export class OpError extends Error {
  code: string;
  constructor(code: string, message: string) { super(message); this.code = code; }
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function getOp(name: string): Op {
  const op = Object.prototype.hasOwnProperty.call(OPS, name) ? OPS[name] : undefined;
  if (!op) throw new OpError('not_found', 'unknown operation');
  return op;
}

/** `q` must run every statement in the SAME transaction (the caller opens and commits it). */
export async function runOp(q: Query, name: string, identity: Identity, input: Record<string, unknown> = {}) {
  const op = getOp(name);
  if (op.scope !== 'public' && !UUID.test(identity.userId)) throw new OpError('unauthenticated', 'sign in first');
  if (op.scope === 'business' && !(identity.context && UUID.test(identity.context))) throw new OpError('bad_request', 'choose a business');
  let params: unknown[];
  try { params = bindParams(op, identity, input); } catch (e: any) {
    const m = /^([a-z_]+): (.*)$/.exec(String(e.message));
    throw new OpError(m?.[1] ?? 'bad_request', m?.[2] ?? 'bad input');
  }
  const g = guardSql(op);
  if (g) await q(g.sql, g.params(identity));
  // Declare the identity parameters' types once, so ops that do not use them
  // still bind cleanly (an unreferenced CTE is never evaluated).
  const ctx = op.scope === 'me' ? '$1::uuid' : op.scope === 'business' ? '$1::uuid, $2::uuid' : op.scope === 'admin' ? '$1::uuid, $2::text' : '';
  const sql = ctx ? `with _ctx as (select ${ctx}) ${op.sql}` : op.sql;
  return shapeResult(op, await q(sql, params));
}

import { PGlite } from '@electric-sql/pglite';
import { Sandbox } from './sandbox.ts';
import { seed } from './seed.ts';

const files = import.meta.glob('../../../backend/supabase/migrations/*.sql', { query: '?raw', import: 'default', eager: true }) as Record<string, string>;
export const MIGRATIONS = Object.keys(files).sort().map((k) => ({ name: k.split('/').pop()!, sql: files[k] }));

let booting: Promise<Sandbox> | null = null;
export function boot(onProgress?: (msg: string) => void): Promise<Sandbox> {
  if (!booting) booting = (async () => {
    onProgress?.('Starting Postgres in your browser');
    const db = new PGlite();
    await db.waitReady;
    for (const m of MIGRATIONS) { onProgress?.('Applying ' + m.name); await db.exec(m.sql); }
    const sb = new Sandbox(db);
    onProgress?.('Creating sandbox records through the engine');
    await seed(sb);
    return sb;
  })();
  return booting;
}

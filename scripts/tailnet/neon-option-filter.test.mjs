import test from 'node:test';
import assert from 'node:assert/strict';
import {Readable} from 'node:stream';
import {cleanDdlLine, NeonOptionFilter} from './neon-option-filter.mjs';

test('removes the Neon-only option in every DDL form', () => {
  assert.equal(cleanDdlLine("WITH (pg_attver='1');"), ';');
  assert.equal(cleanDdlLine("WITH (fillfactor='80', pg_attver='1');"), "WITH (fillfactor='80');");
  assert.equal(cleanDdlLine("WITH (pg_attver='1', fillfactor='80');"), "WITH (fillfactor='80');");
  assert.equal(cleanDdlLine("ALTER TABLE ONLY public.customer_audit SET (pg_attver='2');"), '');
  assert.equal(cleanDdlLine("ALTER TABLE ONLY public.customer_audit ALTER COLUMN x SET (pg_attver=3);"), '');
  assert.equal(cleanDdlLine("ALTER TABLE ONLY public.t ALTER COLUMN x SET (n_distinct='5', pg_attver='3');"), "ALTER TABLE ONLY public.t ALTER COLUMN x SET (n_distinct='5');");
  assert.equal(cleanDdlLine('CREATE TABLE public.farmers ('), 'CREATE TABLE public.farmers (');
});

test('never alters COPY data, including text that mentions the option, and keeps UTF-8 intact', async () => {
  const sql = [
    'CREATE TABLE public.customer_audit (', '    id integer', ')', "WITH (pg_attver='1');",
    'COPY public.customer_audit (id, note) FROM stdin;', "1\tnote mentions pg_attver='9' and Kiambu – Wanjirũ", '\\.',
    "ALTER TABLE ONLY public.customer_audit SET (pg_attver='2');", 'SELECT 1;', '',
  ].join('\n');
  const bytes = Buffer.from(sql);
  // Feed one byte at a time to exercise line and multi-byte boundaries.
  const chunks = [...bytes].map(b => Buffer.from([b]));
  const f = new NeonOptionFilter(); let out = '';
  for await (const c of Readable.from(chunks).pipe(f)) out += c;
  assert.equal(out, ['CREATE TABLE public.customer_audit (', '    id integer', ')', ';',
    'COPY public.customer_audit (id, note) FROM stdin;', "1\tnote mentions pg_attver='9' and Kiambu – Wanjirũ", '\\.',
    'SELECT 1;', ''].join('\n'));
  assert.equal(f.changed, 2); assert.equal(f.copyBlocks, 1);
});

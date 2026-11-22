// Restore an authenticated, encrypted Neon backup into THIS checkout's own Docker PostgreSQL.
// The archive is decrypted in memory, rendered to SQL by pg_restore, filtered, and applied by psql in
// ONE transaction. No plaintext dump touches disk.
//
// Why a SQL stream instead of pg_restore straight into the database: Neon's PostgreSQL stores its own
// storage parameter (pg_attver) on some tables, which upstream PostgreSQL rejects
// ("unrecognized parameter"). The filter removes ONLY that parameter from DDL lines; COPY data blocks
// pass through byte-for-byte, so no record is altered.
//
// Usage (from deploy-mac.sh): BACKUP_KEY_FILE=/private/key node restore-encrypted.mjs <archive.dump.enc> <checkout-root> <docker-binary>
import {spawn} from 'node:child_process';
import {pipeline} from 'node:stream/promises';
import {resolve} from 'node:path';
import {decrypted, inspect} from '../../app/scripts/backup-hosted.mjs';
import {NeonOptionFilter} from './neon-option-filter.mjs';

const [file, root, docker] = process.argv.slice(2);
if (!file || !root || !docker) {
  console.error('Usage: node restore-encrypted.mjs <archive.dump.enc> <checkout-root> <docker-binary>');
  process.exit(2);
}
const compose = ['compose', '--project-directory', root, '--env-file', resolve(root, '.env'), 'exec', '-T', 'postgres', 'sh', '-c'];
const run = (script, stdout) => {
  const child = spawn(docker, [...compose, script], {stdio: ['pipe', stdout, 'inherit']});
  child.done = new Promise((ok, fail) => {
    child.once('error', fail);
    child.once('close', code => code === 0 ? ok() : fail(new Error(script.split(' ')[1] + ' exited with code ' + code)));
  });
  return child;
};
try {
  // Full GCM authentication pass first, so a tampered or truncated archive never reaches PostgreSQL.
  await inspect(resolve(file));
  const {source, decipher} = await decrypted(resolve(file));
  const render = run('exec pg_restore --no-owner --no-acl -f -', 'pipe');
  const apply = run('exec psql -X -q -o /dev/null -v ON_ERROR_STOP=1 --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"', 'inherit');
  const filter = new NeonOptionFilter();
  await Promise.all([
    pipeline(source, decipher, render.stdin),
    pipeline(render.stdout, filter, apply.stdin),
    render.done,
    apply.done,
  ]);
  console.log(`Encrypted backup restored into the local tailnet database (${filter.changed} Neon-only setting line(s) removed, ${filter.copyBlocks} data blocks passed through unchanged).`);
} catch (e) {
  console.error('Restore failed:', e.message);
  process.exitCode = 1;
}

// Restore an authenticated, encrypted Neon backup into THIS checkout's own Docker PostgreSQL.
// The archive is decrypted in memory and streamed to pg_restore; no plaintext dump touches disk.
// Usage (from deploy-mac.sh): BACKUP_KEY_FILE=/private/key node restore-encrypted.mjs <archive.dump.enc> <checkout-root> <docker-binary>
import {spawn} from 'node:child_process';
import {pipeline} from 'node:stream/promises';
import {resolve} from 'node:path';
import {decrypted, inspect} from '../../app/scripts/backup-hosted.mjs';

const [file, root, docker] = process.argv.slice(2);
if (!file || !root || !docker) {
  console.error('Usage: node restore-encrypted.mjs <archive.dump.enc> <checkout-root> <docker-binary>');
  process.exit(2);
}
try {
  // Full GCM authentication pass first, so a tampered or truncated archive never reaches pg_restore.
  await inspect(resolve(file));
  const {source, decipher} = await decrypted(resolve(file));
  const restore = spawn(docker, [
    'compose', '--project-directory', root, '--env-file', resolve(root, '.env'),
    'exec', '-T', 'postgres', 'sh', '-c',
    'exec pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-acl --exit-on-error --single-transaction',
  ], {stdio: ['pipe', 'inherit', 'inherit']});
  const finished = new Promise((ok, fail) => {
    restore.once('error', fail);
    restore.once('close', code => code === 0 ? ok() : fail(new Error('pg_restore exited with code ' + code)));
  });
  await Promise.all([pipeline(source, decipher, restore.stdin), finished]);
  console.log('Encrypted backup restored into the local tailnet database.');
} catch (e) {
  console.error('Restore failed:', e.message);
  process.exitCode = 1;
}

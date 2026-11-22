// Line filter for `pg_restore -f -` output: removes Neon-only storage parameters that upstream
// PostgreSQL rejects, touching DDL lines only. Everything between `COPY ... FROM stdin;` and `\.`
// is table data and passes through unchanged.
import {Transform} from 'node:stream';
import {StringDecoder} from 'node:string_decoder';

export const NEON_ONLY_OPTIONS = ['pg_attver'];
const option = new RegExp(`\\b(?:${NEON_ONLY_OPTIONS.join('|')})\\s*=\\s*(?:'(?:[^']|'')*'|[^,)\\s]+)`, 'g');

// Returns the cleaned DDL line, '' to drop it, or throws if a Neon option survives.
export function cleanDdlLine(line) {
  if (!NEON_ONLY_OPTIONS.some(name => line.includes(name))) return line;
  let out = line.replace(option, '')
    .replace(/\(\s*,\s*/g, '(').replace(/,\s*,/g, ',').replace(/,\s*\)/g, ')');
  // `WITH ()` left on a CREATE TABLE tail line, e.g. `)\nWITH (pg_attver='1');`
  out = out.replace(/^\s*WITH\s*\(\s*\)\s*;\s*$/, ';').replace(/\s+WITH\s*\(\s*\)/g, '');
  // `ALTER TABLE ... SET ();` / `RESET ()` with nothing left to set: drop the statement.
  if (/\b(?:SET|RESET)\s*\(\s*\)\s*;\s*$/.test(out)) return '';
  if (NEON_ONLY_OPTIONS.some(name => out.includes(name))) throw new Error('Could not remove Neon-only option from DDL line');
  return out;
}

export class NeonOptionFilter extends Transform {
  constructor() { super(); this.decoder = new StringDecoder('utf8'); this.tail = ''; this.inCopy = false; this.changed = 0; this.copyBlocks = 0; }
  _line(line) {
    if (this.inCopy) { if (line === '\\.') this.inCopy = false; return line + '\n'; }
    if (/^COPY .* FROM stdin;$/.test(line)) { this.inCopy = true; this.copyBlocks++; return line + '\n'; }
    const cleaned = cleanDdlLine(line);
    if (cleaned !== line) this.changed++;
    return cleaned === '' ? '' : cleaned + '\n';
  }
  _transform(chunk, _enc, done) {
    try {
      const text = this.tail + this.decoder.write(chunk);
      const lines = text.split('\n'); this.tail = lines.pop();
      this.push(lines.map(l => this._line(l)).join(''));
      done();
    } catch (e) { done(e); }
  }
  _flush(done) {
    try { this.tail += this.decoder.end(); if (this.tail) this.push(this._line(this.tail).replace(/\n$/, '')); done(); } catch (e) { done(e); }
  }
}

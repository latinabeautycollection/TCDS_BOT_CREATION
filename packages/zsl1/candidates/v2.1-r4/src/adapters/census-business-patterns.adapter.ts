import { spawn } from 'node:child_process';
import { readFile, mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import type { ZslSourceAdapter, SourceRelease, RetrievedArtifact, ArtifactValidation, RawSourceRecord, RecordValidation, IngestContext, ReconciliationResult, ValidationIssue } from '../core/types.js';
import { inspectZip } from '../core/archive.js';
import { parseCsvStream, parseDelimitedLine } from '../core/delimited.js';
import { sha256Canonical } from '../core/hash.js';
import { downloadToFile } from '../core/http.js';
import { loadPolicy } from '../core/policy.js';

type Geography = 'STATE' | 'COUNTY' | 'POSTAL_CODE';
type Selection = { version: string; year: number; vocabulary: string; codes: string[] };

const files: Record<Geography, string> = {
  STATE: 'cbp23st.zip',
  COUNTY: 'cbp23co.zip',
  POSTAL_CODE: 'zbp23detail.zip'
};
const fields: Record<Geography, string[]> = {
  STATE: ['fipstate', 'naics', 'lfo', 'est', 'emp', 'emp_nf', 'ap', 'ap_nf'],
  COUNTY: ['fipstate', 'fipscty', 'naics', 'est', 'emp', 'emp_nf', 'ap', 'ap_nf'],
  POSTAL_CODE: ['zip', 'naics', 'est']
};

async function memberFor(artifact: RetrievedArtifact, sourceKey: string): Promise<string> {
  if (artifact.sourceKey !== sourceKey) throw new Error('CBP_ZBP_SOURCE_MISMATCH');
  const { doc } = await loadPolicy();
  const members = await inspectZip(artifact.localPath, doc.sources[sourceKey]!);
  const expected = files[artifact.sourceKey === 'CENSUS_ZBP' ? 'POSTAL_CODE' :
    artifact.fileName === 'cbp23st.zip' ? 'STATE' : 'COUNTY'].replace('.zip', '.txt');
  if (members.length !== 1 || members[0]!.name !== expected) throw new Error('CBP_ZBP_ARCHIVE_MEMBER_MISMATCH');
  return expected;
}

async function headerFor(path: string, member: string): Promise<string[]> {
  const child = spawn('unzip', ['-p', path, member], { stdio: ['ignore', 'pipe', 'pipe'] });
  const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
  try {
    for await (const line of lines) return parseDelimitedLine(line, ',');
    throw new Error('CBP_ZBP_EMPTY_ARCHIVE_MEMBER');
  } finally {
    lines.close();
    child.kill('SIGTERM');
  }
}

function numeric(value: string, field: string, flag?: string): string | null {
  if (flag === 'N') return null;
  if (value === '' || value === 'N' || value === 'D' || value === 'S') return null;
  if (!/^\d+$/.test(value)) throw new Error(`CBP_ZBP_INVALID_${field}:${value}`);
  return value;
}

export class CensusBusinessPatternsAdapter implements ZslSourceAdapter {
  readonly adapterVersion = '2.1.1';
  readonly sourceKey: string;
  private readonly selectionPath = 'config/cbp-zbp-selection.json';

  constructor(private readonly geography: Geography, private readonly year: number) {
    if (year !== 2023) throw new Error('CBP_ZBP_VINTAGE_UNSUPPORTED');
    this.sourceKey = geography === 'POSTAL_CODE' ? 'CENSUS_ZBP' : 'CENSUS_CBP';
  }

  private async selection(): Promise<Selection> {
    const selection = JSON.parse(await readFile(this.selectionPath, 'utf8')) as Selection;
    if (selection.year !== this.year || selection.vocabulary !== 'NAICS2017' ||
        !Array.isArray(selection.codes) || selection.codes.length === 0 ||
        new Set(selection.codes).size !== selection.codes.length ||
        !selection.codes.every(code => /^\d{6}$/.test(code))) throw new Error('CBP_ZBP_SELECTION_INVALID');
    return selection;
  }

  async discoverRelease(): Promise<SourceRelease> {
    const selection = await this.selection();
    return {
      sourceKey: this.sourceKey,
      releaseKey: `${this.year}:${this.geography}:${selection.version}`,
      releaseLabel: `${this.year} ${this.sourceKey} ${this.geography} selected NAICS2017`,
      sourceYear: this.year,
      discoveredAt: new Date().toISOString(),
      metadata: { dataset: this.geography === 'POSTAL_CODE' ? 'ZBP' : 'CBP', geography: this.geography,
        vocabulary: selection.vocabulary, selectionVersion: selection.version,
        selectionSha256: sha256Canonical(selection), codes: selection.codes }
    };
  }

  async retrieve(release: SourceRelease): Promise<RetrievedArtifact> {
    const { doc } = await loadPolicy();
    const file = files[this.geography];
    const url = `https://www2.census.gov/programs-surveys/cbp/datasets/${this.year}/${file}`;
    const dir = await mkdtemp(join(tmpdir(), 'zsl-cbp-zbp-'));
    const path = join(dir, file);
    const result = await downloadToFile(url, { headers: { 'user-agent': 'TCDS-ZSL1/2.1.1' } }, path, doc.sources[this.sourceKey]!);
    return { sourceKey: this.sourceKey, releaseKey: release.releaseKey, fileName: file,
      localPath: path, sourceUrl: url, byteCount: result.byteCount, sha256: result.sha256,
      retrievedAt: new Date().toISOString(), ...(result.contentType ? { contentType: result.contentType } : {}),
      ...(result.etag ? { etag: result.etag } : {}),
      ...(result.lastModified ? { lastModified: result.lastModified } : {}) };
  }

  async validateArtifact(artifact: RetrievedArtifact): Promise<ArtifactValidation> {
    const member = await memberFor(artifact, this.sourceKey);
    const header = await headerFor(artifact.localPath, member);
    const missing = fields[this.geography].filter(field => !header.includes(field));
    const issues: ValidationIssue[] = missing.map(field => ({ code: 'CBP_ZBP_HEADER_MISSING', message: field, field, fatal: true }));
    const selection = await this.selection();
    return { valid: issues.length === 0, issues,
      schemaSha256: sha256Canonical({ year: this.year, geography: this.geography, member, header, selection }),
      evidence: { member, header, selection, selectionSha256: sha256Canonical(selection) } };
  }

  async *parse(artifact: RetrievedArtifact): AsyncIterable<RawSourceRecord> {
    const member = await memberFor(artifact, this.sourceKey);
    const selection = await this.selection();
    const codes = new Set(selection.codes);
    const child = spawn('unzip', ['-p', artifact.localPath, member], { stdio: ['ignore', 'pipe', 'pipe'] });
    child.stdout.setEncoding('utf8');
    let stderr = '';
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk: string) => { stderr += chunk.slice(0, 1000); });
    const closed = new Promise<number | null>((resolve, reject) => {
      child.once('error', reject);
      child.once('close', resolve);
    });
    let header: string[] | undefined;
    let rowNumber = 0;
    const naturalKeys = new Set<string>();
    try {
      for await (const values of parseCsvStream(child.stdout)) {
        if (!header) { header = values; continue; }
        rowNumber++;
        if (values.length !== header.length) throw new Error(`CBP_ZBP_COLUMN_COUNT_MISMATCH:${rowNumber}`);
        const source = Object.fromEntries(header.map((field, i) => [field, values[i] ?? '']));
        const code = source.naics ?? '';
        if (!codes.has(code) || (this.geography === 'STATE' && source.lfo !== '-')) continue;
        const state = source.fipstate ?? '';
        const county = source.fipscty ?? '';
        const zip = source.zip ?? '';
        const geo = this.geography === 'STATE' ? state : this.geography === 'COUNTY' ? state + county : zip;
        const record: Record<string, unknown> = {
          ...source, source_member: member, source_row: rowNumber, NAICS2017: code,
          ESTAB: numeric(source.est ?? '', 'ESTAB'), ESTAB_F: null,
          EMP: this.geography === 'POSTAL_CODE' ? null : numeric(source.emp ?? '', 'EMP', source.emp_nf),
          EMP_F: this.geography === 'POSTAL_CODE' ? null : (source.emp_nf || null),
          PAYANN: this.geography === 'POSTAL_CODE' ? null : numeric(source.ap ?? '', 'PAYANN', source.ap_nf),
          PAYANN_F: this.geography === 'POSTAL_CODE' ? null : (source.ap_nf || null),
          ...(this.geography === 'POSTAL_CODE' ? { ZIPCODE: zip } : { state, ...(this.geography === 'COUNTY' ? { county } : {}) })
        };
        const naturalKey = `${this.geography}:${geo}:${code}`;
        if (naturalKeys.has(naturalKey)) throw new Error(`CBP_ZBP_DUPLICATE_NATURAL_KEY:${naturalKey}`);
        naturalKeys.add(naturalKey);
        yield { naturalKey, record };
      }
      if (!header) throw new Error('CBP_ZBP_EMPTY_ARCHIVE_MEMBER');
      const status = await closed;
      if (status !== 0) throw new Error(`CBP_ZBP_UNZIP_FAILED:${status}:${stderr.slice(0, 200)}`);
    } finally {
      if (child.exitCode === null) child.kill('SIGTERM');
    }
  }

  validateRecord(row: RawSourceRecord): RecordValidation {
    const record = row.record;
    const geography = this.geography === 'STATE' ? String(record.state ?? '') :
      this.geography === 'COUNTY' ? `${record.state ?? ''}${record.county ?? ''}` : String(record.ZIPCODE ?? '');
    const issues: ValidationIssue[] = [];
    if (!new RegExp(`^\\d{${this.geography === 'STATE' ? 2 : 5}}$`).test(geography))
      issues.push({ code: 'CBP_ZBP_GEOGRAPHY_INVALID', message: geography, fatal: true });
    if (!/^\d{6}$/.test(String(record.NAICS2017 ?? '')))
      issues.push({ code: 'CBP_ZBP_NAICS_INVALID', message: String(record.NAICS2017 ?? ''), fatal: true });
    if (record.ESTAB === null) issues.push({ code: 'CBP_ZBP_ESTAB_MISSING', message: row.naturalKey, fatal: true });
    return { valid: issues.length === 0, issues };
  }

  async reconcile(_context: IngestContext): Promise<ReconciliationResult> {
    return { ok: true, parsedCount: 0, loadedMembershipCount: 0, distinctRecordCount: 0, issues: [] };
  }
}

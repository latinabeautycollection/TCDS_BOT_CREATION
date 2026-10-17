import { join } from "node:path";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { spawn } from "node:child_process";
import type { ArtifactValidation, IngestContext, RawSourceRecord, ReconciliationResult, RecordValidation, RetrievedArtifact, SourceRelease, ValidationIssue, ZslSourceAdapter } from "../core/types.js";
import { inspectZip } from "../core/archive.js";
import { parseCsvStream } from "../core/delimited.js";
import { sha256Canonical } from "../core/hash.js";
import { downloadToFile } from "../core/http.js";
import { loadPolicy } from "../core/policy.js";
import { validateRequired } from "./common.js";

export type BusinessPatternsGrain = "STATE" | "COUNTY" | "POSTAL_CODE";
type SourceKey = "CENSUS_CBP" | "CENSUS_ZBP";

function fips(value: unknown, width: number): string | undefined {
  const text = String(value ?? "").trim();
  return /^\d+$/.test(text) && text.length <= width ? text.padStart(width, "0") : undefined;
}

export function deriveCbpStateGeoId(record: Record<string, unknown>): string | undefined {
  const state = fips(record.STATE, 2);
  return state ? "0400000US" + state : undefined;
}

export function deriveCbpCountyGeoId(record: Record<string, unknown>): string | undefined {
  const state = fips(record.STATE, 2);
  const county = fips(record.COUNTY, 3);
  return state && county ? "0500000US" + state + county : undefined;
}

function canonical(headers: string[], row: string[]): Record<string, unknown> {
  const raw: Record<string, unknown> = {};
  headers.forEach((header, index) => { raw[header] = row[index] ?? ""; });
  const lower = new Map(headers.map(header => [header.toLowerCase(), header]));
  const value = (...names: string[]) => {
    const key = names.map(name => lower.get(name.toLowerCase())).find(Boolean);
    return key ? raw[key] : "";
  };
  return {
    STATE: value("STATE", "fipstate"),
    COUNTY: value("COUNTY", "fipscty"),
    ZIPCODE: value("ZIPCODE", "zip"),
    NAICS2017: value("NAICS2017", "naics"),
    ESTAB: value("ESTAB", "est"),
    EMP: value("EMP", "emp"),
    PAYANN: value("PAYANN", "ap"),
    ESTAB_F: value("ESTAB_F", "est_nf"),
    EMP_F: value("EMP_F", "emp_nf"),
    PAYANN_F: value("PAYANN_F", "ap_nf")
  };
}

export class CensusBusinessPatternsAdapter implements ZslSourceAdapter {
  readonly adapterVersion = "2.1.5";
  readonly sourceKey: SourceKey;

  constructor(
    private readonly grain: BusinessPatternsGrain,
    private readonly sourceYear: number,
    private readonly governedUrl: string
  ) {
    this.sourceKey = grain === "POSTAL_CODE" ? "CENSUS_ZBP" : "CENSUS_CBP";
    if (sourceYear !== 2023) throw new Error("CBP_ZBP_SOURCE_YEAR_MUST_BE_2023");
    if (!governedUrl) throw new Error("CBP_ZBP_GOVERNED_URL_REQUIRED");
    if (new URL(governedUrl).hostname !== "www2.census.gov") throw new Error("CBP_ZBP_UNAPPROVED_HOST");
  }

  async discoverRelease(): Promise<SourceRelease> {
    const dataset = this.sourceKey === "CENSUS_CBP" ? "CBP" : "ZBP";
    const releaseKey = this.sourceYear + ":" + this.grain + ":2023-naics2017-zsl1-v2.1.5";
    return {
      sourceKey: this.sourceKey,
      releaseKey,
      releaseLabel: "Census " + dataset + " " + this.grain + " " + this.sourceYear,
      sourceYear: this.sourceYear,
      discoveredAt: new Date().toISOString(),
      metadata: { dataset, geography: this.grain, naicsVocabulary: "NAICS2017", releaseKey, sourceYear: this.sourceYear, governedUrl: this.governedUrl }
    };
  }

  async retrieve(release: SourceRelease): Promise<RetrievedArtifact> {
    const { doc } = await loadPolicy();
    const directory = await mkdtemp(join(tmpdir(), "zsl-cbp-zbp-"));
    const localPath = join(directory, this.sourceKey + "_" + release.releaseKey + ".zip");
    const downloaded = await downloadToFile(this.governedUrl, {
      headers: { "user-agent": "TCDS-ZSL1/2.1.5", Accept: "application/zip,application/octet-stream" }
    }, localPath, doc.sources[this.sourceKey]!);
    return {
      sourceKey: this.sourceKey, releaseKey: release.releaseKey, fileName: localPath.split("/").pop()!,
      localPath, sourceUrl: this.governedUrl, byteCount: downloaded.byteCount, sha256: downloaded.sha256,
      retrievedAt: new Date().toISOString(), ...(downloaded.contentType ? { contentType: downloaded.contentType } : {})
    };
  }

  private async member(path: string) {
    const { doc } = await loadPolicy();
    const members = await inspectZip(path, doc.sources[this.sourceKey]!);
    const delimited = members.filter(member => /\.(csv|txt)$/i.test(member.name));
    if (delimited.length !== 1) throw new Error("CBP_ZBP_EXPECTED_SINGLE_DELIMITED_MEMBER:" + this.sourceKey + ":" + delimited.length);
    return delimited[0]!;
  }

  private stream(path: string, member: string) {
    const child = spawn("unzip", ["-p", path, member], { stdio: ["ignore", "pipe", "pipe"] });
    let stderr = "";
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk: string) => { stderr += chunk; });
    child.once("close", code => {
      if (code !== 0) child.stdout.destroy(new Error("CBP_ZBP_UNZIP_FAILED:" + code + ":" + stderr.slice(0, 1000)));
    });
    return child.stdout;
  }

  private requiredHeaders(): string[] {
    if (this.grain === "STATE") return ["fipstate", "naics", "est"];
    if (this.grain === "COUNTY") return ["fipstate", "fipscty", "naics", "est"];
    return ["zip", "naics", "est"];
  }

  async validateArtifact(artifact: RetrievedArtifact): Promise<ArtifactValidation> {
    const member = await this.member(artifact.localPath);
    const iterator = parseCsvStream(this.stream(artifact.localPath, member.name))[Symbol.asyncIterator]();
    const headers = ((await iterator.next()).value ?? []).map((value: string) => value.trim()) as string[];
    const available = new Set(headers.map(header => header.toLowerCase()));
    const issues: ValidationIssue[] = [];
    for (const required of this.requiredHeaders()) {
      if (!available.has(required)) issues.push({ code: "CBP_ZBP_REQUIRED_HEADER_MISSING", message: required, fatal: true, field: required });
    }
    return {
      valid: issues.every(issue => !issue.fatal), issues,
      schemaSha256: sha256Canonical({ sourceKey: this.sourceKey, grain: this.grain, member: member.name, headers }),
      evidence: { member: member.name, headers, expandedBytes: member.expandedBytes, compressedBytes: member.compressedBytes }
    };
  }

  async *parse(artifact: RetrievedArtifact): AsyncIterable<RawSourceRecord> {
    const member = await this.member(artifact.localPath);
    let headers: string[] | undefined;
    let ordinal = 0;
    for await (const row of parseCsvStream(this.stream(artifact.localPath, member.name))) {
      if (!headers) { headers = row.map(value => value.trim()); continue; }
      ordinal++;
      if (row.length !== headers.length) throw new Error("CBP_ZBP_COLUMN_COUNT_MISMATCH:" + ordinal);
      const record = canonical(headers, row);
      if (this.grain === "STATE") record.GEO_ID = deriveCbpStateGeoId(record);
      if (this.grain === "COUNTY") record.GEO_ID = deriveCbpCountyGeoId(record);
      const identity = this.grain === "POSTAL_CODE" ? record.ZIPCODE : record.GEO_ID;
      yield { naturalKey: String(identity ?? "") + ":" + String(record.NAICS2017 ?? ""), record };
    }
  }

  validateRecord(record: RawSourceRecord): RecordValidation {
    const required = this.grain === "POSTAL_CODE" ? ["ZIPCODE", "NAICS2017", "ESTAB"] : ["GEO_ID", "NAICS2017", "ESTAB"];
    const issues = [...validateRequired(record, required).issues];
    const geo = String(record.record.GEO_ID ?? "");
    if (this.grain === "STATE" && !/^0400000US\d{2}$/.test(geo)) issues.push({ code: "CBP_STATE_GEOID_INVALID", message: geo, fatal: true, field: "GEO_ID" });
    if (this.grain === "COUNTY" && !/^0500000US\d{5}$/.test(geo)) issues.push({ code: "CBP_COUNTY_GEOID_INVALID", message: geo, fatal: true, field: "GEO_ID" });
    if (this.grain === "POSTAL_CODE" && !/^\d{5}$/.test(String(record.record.ZIPCODE ?? ""))) issues.push({ code: "ZBP_ZIP_INVALID", message: String(record.record.ZIPCODE ?? ""), fatal: true, field: "ZIPCODE" });
    if (!/^[0-9A-Z-]+$/.test(String(record.record.NAICS2017 ?? ""))) issues.push({ code: "NAICS2017_INVALID", message: String(record.record.NAICS2017 ?? ""), fatal: true, field: "NAICS2017" });
    return { valid: issues.every(issue => !issue.fatal), issues };
  }

  async reconcile(_context: IngestContext): Promise<ReconciliationResult> {
    return { ok: true, parsedCount: 0, loadedMembershipCount: 0, distinctRecordCount: 0, issues: [] };
  }
}

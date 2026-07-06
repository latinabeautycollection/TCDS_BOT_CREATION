export type PaidIpIntelResult = {
  ip?: string;
  asn?: string | null;
  org?: string | null;
  ipType?: string | null;
  city?: string | null;
  region?: string | null;
  countryCode?: string | null;
  timezone?: string | null;
  isAnonymous?: boolean | null;
  isHosting?: boolean | null;
  isVpn?: boolean | null;
  isTor?: boolean | null;
  isProxy?: boolean | null;
  isRelay?: boolean | null;
  isResidentialProxy?: boolean | null;
  reputationScore?: number;
  riskReasons?: string[];
  raw?: unknown;
  error?: string;
};

export async function paidIpIntel(ip: string): Promise<PaidIpIntelResult> {
  const token = process.env.IPINFO_TOKEN || "";

  if (!ip) return {};

  if (!token) {
    return {
      ip,
      error: "missing_ipinfo_token",
      reputationScore: 50,
      riskReasons: ["missing_ipinfo_token"]
    };
  }

  const res = await fetch(`https://api.ipinfo.io/lookup/${encodeURIComponent(ip)}`, {
    headers: {
      authorization: `Bearer ${token}`,
      accept: "application/json"
    }
  });

  const data: any = await res.json().catch(() => ({}));

  if (!res.ok) {
    return {
      ip,
      error: data?.error?.message || data?.message || `ipinfo_http_${res.status}`,
      reputationScore: 50,
      riskReasons: ["ipinfo_lookup_failed"]
    };
  }

  const riskReasons: string[] = [];

  if (data.is_hosting) riskReasons.push("hosting_network");
  if (data.anonymous?.is_vpn) riskReasons.push("vpn_detected");
  if (data.anonymous?.is_tor) riskReasons.push("tor_detected");
  if (data.anonymous?.is_proxy) riskReasons.push("proxy_detected");
  if (data.anonymous?.is_relay) riskReasons.push("relay_detected");

  const ipType = data.anonymous?.is_res_proxy
    ? "residential"
    : data.is_hosting
      ? "hosting"
      : data.as?.type || null;

  return {
    ip: data.ip || ip,
    asn: data.as?.asn || null,
    org: data.as?.name || null,
    ipType,
    city: data.geo?.city || null,
    region: data.geo?.region || null,
    countryCode: data.geo?.country_code || null,
    timezone: data.geo?.timezone || null,
    isAnonymous: data.is_anonymous ?? null,
    isHosting: data.is_hosting ?? null,
    isVpn: data.anonymous?.is_vpn ?? null,
    isTor: data.anonymous?.is_tor ?? null,
    isProxy: data.anonymous?.is_proxy ?? null,
    isRelay: data.anonymous?.is_relay ?? null,
    isResidentialProxy: data.anonymous?.is_res_proxy ?? null,
    reputationScore: riskReasons.length ? 65 : 95,
    riskReasons,
    raw: data
  };
}

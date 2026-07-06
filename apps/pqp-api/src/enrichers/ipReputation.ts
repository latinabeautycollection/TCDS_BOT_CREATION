export type IpReputationResult = {
  ipType: "residential" | "mobile" | "datacenter" | "unknown";
  reputationScore: number;
  riskReasons: string[];
  asn?: number;
  org?: string;
  countryCode?: string;
};

/**
 * Defensive placeholder.
 * Replace this with MaxMind, IPinfo, Spur, IPQS, or internal threat intel.
 */
export function enrichIp(ip: string | null | undefined): IpReputationResult {
  const reasons: string[] = [];

  if (!ip) {
    return {
      ipType: "unknown",
      reputationScore: 0,
      riskReasons: ["Missing IP address"]
    };
  }

  const privateRanges = [
    /^10\./,
    /^192\.168\./,
    /^172\.(1[6-9]|2[0-9]|3[0-1])\./,
    /^127\./
  ];

  if (privateRanges.some(r => r.test(ip))) {
    reasons.push("Private or internal IP observed");
    return {
      ipType: "unknown",
      reputationScore: 1,
      riskReasons: reasons
    };
  }

  return {
    ipType: "unknown",
    reputationScore: 2,
    riskReasons: ["No external reputation provider configured"]
  };
}

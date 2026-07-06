export type ScoreInput = {
  edge?: any;
  fingerprint?: any;
  behaviorEvents?: any[];
  challengeEvents?: any[];
};

export type ScoreResult = {
  networkScore: number;
  browserScore: number;
  behaviorScore: number;
  continuityScore: number;
  challengeScore: number;
  totalScore: number;
  verdict: string;
  failReasons: string[];
};

function clamp(n: number, max: number): number {
  return Math.max(0, Math.min(max, n));
}

export function scorePqp(input: ScoreInput): ScoreResult {
  const failReasons: string[] = [];

  let networkScore = 25;
  const edge = input.edge;

  if (!edge) {
    networkScore = 0;
    failReasons.push("Missing edge telemetry");
  } else {
    if (!edge.ja3_hash && !edge.ja4_hash) {
      networkScore -= 8;
      failReasons.push("Missing JA3/JA4 fingerprint");
    }

    if (!edge.http_version) {
      networkScore -= 5;
      failReasons.push("Missing HTTP version telemetry");
    }

    if ((edge.header_consistency_score ?? 0) < 3) {
      networkScore -= 5;
      failReasons.push("Weak header consistency");
    }

    if (edge.leak_detected) {
      networkScore -= 3;
      failReasons.push("Potential proxy, DNS, IPv6, or header leak detected");
    }
  }

  let browserScore = 25;
  const fp = input.fingerprint;

  if (!fp) {
    browserScore = 0;
    failReasons.push("Missing browser fingerprint");
  } else {
    if (fp.webdriver_flag === true) {
      browserScore -= 5;
      failReasons.push("navigator.webdriver exposed");
    }

    if (!fp.webgl_vendor || !fp.webgl_renderer) {
      browserScore -= 5;
      failReasons.push("Missing WebGL vendor or renderer");
    }

    if (!fp.canvas_hash) {
      browserScore -= 4;
      failReasons.push("Missing canvas hash");
    }

    if (!fp.audio_hash) {
      browserScore -= 3;
      failReasons.push("Missing AudioContext hash");
    }

    if (!fp.timezone || !fp.languages || fp.languages.length === 0) {
      browserScore -= 5;
      failReasons.push("Missing timezone or language signals");
    }

    if (!fp.cpu_cores || !fp.device_memory) {
      browserScore -= 3;
      failReasons.push("Missing CPU or memory signals");
    }
  }

  const behavior = input.behaviorEvents ?? [];
  let behaviorScore = 20;

  const mouseMoves = behavior.filter(e => e.event_type === "mousemove");
  const scrolls = behavior.filter(e => e.event_type === "scroll");
  const keys = behavior.filter(e => e.event_type === "keydown" || e.event_type === "keyup");
  const clicks = behavior.filter(e => e.event_type === "click");

  if (mouseMoves.length < 10) {
    behaviorScore -= 5;
    failReasons.push("Insufficient mouse movement");
  }

  if (scrolls.length < 2) {
    behaviorScore -= 4;
    failReasons.push("Insufficient scroll variability");
  }

  if (keys.length > 0 && keys.length < 4) {
    behaviorScore -= 4;
    failReasons.push("Weak keyboard cadence telemetry");
  }

  if (clicks.length > 0 && mouseMoves.length === 0) {
    behaviorScore -= 3;
    failReasons.push("Clicks occurred without mouse movement");
  }

  const totalEvents = behavior.length;
  if (totalEvents < 20) {
    behaviorScore -= 4;
    failReasons.push("Low behavioral entropy");
  }

  let continuityScore = 15;

  if (fp && edge) {
    const uaMismatch =
      edge.user_agent &&
      fp.user_agent &&
      edge.user_agent !== fp.user_agent;

    if (uaMismatch) {
      continuityScore -= 3;
      failReasons.push("User-Agent mismatch between edge and browser");
    }
  } else {
    continuityScore -= 5;
  }

  if (!fp?.timezone) {
    continuityScore -= 4;
  }

  let challengeScore = 15;
  const challenges = input.challengeEvents ?? [];

  if (challenges.length === 0) {
    challengeScore -= 5;
    failReasons.push("No challenge telemetry recorded");
  } else {
    const failed = challenges.some(c =>
      ["failed", "timeout", "abandoned"].includes(String(c.outcome || "").toLowerCase())
    );

    if (failed) {
      challengeScore -= 6;
      failReasons.push("Challenge failed, timed out, or was abandoned");
    }
  }

  networkScore = clamp(networkScore, 25);
  browserScore = clamp(browserScore, 25);
  behaviorScore = clamp(behaviorScore, 20);
  continuityScore = clamp(continuityScore, 15);
  challengeScore = clamp(challengeScore, 15);

  const totalScore =
    networkScore +
    browserScore +
    behaviorScore +
    continuityScore +
    challengeScore;

  let verdict = "weak_bot";
  if (totalScore >= 91) verdict = "critical_exposure";
  else if (totalScore >= 76) verdict = "high_grade_simulator";
  else if (totalScore >= 56) verdict = "advanced_gray_bot";
  else if (totalScore >= 31) verdict = "basic_stealth";
  else verdict = "weak_bot";

  return {
    networkScore,
    browserScore,
    behaviorScore,
    continuityScore,
    challengeScore,
    totalScore,
    verdict,
    failReasons
  };
}

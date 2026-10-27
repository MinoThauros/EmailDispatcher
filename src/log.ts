// One JSON object per line, so platform log drains (Vercel, Datadog, Loki)
// can index fields without parsing prose. Never pass tokens or email bodies.

type Level = "info" | "warn" | "error";

export function log(level: Level, event: string, fields: Record<string, unknown> = {}): void {
  const line = JSON.stringify({ level, event, at: new Date().toISOString(), ...fields });

  if (level === "error") {
    console.error(line);
  } else if (level === "warn") {
    console.warn(line);
  } else {
    console.log(line);
  }
}

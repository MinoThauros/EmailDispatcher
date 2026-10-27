import { timingSafeEqual } from "node:crypto";

export function jsonResponse(body: unknown, init: ResponseInit = {}): Response {
  return new Response(JSON.stringify(body), {
    ...init,
    headers: { "content-type": "application/json; charset=utf-8", ...(init.headers ?? {}) },
  });
}

/**
 * Vercel Cron sends `Authorization: Bearer $CRON_SECRET`. The endpoint fails
 * closed when the secret is not configured, so it is never left public.
 */
export function checkCronAuthorization(request: Request, secret = process.env.CRON_SECRET): Response | null {
  const expected = secret?.trim();

  if (!expected) {
    return jsonResponse({ ok: false, error: "CRON_SECRET is not configured" }, { status: 500 });
  }

  const provided = Buffer.from(request.headers.get("authorization") ?? "");
  const wanted = Buffer.from(`Bearer ${expected}`);

  if (provided.length !== wanted.length || !timingSafeEqual(provided, wanted)) {
    return jsonResponse({ ok: false, error: "Unauthorized" }, { status: 401 });
  }

  return null;
}

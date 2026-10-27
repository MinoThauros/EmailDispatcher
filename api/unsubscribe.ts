import { getRuntimeConfig } from "../src/config";
import { createSupabaseRpcClient } from "../src/rpc";

// Public unsubscribe endpoint. Point UNSUBSCRIBE_URL_BASE at it, e.g.
// https://your-app.vercel.app/api/unsubscribe?token={token}
//
// GET only shows a confirm button: link scanners in mail security gateways
// prefetch URLs, and a GET that writes would unsubscribe people by accident.
// POST does the write, both from that button and from RFC 8058 one-click
// (mail clients POST "List-Unsubscribe=One-Click" to the header URL).

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function readToken(request: Request): string | null {
  const token = new URL(request.url).searchParams.get("token") ?? "";
  return UUID.test(token) ? token : null;
}

function page(body: string, status = 200): Response {
  const html = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Unsubscribe</title><body style="font-family:system-ui,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem">${body}</body>`;
  return new Response(html, { status, headers: { "content-type": "text/html; charset=utf-8" } });
}

export async function GET(request: Request): Promise<Response> {
  const token = readToken(request);

  if (!token) {
    return page("<p>This unsubscribe link is not valid.</p>", 400);
  }

  return page(
    `<p>Stop receiving these emails?</p><form method="post" action="?token=${token}"><button type="submit">Unsubscribe</button></form>`
  );
}

export async function POST(request: Request): Promise<Response> {
  const token = readToken(request);
  const body = await request.text().catch(() => "");
  const oneClick = body.includes("List-Unsubscribe=One-Click");

  if (!token) {
    return oneClick ? new Response(null, { status: 400 }) : page("<p>This unsubscribe link is not valid.</p>", 400);
  }

  try {
    const runtime = getRuntimeConfig();
    const rpc = createSupabaseRpcClient(runtime.supabaseUrl, runtime.supabaseServiceRoleKey);
    const { error } = await rpc.rpc<boolean>("dispatcher_record_unsubscribe", {
      p_token: token,
      p_via: oneClick ? "one_click_header" : "unsubscribe_link",
    });

    if (error) {
      throw new Error(error.message ?? "unsubscribe failed");
    }
  } catch {
    return oneClick ? new Response(null, { status: 500 }) : page("<p>Something went wrong. Please try again.</p>", 500);
  }

  // An unknown token gets the same answer, so the endpoint doesn't reveal
  // which tokens exist.
  return oneClick ? new Response(null, { status: 200 }) : page("<p>You have been unsubscribed.</p>");
}

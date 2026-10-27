import { runDispatcherCycle } from "../../src/dispatcher";
import { checkCronAuthorization, jsonResponse } from "../../src/http";
import { log } from "../../src/log";

// vercel.json gives this function 300s; the worker's drain budget (270s)
// plus its shutdown margin is sized to finish inside that.

export async function GET(request: Request): Promise<Response> {
  const unauthorized = checkCronAuthorization(request);

  if (unauthorized) {
    return unauthorized;
  }

  const triggeredAt = new Date().toISOString();

  try {
    const summary = await runDispatcherCycle();
    return jsonResponse({ ok: true, mode: "cron", triggeredAt, ...summary });
  } catch (error) {
    log("error", "dispatcher.cycle.failed", { triggeredAt, error: error instanceof Error ? error.message : String(error) });
    return jsonResponse({ ok: false, error: "Dispatcher cycle failed" }, { status: 500 });
  }
}

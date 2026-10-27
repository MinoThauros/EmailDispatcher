import "dotenv/config";
import { getRuntimeConfig } from "./config";
import { runDispatcherCycle } from "./dispatcher";
import { createSupabaseRpcClient } from "./rpc";

// Local runner: the same cycle the cron route runs, repeated
// WORKER_LOOP_CYCLES times so you can watch pacing and retries unfold.
async function main(): Promise<void> {
  const runtime = getRuntimeConfig();
  const rpc = createSupabaseRpcClient(runtime.supabaseUrl, runtime.supabaseServiceRoleKey);

  for (let cycle = 1; cycle <= runtime.loopCycles; cycle += 1) {
    await runDispatcherCycle(process.env, rpc);

    if (cycle < runtime.loopCycles && runtime.loopDelayMs > 0) {
      await new Promise((resolve) => setTimeout(resolve, runtime.loopDelayMs));
    }
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});

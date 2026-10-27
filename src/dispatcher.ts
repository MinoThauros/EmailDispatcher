import { getProviderConfig, getRuntimeConfig, getSimulationConfig, getWorkerConfig } from "./config";
import { log } from "./log";
import { executeGmailSend } from "./provider/gmail";
import { createSimulatedFetcher } from "./provider/simulated-fetch";
import { createReceiptClient } from "./receipts";
import { createSupabaseRpcClient, type RpcClient } from "./rpc";
import { collectScopeDeferrals, drainQueue, runWorkerCycle, type WorkerCycleSummary } from "./worker";

/**
 * One full dispatcher cycle, shared by the cron route and the local runner:
 * claim in Postgres, send through Gmail (or the simulator), write the
 * receipt, repeat; then report why the remaining work was deferred.
 */
export async function runDispatcherCycle(
  env: Record<string, string | undefined> = process.env,
  rpc: RpcClient = createRpcFromEnv(env)
): Promise<WorkerCycleSummary> {
  const workerConfig = getWorkerConfig(env);
  const providerConfig = getProviderConfig(env);
  const simulation = getSimulationConfig(env);
  const fetcher = simulation.enabled ? createSimulatedFetcher(simulation) : undefined;
  const receipts = createReceiptClient(rpc);

  const summary = await runWorkerCycle({
    config: workerConfig,
    drain: async (context) => {
      const tokensIssued = await drainQueue({
        config: workerConfig,
        context,
        rpc,
        handleTokenIssued: (sendContext) =>
          executeGmailSend({ config: providerConfig, context: sendContext, fetcher, receipts, rpc }),
      });

      const deferrals = await collectScopeDeferrals(rpc, context.workerId);

      if (deferrals.length > 0) {
        log("info", "dispatcher.cycle.deferrals", { workerId: context.workerId, deferrals });
      }

      return tokensIssued;
    },
  });

  log("info", "dispatcher.cycle.completed", { ...summary, simulated: simulation.enabled });
  return summary;
}

function createRpcFromEnv(env: Record<string, string | undefined>): RpcClient {
  const runtime = getRuntimeConfig(env);
  return createSupabaseRpcClient(runtime.supabaseUrl, runtime.supabaseServiceRoleKey);
}

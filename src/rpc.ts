export type RpcError = {
  code?: string;
  details?: string;
  hint?: string;
  message?: string;
};

export type RpcResult<Data> = {
  data: Data | null;
  error: RpcError | null;
};

/**
 * The only database surface the worker uses: calling dispatcher RPCs. Kept
 * structural so tests can pass a fake, and so any client that can call a
 * Postgres function (supabase-js, PostgREST, a pg pool) fits.
 */
export type RpcClient = {
  rpc<Data = unknown>(fn: string, args?: Record<string, unknown>): PromiseLike<RpcResult<Data>>;
};

/**
 * Calls PostgREST's `POST /rest/v1/rpc/<fn>` with the service-role key. The
 * worker needs nothing else from Supabase, so this avoids pulling in
 * supabase-js (and its Realtime client) for a handful of function calls.
 */
export function createSupabaseRpcClient(url: string, serviceRoleKey: string, fetcher: typeof fetch = fetch): RpcClient {
  const base = `${url.replace(/\/+$/, "")}/rest/v1/rpc/`;

  return {
    async rpc<Data>(fn: string, args: Record<string, unknown> = {}): Promise<RpcResult<Data>> {
      let response: Response;

      try {
        response = await fetcher(base + encodeURIComponent(fn), {
          method: "POST",
          headers: {
            apikey: serviceRoleKey,
            Authorization: `Bearer ${serviceRoleKey}`,
            "Content-Type": "application/json",
            Accept: "application/json",
          },
          body: JSON.stringify(args),
        });
      } catch (error) {
        return { data: null, error: { message: error instanceof Error ? error.message : "RPC request failed" } };
      }

      const text = await response.text();
      let body: unknown = null;

      try {
        body = text ? JSON.parse(text) : null;
      } catch {
        body = text;
      }

      if (!response.ok) {
        const error = typeof body === "object" && body !== null ? (body as RpcError) : { message: String(body) };
        return { data: null, error: { ...error, message: error.message ?? `HTTP ${response.status}` } };
      }

      return { data: body as Data, error: null };
    },
  };
}

export function formatRpcError(error: RpcError): string {
  return [error.message, error.code, error.details, error.hint]
    .filter((part): part is string => Boolean(part))
    .join(" ");
}

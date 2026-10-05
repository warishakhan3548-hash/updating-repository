// A second public route to the existing control plane. CORE is a service
// binding, so requests never go back out through the workers.dev hostname.
// Pairing state, authentication, consent gates, signaling and TURN remain
// owned by aaris-remote-ice. In particular, return WebSocket upgrades intact.
export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (path !== "/healthz" && path !== "/v1/sessions" &&
        !path.startsWith("/v1/sessions/")) {
      return Response.json({ ok: false, error: "not_found" }, { status: 404 });
    }
    if (!env.CORE) {
      return Response.json(
        { ok: false, error: "backend_not_configured" },
        { status: 503, headers: { "cache-control": "no-store" } }
      );
    }
    return env.CORE.fetch(request);
  }
};

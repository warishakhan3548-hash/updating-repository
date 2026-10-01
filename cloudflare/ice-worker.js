function b64url(input) {
  const s = input.replace(/-/g, "+").replace(/_/g, "/");
  const padded = s + "=".repeat((4 - s.length % 4) % 4);
  const raw = atob(padded);
  return Uint8Array.from(raw, c => c.charCodeAt(0));
}

async function verifyFirebaseToken(token) {
  const parts = token.split(".");
  if (parts.length !== 3) throw new Error("token");

  const header = JSON.parse(
    new TextDecoder().decode(b64url(parts[0]))
  );
  const payload = JSON.parse(
    new TextDecoder().decode(b64url(parts[1]))
  );

  if (header.alg !== "RS256" || !header.kid) {
    throw new Error("header");
  }

  const jwksUrl =
    "https://www.googleapis.com/service_accounts/v1/jwk/" +
    "securetoken@system.gserviceaccount.com";

  async function loadJwks(cacheTtl) {
    const response = await fetch(
      jwksUrl,
      {
        cf: {
          cacheTtl,
          cacheEverything: cacheTtl > 0
        }
      }
    );
    if (!response.ok) throw new Error("jwks");
    return response.json();
  }

  let jwks = await loadJwks(300);
  let jwk = (jwks.keys || []).find(
    key => key.kid === header.kid
  );

  // Firebase signing keys rotate. If a new kid appears while an edge still
  // has the old key set, bypass the cache once instead of denying TURN for
  // an otherwise valid newly-issued token.
  if (!jwk) {
    jwks = await loadJwks(0);
    jwk = (jwks.keys || []).find(
      key => key.kid === header.kid
    );
  }
  if (!jwk) throw new Error("kid");

  const key = await crypto.subtle.importKey(
    "jwk",
    jwk,
    {
      name: "RSASSA-PKCS1-v1_5",
      hash: "SHA-256"
    },
    false,
    ["verify"]
  );

  const valid = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    key,
    b64url(parts[2]),
    new TextEncoder().encode(parts[0] + "." + parts[1])
  );
  if (!valid) throw new Error("signature");

  const now = Math.floor(Date.now() / 1000);
  if (
    payload.aud !== "aaris-control" ||
    payload.iss !==
      "https://securetoken.google.com/aaris-control" ||
    typeof payload.sub !== "string" ||
    payload.sub.length === 0 ||
    payload.exp <= now ||
    payload.iat > now + 60 ||
    typeof payload.auth_time !== "number" ||
    payload.auth_time > now + 60
  ) {
    throw new Error("claims");
  }

  return payload;
}

async function authorizeSession(sessionId, token, uid) {
  if (!/^[0-9a-f-]{36}$/i.test(sessionId)) return false;

  const endpoint =
    "https://aaris-control-default-rtdb.asia-southeast1." +
    "firebasedatabase.app/sessions/" +
    encodeURIComponent(sessionId) +
    ".json?auth=" +
    encodeURIComponent(token);

  const response = await fetch(endpoint, {
    headers: {
      "Cache-Control": "no-store"
    }
  });
  if (!response.ok) return false;

  const session = await response.json();
  if (!session || typeof session !== "object") return false;
  if (
    session.hostUid !== uid &&
    session.controllerUid !== uid
  ) {
    return false;
  }

  return (
    session.state === "SCREEN_READY" ||
    session.state === "LIVE"
  );
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (
      request.method !== "POST" ||
      url.pathname !== "/v1/ice"
    ) {
      return new Response("Not found", { status: 404 });
    }

    const auth = request.headers.get("Authorization") || "";
    if (
      !auth.startsWith("Bearer ") ||
      auth.length > 10_000
    ) {
      return Response.json(
        { error: "unauthorized" },
        { status: 401 }
      );
    }
    const token = auth.slice(7);

    let claims;
    try {
      claims = await verifyFirebaseToken(token);
    } catch {
      return Response.json(
        { error: "unauthorized" },
        { status: 401 }
      );
    }

    let sessionId = "";
    try {
      const body = await request.json();
      sessionId =
        typeof body.sessionId === "string"
          ? body.sessionId
          : "";
    } catch {
      return Response.json(
        { error: "bad_request" },
        { status: 400 }
      );
    }

    if (
      !(await authorizeSession(
        sessionId,
        token,
        claims.sub
      ))
    ) {
      return Response.json(
        { error: "forbidden" },
        { status: 403 }
      );
    }

    if (!env.TURN_KEY_ID || !env.TURN_KEY_SECRET) {
      return Response.json(
        { error: "not_configured" },
        { status: 503 }
      );
    }

    const upstream = await fetch(
      "https://rtc.live.cloudflare.com/v1/turn/keys/" +
        env.TURN_KEY_ID +
        "/credentials/generate-ice-servers",
      {
        method: "POST",
        headers: {
          Authorization: "Bearer " + env.TURN_KEY_SECRET,
          "Content-Type": "application/json"
        },
        body: JSON.stringify({
          ttl: 21600,
          customIdentifier:
            claims.sub + ":" + sessionId.slice(0, 8)
        })
      }
    );

    if (!upstream.ok) {
      return Response.json(
        { error: "turn_unavailable" },
        {
          status: 502,
          headers: {
            "Cache-Control": "no-store"
          }
        }
      );
    }

    return new Response(await upstream.text(), {
      status: 200,
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": "no-store"
      }
    });
  }
};

import { createHmac, randomInt, randomUUID } from "node:crypto";
import { initializeApp } from "firebase-admin/app";
import { getDatabase } from "firebase-admin/database";
import { defineSecret } from "firebase-functions/params";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { setGlobalOptions } from "firebase-functions/v2/options";

initializeApp();

setGlobalOptions({
  region: "asia-south1",
  maxInstances: 100,
  concurrency: 40
});

const PAIRING_PEPPER = defineSecret("PAIRING_PEPPER");

const CODE_TTL_MS = 5 * 60_000;
const REDEEM_WINDOW_MS = 60_000;
const MAX_REDEEMS_PER_WINDOW = 8;
const CONNECT_SETUP_TTL_MS = 3 * 60_000;
const ICE_CONFIG_TTL_SECONDS = 60 * 60;
const DEFAULT_STUN_URLS = [
  "stun:stun.l.google.com:19302",
  "stun:stun1.l.google.com:19302"
];

type SessionState =
  | "CODE_ACTIVE"
  | "PAIR_PENDING"
  | "HOST_APPROVED"
  | "SCREEN_READY"
  | "CONNECTING"
  | "LIVE"
  | "CLOSED";

interface PairingCodeRecord {
  sessionId: string;
  hostUid: string;
  expiresAtMs: number;
  state: "ACTIVE" | "RESERVED";
  reservedBy?: string;
  reservedAtMs?: number;
}

interface RedeemRateRecord {
  windowStartMs: number;
  count: number;
}

function requireUid(uid?: string): string {
  if (!uid) {
    throw new HttpsError("unauthenticated", "Authentication is required.");
  }
  return uid;
}

function requireString(value: unknown, name: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new HttpsError("invalid-argument", name + " is required.");
  }
  return value;
}

async function requireActiveSessionParticipant(
  sessionId: string,
  uid: string
): Promise<void> {
  const snap = await getDatabase()
    .ref("sessions/" + sessionId)
    .get();

  if (!snap.exists()) {
    throw new HttpsError("not-found", "Session not found.");
  }

  const session = snap.val() as {
    hostUid?: string;
    controllerUid?: string;
    state?: SessionState;
  };

  if (uid !== session.hostUid && uid !== session.controllerUid) {
    throw new HttpsError(
      "permission-denied",
      "Only session participants can request relay credentials."
    );
  }

  if (session.state !== "SCREEN_READY" && session.state !== "LIVE") {
    throw new HttpsError(
      "failed-precondition",
      "Session is not ready for transport."
    );
  }
}

function normalizeCode(value: unknown): string {
  if (typeof value !== "string") {
    throw new HttpsError("invalid-argument", "Enter the 6-digit code.");
  }
  const code = value.replace(/\D/g, "");
  if (!/^\d{6}$/.test(code)) {
    throw new HttpsError("invalid-argument", "Enter the 6-digit code.");
  }
  return code;
}

function lookupKey(code: string): string {
  return createHmac("sha256", PAIRING_PEPPER.value())
    .update(code)
    .digest("hex");
}

function configuredTurnUrls(): string[] {
  return (process.env.TURN_URLS ?? "")
    .split(",")
    .map((value) => value.trim())
    .filter((value) => /^turns?:/i.test(value))
    .slice(0, 8);
}

async function clearActiveHostSessionIfMatches(
  hostUid: string,
  sessionId: string
): Promise<void> {
  const ref = getDatabase().ref("activeHostSession/" + hostUid);
  await ref.transaction((current) => {
    return current === sessionId ? null : current;
  }, undefined, false);
}

async function enforceRedeemRate(uid: string): Promise<void> {
  const db = getDatabase();
  const ref = db.ref("redeemRate/" + uid);
  const now = Date.now();
  let blocked = false;

  const tx = await ref.transaction((raw) => {
    const current = raw as RedeemRateRecord | null;

    if (
      current === null ||
      now - current.windowStartMs >= REDEEM_WINDOW_MS
    ) {
      return {
        windowStartMs: now,
        count: 1
      } satisfies RedeemRateRecord;
    }

    if (current.count >= MAX_REDEEMS_PER_WINDOW) {
      blocked = true;
      return;
    }

    return {
      windowStartMs: current.windowStartMs,
      count: current.count + 1
    } satisfies RedeemRateRecord;
  }, undefined, false);

  if (blocked || !tx.committed) {
    throw new HttpsError(
      "resource-exhausted",
      "Too many pairing attempts. Try again shortly."
    );
  }
}

function clearSessionTransport(
  updates: Record<string, unknown>,
  sessionId: string
): void {
  const prefix = "sessions/" + sessionId + "/";
  updates[prefix + "hostSignal"] = null;
  updates[prefix + "controllerSignal"] = null;
  updates[prefix + "hostCandidates"] = null;
  updates[prefix + "controllerCandidates"] = null;
  updates[prefix + "presence"] = null;
}

async function closeExistingHostSession(hostUid: string): Promise<void> {
  const db = getDatabase();
  const activeRef = db.ref("activeHostSession/" + hostUid);
  const activeSnap = await activeRef.get();
  const previousSessionId = activeSnap.val();

  if (
    typeof previousSessionId !== "string" ||
    previousSessionId.length === 0
  ) {
    return;
  }

  const codeSnap = await db
    .ref("serverSessionCodes/" + previousSessionId)
    .get();
  const previousCodeKey = codeSnap.val();

  const updates: Record<string, unknown> = {};
  updates["sessions/" + previousSessionId + "/state"] = "CLOSED";
  updates["sessions/" + previousSessionId + "/closedAtMs"] = Date.now();
  updates["serverSessionCodes/" + previousSessionId] = null;
  clearSessionTransport(updates, previousSessionId);

  if (typeof previousCodeKey === "string") {
    updates["pairingCodes/" + previousCodeKey] = null;
  }

  await db.ref().update(updates);
  await clearActiveHostSessionIfMatches(hostUid, previousSessionId);
}

export const getIceConfig = onCall(
  {
    enforceAppCheck: true
  },
  async (request) => {
    const uid = requireUid(request.auth?.uid);
    const sessionId = requireString(
      request.data?.sessionId,
      "sessionId"
    );
    await requireActiveSessionParticipant(sessionId, uid);

    const iceServers: Array<{
      urls: string[];
      username?: string;
      credential?: string;
    }> = [
      { urls: DEFAULT_STUN_URLS }
    ];

    const turnUrls = configuredTurnUrls();
    const turnSecret = (process.env.TURN_SHARED_SECRET ?? "").trim();
    let expiresAtMs = 0;

    if (turnUrls.length > 0 && turnSecret.length >= 16) {
      const expiresAtSeconds =
        Math.floor(Date.now() / 1000) + ICE_CONFIG_TTL_SECONDS;
      const username = expiresAtSeconds + ":" + uid;
      const credential = createHmac("sha1", turnSecret)
        .update(username)
        .digest("base64");

      iceServers.push({
        urls: turnUrls,
        username,
        credential
      });
      expiresAtMs = expiresAtSeconds * 1000;
    }

    return {
      iceServers,
      expiresAtMs
    };
  }
);

export const createPairingSession = onCall(
  {
    secrets: [PAIRING_PEPPER],
    enforceAppCheck: true
  },
  async (request) => {
    const hostUid = requireUid(request.auth?.uid);
    const db = getDatabase();

    await closeExistingHostSession(hostUid);

    for (let attempt = 0; attempt < 12; attempt += 1) {
      const code = String(randomInt(100000, 1000000));
      const key = lookupKey(code);
      const sessionId = randomUUID();
      const now = Date.now();
      const expiresAtMs = now + CODE_TTL_MS;
      const codeRef = db.ref("pairingCodes/" + key);

      const transaction = await codeRef.transaction((existing) => {
        if (existing !== null) return;

        const record: PairingCodeRecord = {
          sessionId,
          hostUid,
          expiresAtMs,
          state: "ACTIVE"
        };
        return record;
      }, undefined, false);

      if (!transaction.committed) continue;

      const updates: Record<string, unknown> = {};
      updates["sessions/" + sessionId] = {
        hostUid,
        state: "CODE_ACTIVE" satisfies SessionState,
        createdAtMs: now,
        expiresAtMs,
        displayGeneration: 0
      };
      updates["serverSessionCodes/" + sessionId] = key;
      updates["activeHostSession/" + hostUid] = sessionId;

      try {
        await db.ref().update(updates);
      } catch (error) {
        await codeRef.transaction((raw) => {
          const current = raw as PairingCodeRecord | null;
          if (
            current === null ||
            current.sessionId !== sessionId ||
            current.hostUid !== hostUid
          ) {
            return;
          }
          return null;
        }, undefined, false).catch(() => undefined);

        throw error;
      }

      return {
        sessionId,
        code,
        expiresAtMs,
        expiresAt: expiresAtMs
      };
    }

    throw new HttpsError(
      "resource-exhausted",
      "Could not allocate a pairing code. Try again."
    );
  }
);

export const redeemPairingCode = onCall(
  {
    secrets: [PAIRING_PEPPER],
    enforceAppCheck: true
  },
  async (request) => {
    const controllerUid = requireUid(request.auth?.uid);
    await enforceRedeemRate(controllerUid);

    const code = normalizeCode(request.data?.code);
    const key = lookupKey(code);
    const db = getDatabase();
    const now = Date.now();
    const codeRef = db.ref("pairingCodes/" + key);

    let failure: "not-found" | "expired" | "busy" | "self" | null = null;

    const tx = await codeRef.transaction((raw) => {
      if (raw === null) {
        failure = "not-found";
        return;
      }

      const record = raw as PairingCodeRecord;

      if (record.hostUid === controllerUid) {
        failure = "self";
        return;
      }

      if (record.expiresAtMs <= now) {
        failure = "expired";
        return null;
      }

      if (
        record.state === "RESERVED" &&
        record.reservedBy !== controllerUid
      ) {
        failure = "busy";
        return;
      }

      return {
        ...record,
        state: "RESERVED",
        reservedBy: controllerUid,
        reservedAtMs: record.reservedAtMs ?? now
      } satisfies PairingCodeRecord;
    }, undefined, false);

    if (failure === "self") {
      throw new HttpsError(
        "failed-precondition",
        "Use this code from the other phone."
      );
    }
    if (failure === "busy") {
      throw new HttpsError(
        "already-exists",
        "That code is already being used."
      );
    }
    if (failure === "expired") {
      throw new HttpsError("deadline-exceeded", "Code expired.");
    }
    if (failure === "not-found" || !tx.committed) {
      throw new HttpsError("not-found", "Code expired or invalid.");
    }

    const record = tx.snapshot.val() as PairingCodeRecord | null;
    if (!record?.sessionId || !record.hostUid) {
      throw new HttpsError("not-found", "Code expired or invalid.");
    }

    const sessionRef = db.ref("sessions/" + record.sessionId);
    let sessionFailure:
      | "not-found"
      | "expired"
      | "state"
      | "busy"
      | null = null;

    let sessionTx;
    try {
      sessionTx = await sessionRef.transaction((raw) => {
        sessionFailure = null;

        if (raw === null) {
          sessionFailure = "not-found";
          return;
        }

        const session = raw as {
          state?: SessionState;
          expiresAtMs?: number;
          controllerUid?: string;
          pairedAtMs?: number;
          [key: string]: unknown;
        };

        if ((session.expiresAtMs ?? 0) <= now) {
          sessionFailure = "expired";
          return {
            ...session,
            state: "CLOSED" satisfies SessionState,
            closedAtMs: now
          };
        }

        if (
          session.state !== "CODE_ACTIVE" &&
          session.state !== "PAIR_PENDING"
        ) {
          sessionFailure = "state";
          return;
        }

        if (
          typeof session.controllerUid === "string" &&
          session.controllerUid !== controllerUid
        ) {
          sessionFailure = "busy";
          return;
        }

        return {
          ...session,
          controllerUid,
          state: "PAIR_PENDING" satisfies SessionState,
          pairedAtMs: session.pairedAtMs ?? now
        };
      }, undefined, false);
    } catch (error) {
      await codeRef.transaction((raw) => {
        const current = raw as PairingCodeRecord | null;
        if (
          current === null ||
          current.state !== "RESERVED" ||
          current.reservedBy !== controllerUid
        ) {
          return;
        }

        return {
          sessionId: current.sessionId,
          hostUid: current.hostUid,
          expiresAtMs: current.expiresAtMs,
          state: "ACTIVE"
        } satisfies PairingCodeRecord;
      }, undefined, false).catch(() => undefined);
      throw error;
    }

    if (sessionFailure === "expired" && sessionTx.committed) {
      const updates: Record<string, unknown> = {};
      updates["pairingCodes/" + key] = null;
      updates["serverSessionCodes/" + record.sessionId] = null;
      clearSessionTransport(updates, record.sessionId);
      await db.ref().update(updates);
      await clearActiveHostSessionIfMatches(
        record.hostUid,
        record.sessionId
      );
      throw new HttpsError("deadline-exceeded", "Code expired.");
    }

    if (!sessionTx.committed) {
      if (sessionFailure === "busy") {
        throw new HttpsError(
          "already-exists",
          "Session is already reserved."
        );
      }

      if (
        sessionFailure === "not-found" ||
        sessionFailure === "state"
      ) {
        await codeRef.remove();
        await db.ref(
          "serverSessionCodes/" + record.sessionId
        ).remove();
      }

      if (sessionFailure === "not-found") {
        throw new HttpsError(
          "not-found",
          "Session no longer exists."
        );
      }

      throw new HttpsError(
        "failed-precondition",
        "Session is no longer available."
      );
    }

    return {
      sessionId: record.sessionId,
      hostUid: record.hostUid
    };
  }
);

export const approvePairingSession = onCall(
  {
    secrets: [PAIRING_PEPPER],
    enforceAppCheck: true
  },
  async (request) => {
    const hostUid = requireUid(request.auth?.uid);
    const sessionId = requireString(
      request.data?.sessionId,
      "sessionId"
    );
    const ref = getDatabase().ref("sessions/" + sessionId);
    const now = Date.now();

    let failure:
      | "not-found"
      | "permission"
      | "state"
      | "expired"
      | null = null;

    const tx = await ref.transaction((raw) => {
      failure = null;

      if (raw === null) {
        failure = "not-found";
        return;
      }

      const session = raw as {
        hostUid?: string;
        controllerUid?: string;
        state?: SessionState;
        expiresAtMs?: number;
        [key: string]: unknown;
      };

      if (session.hostUid !== hostUid) {
        failure = "permission";
        return;
      }

      if ((session.expiresAtMs ?? 0) <= now) {
        failure = "expired";
        return;
      }

      if (!session.controllerUid || session.state !== "PAIR_PENDING") {
        failure = "state";
        return;
      }

      return {
        ...session,
        state: "HOST_APPROVED" satisfies SessionState,
        approvedAtMs: now,
        connectExpiresAtMs: now + CONNECT_SETUP_TTL_MS
      };
    }, undefined, false);

    if (!tx.committed) {
      if (failure === "not-found") {
        throw new HttpsError("not-found", "Session not found.");
      }
      if (failure === "permission") {
        throw new HttpsError(
          "permission-denied",
          "Only the sharing phone can approve."
        );
      }
      if (failure === "expired") {
        throw new HttpsError(
          "deadline-exceeded",
          "Pairing request expired. Create a new code."
        );
      }
      throw new HttpsError(
        "failed-precondition",
        "No valid connection request."
      );
    }

    return { ok: true };
  }
);

export const markScreenReady = onCall(
  {
    secrets: [PAIRING_PEPPER],
    enforceAppCheck: true
  },
  async (request) => {
    const hostUid = requireUid(request.auth?.uid);
    const sessionId = requireString(
      request.data?.sessionId,
      "sessionId"
    );
    const db = getDatabase();
    const ref = db.ref("sessions/" + sessionId);
    const now = Date.now();

    let failure:
      | "not-found"
      | "permission"
      | "state"
      | "expired"
      | null = null;

    const tx = await ref.transaction((raw) => {
      failure = null;

      if (raw === null) {
        failure = "not-found";
        return;
      }

      const session = raw as {
        hostUid?: string;
        state?: SessionState;
        connectExpiresAtMs?: number;
        [key: string]: unknown;
      };

      if (session.hostUid !== hostUid) {
        failure = "permission";
        return;
      }

      if ((session.connectExpiresAtMs ?? 0) <= now) {
        failure = "expired";
        return;
      }

      if (session.state !== "HOST_APPROVED") {
        failure = "state";
        return;
      }

      return {
        ...session,
        state: "SCREEN_READY" satisfies SessionState,
        screenReadyAtMs: now
      };
    }, undefined, false);

    if (!tx.committed) {
      if (failure === "not-found") {
        throw new HttpsError("not-found", "Session not found.");
      }
      if (failure === "permission") {
        throw new HttpsError(
          "permission-denied",
          "Only the sharing phone can start."
        );
      }
      if (failure === "expired") {
        throw new HttpsError(
          "deadline-exceeded",
          "Connection setup expired. Create a new code."
        );
      }
      throw new HttpsError(
        "failed-precondition",
        "Session was not approved."
      );
    }

    const codeSnap = await db
      .ref("serverSessionCodes/" + sessionId)
      .get();
    const key = codeSnap.val();

    const updates: Record<string, unknown> = {};
    updates["serverSessionCodes/" + sessionId] = null;

    if (typeof key === "string") {
      updates["pairingCodes/" + key] = null;
    }

    await db.ref().update(updates);
    return { ok: true };
  }
);

export const closePairingSession = onCall(
  {
    secrets: [PAIRING_PEPPER],
    enforceAppCheck: true
  },
  async (request) => {
    const uid = requireUid(request.auth?.uid);
    const sessionId = requireString(
      request.data?.sessionId,
      "sessionId"
    );
    const db = getDatabase();
    const ref = db.ref("sessions/" + sessionId);
    const snap = await ref.get();

    if (!snap.exists()) {
      return { ok: true };
    }

    const session = snap.val() as {
      hostUid?: string;
      controllerUid?: string;
    };

    if (uid !== session.hostUid && uid !== session.controllerUid) {
      throw new HttpsError(
        "permission-denied",
        "Not a session participant."
      );
    }

    const codeSnap = await db
      .ref("serverSessionCodes/" + sessionId)
      .get();
    const key = codeSnap.val();

    const updates: Record<string, unknown> = {};
    updates["sessions/" + sessionId + "/state"] = "CLOSED";
    updates["sessions/" + sessionId + "/closedAtMs"] = Date.now();
    updates["serverSessionCodes/" + sessionId] = null;
    clearSessionTransport(updates, sessionId);

    if (typeof key === "string") {
      updates["pairingCodes/" + key] = null;
    }
    await db.ref().update(updates);
    if (typeof session.hostUid === "string") {
      await clearActiveHostSessionIfMatches(
        session.hostUid,
        sessionId
      );
    }
    return { ok: true };
  }
);


export const markSessionLive = onCall(
  {
    secrets: [PAIRING_PEPPER],
    enforceAppCheck: true
  },
  async (request) => {
    const hostUid = requireUid(request.auth?.uid);
    const sessionId = requireString(
      request.data?.sessionId,
      "sessionId"
    );
    const ref = getDatabase().ref("sessions/" + sessionId);
    const now = Date.now();

    let failure:
      | "not-found"
      | "permission"
      | "state"
      | "expired"
      | null = null;

    const tx = await ref.transaction((raw) => {
      failure = null;

      if (raw === null) {
        failure = "not-found";
        return;
      }

      const session = raw as {
        hostUid?: string;
        controllerUid?: string;
        state?: SessionState;
        connectExpiresAtMs?: number;
        [key: string]: unknown;
      };

      if (session.hostUid !== hostUid) {
        failure = "permission";
        return;
      }

      if ((session.connectExpiresAtMs ?? 0) <= now) {
        failure = "expired";
        return;
      }

      if (!session.controllerUid || session.state !== "SCREEN_READY") {
        failure = "state";
        return;
      }

      return {
        ...session,
        state: "LIVE" satisfies SessionState,
        liveAtMs: now
      };
    }, undefined, false);

    if (!tx.committed) {
      if (failure === "not-found") {
        throw new HttpsError("not-found", "Session not found.");
      }
      if (failure === "permission") {
        throw new HttpsError(
          "permission-denied",
          "Only the sharing phone can mark the session live."
        );
      }
      if (failure === "expired") {
        throw new HttpsError(
          "deadline-exceeded",
          "Connection setup expired. Create a new code."
        );
      }
      throw new HttpsError(
        "failed-precondition",
        "Session is not ready for live transport."
      );
    }

    return { ok: true };
  }
);

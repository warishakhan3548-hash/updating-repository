import { randomInt, randomUUID } from "node:crypto";
import { initializeApp } from "firebase-admin/app";
import { getDatabase } from "firebase-admin/database";
import { HttpsError, onCall } from "firebase-functions/v2/https";

initializeApp();

const db = getDatabase();

const CODE_TTL_MS = 90_000;
const CREATE_MIN_INTERVAL_MS = 2_500;
const REDEEM_MIN_INTERVAL_MS = 750;
const MAX_CODE_ATTEMPTS = 12;

type PairingCodeRecord = {
  sessionId: string;
  hostUid: string;
  controllerUid?: string;
  status: "OPEN" | "CLAIMED" | "USED" | "CLOSED";
  expiresAt: number;
};

type SessionRecord = {
  hostUid: string;
  controllerUid?: string;
  state:
    | "CODE_ACTIVE"
    | "PAIR_PENDING"
    | "HOST_APPROVED"
    | "SCREEN_CONSENT"
    | "CONNECTING"
    | "LIVE"
    | "CLOSED";
  createdAt: number;
  updatedAt: number;
  expiresAt: number;
};

function requireUid(request: { auth?: { uid: string } | null }): string {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign in before starting a remote-support session.");
  }
  return uid;
}

async function throttle(uid: string, bucket: string, minIntervalMs: number): Promise<void> {
  const now = Date.now();
  const ref = db.ref(`rateLimits/${uid}/${bucket}`);
  const result = await ref.transaction((last: number | null) => {
    if (typeof last === "number" && now - last < minIntervalMs) return;
    return now;
  }, undefined, false);

  if (!result.committed) {
    throw new HttpsError("resource-exhausted", "Too many requests. Try again shortly.");
  }
}

async function claimFreshCode(hostUid: string, sessionId: string, expiresAt: number): Promise<string> {
  for (let attempt = 0; attempt < MAX_CODE_ATTEMPTS; attempt += 1) {
    const code = randomInt(100_000, 1_000_000).toString();
    const ref = db.ref(`pairingCodes/${code}`);
    const result = await ref.transaction((current: PairingCodeRecord | null) => {
      if (current != null && current.expiresAt > Date.now()) return;
      const next: PairingCodeRecord = {
        sessionId,
        hostUid,
        status: "OPEN",
        expiresAt
      };
      return next;
    }, undefined, false);

    if (result.committed) return code;
  }
  throw new HttpsError("resource-exhausted", "Could not allocate a pairing code. Try again.");
}

export const createPairingSession = onCall(
  { enforceAppCheck: true, consumeAppCheckToken: true },
  async (request) => {
    const hostUid = requireUid(request);
    await throttle(hostUid, "createPairingSession", CREATE_MIN_INTERVAL_MS);

    const now = Date.now();
    const sessionId = randomUUID();
    const expiresAt = now + CODE_TTL_MS;
    const code = await claimFreshCode(hostUid, sessionId, expiresAt);

    const session: SessionRecord = {
      hostUid,
      state: "CODE_ACTIVE",
      createdAt: now,
      updatedAt: now,
      expiresAt
    };

    try {
      await db.ref().update({
        [`sessions/${sessionId}`]: session,
        [`sessionSecrets/${sessionId}/pairingCode`]: code
      });
    } catch (error) {
      await db.ref(`pairingCodes/${code}`).remove().catch(() => undefined);
      throw error;
    }

    return { sessionId, code, expiresAt };
  }
);

export const redeemPairingCode = onCall(
  { enforceAppCheck: true, consumeAppCheckToken: true },
  async (request) => {
    const controllerUid = requireUid(request);
    await throttle(controllerUid, "redeemPairingCode", REDEEM_MIN_INTERVAL_MS);

    const code = String(request.data?.code ?? "").replace(/\D/g, "");
    if (!/^\d{6}$/.test(code)) {
      throw new HttpsError("invalid-argument", "Enter a valid six-digit code.");
    }

    const codeRef = db.ref(`pairingCodes/${code}`);
    let claimed: PairingCodeRecord | null = null;

    const result = await codeRef.transaction((current: PairingCodeRecord | null) => {
      if (!current) return;
      if (current.expiresAt <= Date.now()) return;
      if (current.status !== "OPEN") return;
      if (current.hostUid === controllerUid) return;

      const next: PairingCodeRecord = {
        ...current,
        status: "CLAIMED",
        controllerUid
      };
      claimed = next;
      return next;
    }, undefined, false);

    if (!result.committed || !claimed) {
      throw new HttpsError("not-found", "That code is invalid, expired, or already used.");
    }

    const record = claimed as PairingCodeRecord;
    const sessionRef = db.ref(`sessions/${record.sessionId}`);
    const sessionSnap = await sessionRef.get();
    const session = sessionSnap.val() as SessionRecord | null;

    if (!session || session.hostUid !== record.hostUid || session.expiresAt <= Date.now()) {
      await codeRef.update({ status: "CLOSED" });
      throw new HttpsError("failed-precondition", "This session is no longer available.");
    }

    await sessionRef.update({
      controllerUid,
      state: "PAIR_PENDING",
      updatedAt: Date.now()
    });

    return {
      sessionId: record.sessionId,
      hostUid: record.hostUid
    };
  }
);

export const approvePairingSession = onCall(
  { enforceAppCheck: true, consumeAppCheckToken: true },
  async (request) => {
    const hostUid = requireUid(request);
    const sessionId = String(request.data?.sessionId ?? "");
    if (!sessionId) throw new HttpsError("invalid-argument", "Missing sessionId.");

    const sessionRef = db.ref(`sessions/${sessionId}`);
    const snap = await sessionRef.get();
    const session = snap.val() as SessionRecord | null;

    if (!session || session.hostUid !== hostUid) {
      throw new HttpsError("permission-denied", "Only the sharing device can approve.");
    }
    if (session.state !== "PAIR_PENDING" || !session.controllerUid) {
      throw new HttpsError("failed-precondition", "No pending controller is waiting.");
    }

    const codeSnap = await db.ref(`sessionSecrets/${sessionId}/pairingCode`).get();
    const code = codeSnap.val();
    if (typeof code !== "string") {
      throw new HttpsError("failed-precondition", "Pairing code record is missing.");
    }

    const now = Date.now();
    await db.ref().update({
      [`sessions/${sessionId}/state`]: "HOST_APPROVED",
      [`sessions/${sessionId}/updatedAt`]: now,
      [`pairingCodes/${code}/status`]: "USED"
    });

    return { sessionId, approved: true };
  }
);

export const beginHostConnection = onCall(
  { enforceAppCheck: true, consumeAppCheckToken: true },
  async (request) => {
    const hostUid = requireUid(request);
    const sessionId = String(request.data?.sessionId ?? "");
    if (!sessionId) throw new HttpsError("invalid-argument", "Missing sessionId.");

    const sessionRef = db.ref(`sessions/${sessionId}`);
    const snap = await sessionRef.get();
    const session = snap.val() as SessionRecord | null;

    if (!session || session.hostUid !== hostUid) {
      throw new HttpsError("permission-denied", "Only the sharing device can start capture.");
    }
    if (session.state !== "HOST_APPROVED" || !session.controllerUid) {
      throw new HttpsError("failed-precondition", "Session is not ready to connect.");
    }

    await sessionRef.update({
      state: "CONNECTING",
      updatedAt: Date.now()
    });
    return { sessionId, connecting: true };
  }
);

export const closePairingSession = onCall(
  { enforceAppCheck: true, consumeAppCheckToken: true },
  async (request) => {
    const uid = requireUid(request);
    const sessionId = String(request.data?.sessionId ?? "");
    if (!sessionId) throw new HttpsError("invalid-argument", "Missing sessionId.");

    const sessionRef = db.ref(`sessions/${sessionId}`);
    const snap = await sessionRef.get();
    const session = snap.val() as SessionRecord | null;

    if (!session || (session.hostUid !== uid && session.controllerUid !== uid)) {
      throw new HttpsError("permission-denied", "You are not part of this session.");
    }

    const codeSnap = await db.ref(`sessionSecrets/${sessionId}/pairingCode`).get();
    const code = codeSnap.val();
    const updates: Record<string, unknown> = {
      [`sessions/${sessionId}/state`]: "CLOSED",
      [`sessions/${sessionId}/updatedAt`]: Date.now(),
      [`signals/${sessionId}`]: null,
      [`presence/${sessionId}`]: null,
      [`sessionSecrets/${sessionId}`]: null
    };
    if (typeof code === "string") updates[`pairingCodes/${code}`] = null;

    await db.ref().update(updates);
    return { sessionId, closed: true };
  }
);

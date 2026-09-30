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

const CODE_TTL_MS = 120_000;
const REDEEM_WINDOW_MS = 60_000;
const MAX_REDEEMS_PER_WINDOW = 8;

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
  updates["activeHostSession/" + hostUid] = null;

  if (typeof previousCodeKey === "string") {
    updates["pairingCodes/" + previousCodeKey] = null;
  }

  await db.ref().update(updates);
}

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

      await db.ref().update(updates);

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
    const sessionSnap = await sessionRef.get();

    if (!sessionSnap.exists()) {
      await codeRef.remove();
      throw new HttpsError("not-found", "Session no longer exists.");
    }

    const session = sessionSnap.val() as {
      state?: SessionState;
      expiresAtMs?: number;
      controllerUid?: string;
    };

    if (
      session.state !== "CODE_ACTIVE" &&
      session.state !== "PAIR_PENDING"
    ) {
      throw new HttpsError(
        "failed-precondition",
        "Session is no longer available."
      );
    }

    if ((session.expiresAtMs ?? 0) <= now) {
      const updates: Record<string, unknown> = {};
      updates["sessions/" + record.sessionId + "/state"] = "CLOSED";
      updates["sessions/" + record.sessionId + "/closedAtMs"] = now;
      updates["pairingCodes/" + key] = null;
      updates["serverSessionCodes/" + record.sessionId] = null;
      await db.ref().update(updates);
      throw new HttpsError("deadline-exceeded", "Code expired.");
    }

    if (
      typeof session.controllerUid === "string" &&
      session.controllerUid !== controllerUid
    ) {
      throw new HttpsError(
        "already-exists",
        "Session is already reserved."
      );
    }

    await sessionRef.update({
      controllerUid,
      state: "PAIR_PENDING" satisfies SessionState,
      pairedAtMs: now
    });

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
        [key: string]: unknown;
      };

      if (session.hostUid !== hostUid) {
        failure = "permission";
        return;
      }

      if (!session.controllerUid || session.state !== "PAIR_PENDING") {
        failure = "state";
        return;
      }

      return {
        ...session,
        state: "HOST_APPROVED" satisfies SessionState,
        approvedAtMs: now
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
        [key: string]: unknown;
      };

      if (session.hostUid !== hostUid) {
        failure = "permission";
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

    if (typeof key === "string") {
      updates["pairingCodes/" + key] = null;
    }
    if (typeof session.hostUid === "string") {
      updates["activeHostSession/" + session.hostUid] = null;
    }

    await db.ref().update(updates);
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
        [key: string]: unknown;
      };

      if (session.hostUid !== hostUid) {
        failure = "permission";
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
      throw new HttpsError(
        "failed-precondition",
        "Session is not ready for live transport."
      );
    }

    return { ok: true };
  }
);

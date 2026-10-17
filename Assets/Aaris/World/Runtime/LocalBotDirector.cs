using System;
using UnityEngine;
using UnityEngine.SceneManagement;

namespace Aaris.World
{
    [Serializable]
    public sealed class LocalBotUnit
    {
        public Transform actor;
        public Damageable health;
        [NonSerialized] public Vector3 origin;
        [NonSerialized] public Quaternion facing;
        [NonSerialized] public Vector3 desired;
        [NonSerialized] public double nextDecision;
        [NonSerialized] public double nextShot;
        [NonSerialized] public double nextZoneDamage;
        [NonSerialized] public double nextFarStep;
    }

    // One AI scheduler for the whole offline match, not 100 individual Update loops
    // or 100 dynamic Rigidbodies. World collision remains authoritative locally.
    [DefaultExecutionOrder(10)]
    public sealed class LocalBotDirector : MonoBehaviour
    {
        public SandboxSession session;
        public LocalBotUnit[] units = Array.Empty<LocalBotUnit>();
        private readonly int[] nearest = new int[24];
        private readonly float[] nearestDistance = new float[24];
        private TerrainSampler ground;
        private double nextResultCheck;
        public int Alive
        {
            get
            {
                int count = 0;
                foreach (var b in units) if (b != null && b.health != null && !b.health.Dead) count++;
                return count;
            }
        }
        private void Start()
        {
            if (session == null || session.world == null) { enabled = false; return; }
            ground = new TerrainSampler(session.world);
            for (int i = 0; i < units.Length; i++)
            {
                var b = units[i];
                if (b == null || b.actor == null || b.health == null) { enabled = false; Debug.LogError("Invalid local bot binding."); return; }
                b.origin = b.actor.position;
                b.facing = b.actor.rotation;
                b.desired = Vector3.zero;
                b.nextDecision = i * 0.035;
                b.nextShot = i * 0.09;
                b.nextZoneDamage = 1;
                b.nextFarStep = i * 0.025;
            }
        }
        public void ResetBots()
        {
            if (ground == null || units == null) return;
            foreach (var b in units)
            {
                if (b == null || b.actor == null || b.health == null) continue;
                b.actor.SetPositionAndRotation(b.origin, b.facing);
                b.health.ResetHealth();
                b.desired = Vector3.zero; b.nextDecision = 0; b.nextShot = 0;
                b.nextZoneDamage = 1; b.nextFarStep = 0;
            }
            nextResultCheck = 0;
            Physics.SyncTransforms(); // One explicit batch after scene-wide reset.
        }
        private void FixedUpdate()
        {
            if (ground == null || session == null || session.pawn == null || session.MatchEnded) return;
            var cfg = session.settings.bots;
            if (cfg == null || !cfg.enabled) return;
            double now = Time.fixedTimeAsDouble;
            Vector3 player = session.pawn.Body.position;
            float nearSq = (float)(cfg.nearRange * cfg.nearRange);
            int closeCount = 0;
            // Select nearest visible-budget actors without allocating or sorting all 100.
            for (int i = 0; i < units.Length; i++)
            {
                var b = units[i];
                if (b.health.Dead) continue;
                Vector3 separation = b.actor.position - player;
                float d2 = separation.x * separation.x + separation.z * separation.z;
                if (d2 >= nearSq) continue;
                int place = closeCount;
                while (place > 0 && d2 < nearestDistance[place - 1]) place--;
                if (place >= cfg.maxCloseSimulated) continue;
                int end = Mathf.Min(closeCount, cfg.maxCloseSimulated - 1);
                for (int j = end; j > place; j--)
                {
                    nearest[j] = nearest[j - 1]; nearestDistance[j] = nearestDistance[j - 1];
                }
                nearest[place] = i; nearestDistance[place] = d2;
                closeCount = Mathf.Min(closeCount + 1, cfg.maxCloseSimulated);
            }
            bool changed = false;
            var physics = gameObject.scene.GetPhysicsScene();
            for (int i = 0; i < units.Length; i++)
            {
                var b = units[i];
                if (b.health.Dead) continue;
                if (session.settings.zone != null && session.settings.zone.enabled && now >= b.nextZoneDamage)
                {
                    b.nextZoneDamage = now + 1;
                    Vector3 p = b.actor.position;
                    if (session.CurrentZone.Outside(p.x, p.z, 0.5))
                        b.health.Apply((float)session.settings.zone.damagePerSecond);
                    if (b.health.Dead) continue;
                }
                bool close = false;
                for (int k = 0; k < closeCount; k++)
                    if (nearest[k] == i) { close = true; break; }
                if (!close && now < b.nextFarStep) continue;
                if (close)
                {
                    if (now >= b.nextDecision)
                    {
                        b.nextDecision = now + 0.25 + (i % 5) * 0.015;
                        b.desired = SelectDirection(b.actor.position, player, cfg.nearRange);
                    }
                    changed |= Move(b, b.desired, (float)(cfg.moveSpeed * Time.fixedDeltaTime), physics);
                    TryShoot(b, player, now, cfg, physics);
                }
                else
                {
                    b.nextFarStep = now + 0.8 + (i % 7) * 0.06;
                    Vector3 zone = session.settings.zone != null && session.settings.zone.enabled
                        ? new Vector3((float)session.CurrentZone.x, player.y, (float)session.CurrentZone.z)
                        : player;
                    Vector3 direction = SelectDirection(b.actor.position, zone, cfg.nearRange);
                    // Coarse off-screen simulation: small, capped movement, no shooting.
                    changed |= Move(b, direction, (float)Math.Min(3.5, cfg.moveSpeed * 0.85), physics);
                }
            }
            if (changed) Physics.SyncTransforms(); // Single batch sync, not per agent.
            if (now >= nextResultCheck)
            {
                nextResultCheck = now + 0.25;
                if (Alive == 0) session.EndLocalMatch(true);
            }
        }
        private static Vector3 SelectDirection(Vector3 from, Vector3 goal, double nearRange)
        {
            Vector3 d = goal - from; d.y = 0;
            float len = d.magnitude;
            return len > 2 ? d / len : Vector3.zero;
        }
        private bool Move(LocalBotUnit b, Vector3 wish, float step, PhysicsScene scene)
        {
            if (wish.sqrMagnitude < 0.001f || step <= 0) return false;
            Vector3 from = b.actor.position;
            Vector3 chest = from + Vector3.up;
            Vector3 direction = wish;
            int solid = (1 << SandboxLayers.World) | (1 << SandboxLayers.Prop);
            float clearance = step + 0.85f;
            if (scene.Raycast(chest, wish, clearance, solid, QueryTriggerInteraction.Ignore))
            {
                Vector3 left = new Vector3(-wish.z, 0, wish.x);
                Vector3 right = -left;
                if (!scene.Raycast(chest, left, clearance, solid, QueryTriggerInteraction.Ignore)) direction = left;
                else if (!scene.Raycast(chest, right, clearance, solid, QueryTriggerInteraction.Ignore)) direction = right;
                else return false;
            }
            Vector3 p = from + direction * step;
            float minX = session.worldMin.x + 1, maxX = session.worldMax.x - 1;
            float minZ = session.worldMin.y + 1, maxZ = session.worldMax.y - 1;
            if (p.x <= minX || p.x >= maxX || p.z <= minZ || p.z >= maxZ) return false;
            float height = (float)ground.Height(p.x, p.z) + 0.12f;
            if (Mathf.Abs(height - from.y) > Mathf.Max(0.5f, step * 0.8f)) return false;
            p.y = height;
            b.actor.SetPositionAndRotation(p, Quaternion.LookRotation(direction, Vector3.up));
            return true;
        }
        private void TryShoot(LocalBotUnit b, Vector3 player, double now, BotSpec cfg, PhysicsScene scene)
        {
            if (now < b.nextShot || session.MatchEnded) return;
            b.nextShot = now + cfg.shotInterval + (b.actor.GetSiblingIndex() % 5) * 0.13;
            Vector3 start = b.actor.position + Vector3.up * 1.4f;
            Vector3 end = player + Vector3.up * 1.1f;
            Vector3 to = end - start;
            float distance = to.magnitude;
            if (distance < 3 || distance > cfg.sightRange) return;
            // No shots through buildings, props, or steep intervening cover.
            int cover = (1 << SandboxLayers.World) | (1 << SandboxLayers.Prop);
            if (scene.Raycast(start, to / distance, distance, cover, QueryTriggerInteraction.Ignore)) return;
            // Reproducible distance-dependent hit probability without RNG allocations.
            int timeBucket = (int)(now * 10);
            uint hash = unchecked((uint)(b.actor.GetSiblingIndex() * 1103515245 + timeBucket * 12345));
            hash ^= hash >> 16;
            float chance = 0.38f * Mathf.Clamp01(1 - distance / (float)cfg.sightRange);
            if ((hash & 65535u) / 65536f < chance)
                session.ApplyBotDamage(cfg.shotDamage);
        }
    }
}

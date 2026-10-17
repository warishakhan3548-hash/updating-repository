using UnityEngine;
using UnityEngine.SceneManagement;

namespace Aaris.World
{
    // Offline practice NPC. Deliberately uses no NavMesh, networking, or per-bot dynamic solver.
    // Terrain and static obstacles are queried in the existing PhysicsScene at a distance-tiered rate.
    [DefaultExecutionOrder(-75)]
    [RequireComponent(typeof(Rigidbody))]
    public sealed class SandboxBot : MonoBehaviour
    {
        public SandboxSession session;
        public Damageable health;
        public int slot;
        public Vector3 start;
        public BotSpec tuning = new BotSpec();
        private Rigidbody body;
        private double lastThink, nextThink, nextAttack;

        private const int ObstacleMask = (1 << SandboxLayers.World) | (1 << SandboxLayers.Prop);

        private void Awake() { body = GetComponent<Rigidbody>(); }

        private void FixedUpdate()
        {
            if (session == null || session.pawn == null || health == null || health.Dead ||
                session.MatchFinished || !tuning.enabled) return;
            double now = Time.fixedTimeAsDouble;
            if (now < nextThink) return;
            Vector3 feet = body.position;
            Vector3 player = session.pawn.Body.position;
            Vector3 toPlayer = player - feet; toPlayer.y = 0;
            float distance = toPlayer.magnitude;
            double elapsed = lastThink == 0 ? 0.1 : System.Math.Min(0.6, now - lastThink);
            lastThink = now;
            nextThink = now + (distance < 115 ? 0.1 : 0.55);

            var physicsScene = gameObject.scene.GetPhysicsScene();
            bool noticed = distance <= tuning.detectionRange;
            bool visible = noticed && distance > 0.01f &&
                !physicsScene.Raycast(feet + Vector3.up * 1.45f,
                    (player + Vector3.up * 1.15f - (feet + Vector3.up * 1.45f)).normalized,
                    (player + Vector3.up * 1.15f - (feet + Vector3.up * 1.45f)).magnitude,
                    ObstacleMask, QueryTriggerInteraction.Ignore);

            if (visible && distance <= tuning.attackRange && now >= nextAttack)
            {
                nextAttack = now + tuning.attackInterval;
                // Simplified LOS-gated sandbox attack; weapon effects, accuracy, reload and
                // ballistic simulation remain an explicit future combat milestone.
                session.TakeBotDamage(tuning.attackDamage);
            }

            Vector3 goal;
            var zone = session.CurrentZone;
            if (session.settings.zone != null && session.settings.zone.enabled &&
                zone.Outside(feet.x, feet.z, 0.3))
            {
                health.Apply((float)(session.settings.zone.damagePerSecond * elapsed));
                if (health.Dead) return;
            }
            if (session.settings.zone != null && session.settings.zone.enabled &&
                zone.Outside(feet.x, feet.z, 1.0))
                goal = new Vector3((float)zone.x, feet.y, (float)zone.z);
            else if (visible) goal = player;
            else
            {
                float angle = (float)((slot * 2.3999632297 + System.Math.Floor(now / 23) * 0.7) % (2 * System.Math.PI));
                goal = feet + new Vector3(Mathf.Cos(angle), 0, Mathf.Sin(angle)) * 35;
            }

            Vector3 direction = goal - feet; direction.y = 0;
            if (direction.sqrMagnitude < 1) return;
            direction.Normalize();
            // Hold a short tactical distance rather than running through the player.
            if (visible && distance < 9) direction = Vector3.Cross(Vector3.up, direction) *
                (slot % 2 == 0 ? 1 : -1);
            float travel = (float)(tuning.moveSpeed * elapsed);
            Vector3 origin = feet + Vector3.up * 0.95f;
            if (physicsScene.SphereCast(origin, 0.3f, direction, out var obstacle,
                travel + 0.4f, ObstacleMask, QueryTriggerInteraction.Ignore))
            {
                Vector3 tangent = Vector3.Cross(Vector3.up, obstacle.normal);
                tangent.y = 0;
                if (tangent.sqrMagnitude < 0.001f) return;
                tangent.Normalize();
                if (Vector3.Dot(tangent, direction) < 0) tangent = -tangent;
                direction = tangent;
                if (physicsScene.SphereCast(origin, 0.3f, direction, out _,
                    travel + 0.35f, ObstacleMask, QueryTriggerInteraction.Ignore)) return;
            }
            Vector3 next = feet + direction * travel;
            // Explicit ground-following and step-height limit; never teleport to rooftops.
            if (!physicsScene.Raycast(new Vector3(next.x, feet.y + 8, next.z),
                Vector3.down, out var ground, 30, 1 << SandboxLayers.World,
                QueryTriggerInteraction.Ignore)) return;
            float rise = ground.point.y + 0.12f - feet.y;
            if (rise > 0.55f || rise < -1.4f || ground.normal.y < 0.87f) return;
            next.y = ground.point.y + 0.12f;
            body.MovePosition(next);
            body.MoveRotation(Quaternion.LookRotation(direction, Vector3.up));
        }

        public void ResetBot()
        {
            if (body == null) body = GetComponent<Rigidbody>();
            body.position = start;
            body.rotation = Quaternion.identity;
            health.ResetHealth();
            lastThink = nextThink = nextAttack = 0;
        }
    }
}

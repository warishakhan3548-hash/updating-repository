using UnityEngine;
using UnityEngine.SceneManagement;

namespace Aaris.World
{
    // Generated actors are kinematic CharacterControllers, not 100 rigidbodies.
    // Player hits still go through the existing HitRegion -> Damageable pipeline.
    public sealed class LocalBotAgent : MonoBehaviour
    {
        public Damageable damageable;
        public CharacterController mover;
        public Vector3 spawn;
        public Vector3 steering;
        public int index;
        public LocalBotDirector director;
        public double nextShot, nextFarMove;
        public bool credited;
        public bool Alive => damageable != null && !damageable.Dead;

        public void ResetAgent()
        {
            if (mover != null) mover.enabled = false;
            transform.position = spawn;
            damageable.ResetHealth();
            if (mover != null) mover.enabled = true;
            steering = Vector3.zero;
            nextShot = 1 + (index % 7) * 0.13;
            nextFarMove = 0;
            credited = false;
        }
    }

    [DefaultExecutionOrder(50)]
    public sealed class LocalBotDirector : MonoBehaviour
    {
        public SandboxSession session;
        public BotMatchSpec settings;
        public LocalBotAgent[] agents = System.Array.Empty<LocalBotAgent>();
        public int PlayerEliminations { get; private set; }
        public int Living { get; private set; }
        private int cursor;
        private bool started;
        private const int NavigationMask = (1 << SandboxLayers.World) | (1 << SandboxLayers.Prop);

        private void Start() { ResetMatch(); }

        public void ResetMatch()
        {
            cursor = 0;
            PlayerEliminations = 0;
            Living = agents == null ? 0 : agents.Length;
            if (agents != null) foreach (var bot in agents)
                if (bot != null) bot.ResetAgent();
            started = true;
        }

        public void CreditPlayerElimination(LocalBotAgent actor)
        {
            if (actor == null || actor.credited || !started || session == null ||
                session.Outcome != LocalMatchOutcome.Running) return;
            if (actor.Alive) return;
            actor.credited = true;
            PlayerEliminations++;
        }

        private void FixedUpdate()
        {
            if (!started || session == null || settings == null || !settings.enabled ||
                session.Outcome != LocalMatchOutcome.Running || session.pawn == null ||
                session.pawn.Body == null || agents == null || agents.Length == 0) return;
            double now = Time.fixedTimeAsDouble;
            float step = Time.fixedDeltaTime;
            Vector3 playerPosition = session.pawn.Body.position;
            var scene = gameObject.scene.GetPhysicsScene();
            int alive = 0;
            for (int i = 0; i < agents.Length; i++)
            {
                var bot = agents[i];
                if (bot == null || !bot.Alive) continue;
                if (session.settings.zone != null && session.settings.zone.enabled &&
                    session.CurrentZone.Outside(bot.transform.position.x, bot.transform.position.z, 0.35))
                    bot.damageable.Apply((float)(session.settings.zone.damagePerSecond * step));
                if (!bot.Alive) continue;
                alive++;
                float distanceSq = (bot.transform.position - playerPosition).sqrMagnitude;
                // Distant actors move at 5Hz; close combat stays at native fixedHz.
                // This reduces CharacterController collision work with 100 actors.
                bool near = distanceSq <= 125f * 125f;
                if (near || now >= bot.nextFarMove)
                {
                    float delta = near ? step : 0.2f;
                    bot.nextFarMove = now + 0.2;
                    if (bot.steering.sqrMagnitude > 0.001f)
                    {
                        Vector3 velocity = bot.steering * (float)settings.speed * delta;
                        bot.mover.Move(velocity + Vector3.down * (6f * delta));
                        bot.transform.rotation = Quaternion.LookRotation(bot.steering, Vector3.up);
                    }
                    else bot.mover.Move(Vector3.down * (6f * delta));
                }
            }
            Living = alive;
            if (Living == 0) { session.EndMatch(true); return; }
            // Round-robin, strict CPU budget. Near and far agents are treated fairly;
            // no per-actor Update or 100 independent timers/raycast loops.
            int decisions = Mathf.Min(settings.decisionsPerStep, agents.Length);
            for (int n = 0; n < decisions; n++)
            {
                int i = cursor;
                cursor = (cursor + 1) % agents.Length;
                var bot = agents[i];
                if (bot == null || !bot.Alive) continue;
                Think(bot, i, playerPosition, now, scene);
            }
        }

        private void Think(LocalBotAgent bot, int index, Vector3 player, double now, PhysicsScene scene)
        {
            Vector3 position = bot.transform.position;
            Vector3 toPlayer = player - position; toPlayer.y = 0;
            float playerDistance = toPlayer.magnitude;
            var ring = session.CurrentZone;
            Vector3 desired;
            if (session.settings.zone != null && session.settings.zone.enabled &&
                ring.ExcessDistance(position.x, position.z, 1) > 0)
                desired = new Vector3((float)ring.x - position.x, 0, (float)ring.z - position.z);
            else if (playerDistance < settings.detectionRange && playerDistance > 6)
                desired = toPlayer;
            else if (playerDistance <= 6)
                desired = new Vector3(-toPlayer.z, 0, toPlayer.x);
            else
            {
                // Wander toward a seeded orbit near the moving zone, not aimlessly
                // into the map edge. A fixed angle gives stable per-actor behaviour.
                float angle = (index * 2.399963f + (float)now * 0.04f);
                float orbit = session.settings.zone != null && session.settings.zone.enabled
                    ? Mathf.Min((float)ring.radius * 0.45f, 90) : 80;
                desired = new Vector3((float)ring.x + Mathf.Cos(angle) * orbit - position.x,
                                      0, (float)ring.z + Mathf.Sin(angle) * orbit - position.z);
            }
            bot.steering = desired.sqrMagnitude > 0.01f ? desired.normalized : Vector3.zero;
            // Obstacle-aware local avoidance; not falsely described as NavMesh pathfinding.
            if (bot.steering != Vector3.zero &&
                scene.CapsuleCast(position + Vector3.up * 0.42f,
                                  position + Vector3.up * 1.48f,
                                  0.28f, bot.steering, out _, 2.6f, NavigationMask,
                                  QueryTriggerInteraction.Ignore))
            {
                float sign = (index & 1) == 0 ? 1 : -1;
                bot.steering = new Vector3(bot.steering.z * sign, 0, -bot.steering.x * sign);
            }

            if (playerDistance > settings.attackRange || playerDistance < 0.1f) return;
            Vector3 eye = position + Vector3.up * 1.38f;
            Vector3 target = player + Vector3.up * 1.12f;
            Vector3 ray = target - eye;
            bool visible = !scene.Raycast(eye, ray.normalized, ray.magnitude,
                                         NavigationMask, QueryTriggerInteraction.Ignore);
            if (LocalMatchRules.CanFire(playerDistance, settings.attackRange, visible,
                                        now, bot.nextShot))
            {
                // Initial stagger prevents a synchronized first-frame 50-bot volley.
                bot.nextShot = now + settings.secondsPerShot;
                session.DamagePlayer(settings.damage);
            }
        }
    }
}

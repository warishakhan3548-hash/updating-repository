using UnityEngine;
using UnityEngine.SceneManagement;

namespace Aaris.World
{
    public sealed class SandboxSession : MonoBehaviour
    {
        public SandboxSpec settings = new SandboxSpec();
        // Compiled read-only snapshot for tactical presentation; JSON remains the authoring source.
        public WorldSpec world;
        public PhysicsPawn pawn;
        public PhysicsWeapon weapon;
        public SandboxInput input;
        public ThirdPersonRig cameraRig;
        public Damageable[] targets = System.Array.Empty<Damageable>();
        public Rigidbody[] props = System.Array.Empty<Rigidbody>();
        public LocalLootPickup[] loot = System.Array.Empty<LocalLootPickup>();
        public LocalBotDirector botDirector;
        public LocalMatchOutcome Outcome { get; private set; } = LocalMatchOutcome.Running;
        public Vector3 playerStart;
        public Vector3[] propStarts;
        public Quaternion[] propRotations;
        public Vector2 worldMin, worldMax;
        public LineRenderer zoneLine;
        public double PlayerHealth { get; private set; } = 100;
        public BattleZoneSnapshot CurrentZone { get; private set; }
        private double zoneClock, nextZoneVisualUpdate, lootClock;
        private const int ZoneSegments = 96;
        private static SandboxSession owner;
        private float oldStep, oldMaxTime;
        private Vector3 oldGravity;
        private SimulationMode oldMode;
        private bool oldSync, oldReuse, oldMouseSimulation;
        private readonly bool[,] oldCollisions = new bool[4, 4];
        private bool ownsGlobals;

        private void OnEnable()
        {
            if (owner != null && owner != this) { Debug.LogError("Only one sandbox session can own global physics settings."); enabled = false; return; }
            owner = this; ownsGlobals = true;
            PlayerHealth = 100; Outcome = LocalMatchOutcome.Running;
            zoneClock = 0; nextZoneVisualUpdate = 0; lootClock = 0;
            if (settings.zone != null && settings.zone.enabled) CurrentZone = BattleZoneTimeline.At(settings.zone, 0);
            oldGravity = Physics.gravity; oldStep = Time.fixedDeltaTime; oldMaxTime = Time.maximumDeltaTime;
            oldMode = Physics.simulationMode; oldSync = Physics.autoSyncTransforms; oldReuse = Physics.reuseCollisionCallbacks;
            oldMouseSimulation = Input.simulateMouseWithTouches; Input.simulateMouseWithTouches = false;
            Physics.gravity = Vector3.down * (float)settings.gravity;
            Time.fixedDeltaTime = 1f / settings.fixedHz; Time.maximumDeltaTime = Time.fixedDeltaTime * settings.maxCatchUpSteps;
            Physics.simulationMode = SimulationMode.FixedUpdate; Physics.autoSyncTransforms = false; Physics.reuseCollisionCallbacks = true;
            for (int a = 0; a < 4; a++) for (int b = a; b < 4; b++)
            {
                oldCollisions[a, b] = Physics.GetIgnoreLayerCollision(8 + a, 8 + b);
                Physics.IgnoreLayerCollision(8 + a, 8 + b, false);
            }
        }
        private void Update()
        {
            if (pawn == null) return;
            Vector3 p = pawn.Body.position;
            if (InvalidPosition(p)) ResetSandbox();
            bool corrected = false;
            for (int i = 0; i < props.Length; i++) if (InvalidPosition(props[i].position)) { ResetProp(i); corrected = true; }
            if (corrected) Physics.SyncTransforms();
        }
        private void FixedUpdate()
        {
            if (pawn == null || Outcome != LocalMatchOutcome.Running) return;
            CollectNearbyLoot();
            if (settings.zone == null || !settings.zone.enabled) return;
            zoneClock += Time.fixedDeltaTime;
            CurrentZone = BattleZoneTimeline.At(settings.zone, zoneClock);
            Vector3 feet = pawn.Body.position;
            if (CurrentZone.Outside(feet.x, feet.z, settings.movement.radius))
            {
                PlayerHealth = System.Math.Max(0, PlayerHealth - settings.zone.damagePerSecond * Time.fixedDeltaTime);
                if (PlayerHealth <= 0)
                {
                    if (botDirector != null && settings.bots != null && settings.bots.enabled) EndMatch(false);
                    else ResetSandbox(); // Preserve original local-practice behaviour.
                }
            }
        }
        // One bounded scan every 0.2s. World-only line of sight prevents items
        // behind solid buildings from being collected through walls.
        private void CollectNearbyLoot()
        {
            if (loot == null || loot.Length == 0 || settings.loot == null || !settings.loot.enabled ||
                weapon == null || weapon.State == null) return;
            lootClock += Time.fixedDeltaTime;
            if (lootClock < 0.2) return;
            lootClock = 0;
            Vector3 feet = pawn.Body.position;
            Vector3 eye = feet + Vector3.up * 1.1f;
            double radius = settings.loot.pickupRadius;
            var physicsScene = gameObject.scene.GetPhysicsScene();
            foreach (var item in loot)
            {
                if (item == null || !item.gameObject.activeSelf) continue;
                Vector3 diff = item.transform.position - feet;
                if (diff.x * diff.x + diff.z * diff.z > radius * radius || Mathf.Abs(diff.y) > 2f) continue;
                if (item.kind == LootKind.Medical && PlayerHealth >= 100) continue;
                if (item.kind == LootKind.Ammunition && weapon.State.Reserve >= 1000) continue;
                Vector3 toward = (item.transform.position + Vector3.up * 0.55f) - eye;
                if (toward.sqrMagnitude > 0.0001f &&
                    physicsScene.Raycast(eye, toward.normalized, toward.magnitude,
                        1 << SandboxLayers.World, QueryTriggerInteraction.Ignore)) continue;
                if (item.kind == LootKind.Medical) PlayerHealth = System.Math.Min(100, PlayerHealth + item.amount);
                else if (!weapon.State.TryAddReserve(item.amount)) continue;
                item.gameObject.SetActive(false);
            }
        }
        private void LateUpdate()
        {
            if (zoneLine == null || settings.zone == null || !settings.zone.enabled || pawn == null) return;
            if (Time.timeAsDouble < nextZoneVisualUpdate) return;
            nextZoneVisualUpdate = Time.timeAsDouble + 0.5;
            var scene = gameObject.scene.GetPhysicsScene();
            var ring = CurrentZone;
            if (ring.radius <= 0) ring = BattleZoneTimeline.At(settings.zone, zoneClock);
            for (int i = 0; i < ZoneSegments; i++)
            {
                float a = i * (2f * Mathf.PI / ZoneSegments);
                float x = (float)(ring.x + ring.radius * System.Math.Cos(a));
                float z = (float)(ring.z + ring.radius * System.Math.Sin(a));
                float y = 2f;
                if (scene.Raycast(new Vector3(x, 1000f, z), Vector3.down, out RaycastHit ground,
                    2000f, 1 << SandboxLayers.World, QueryTriggerInteraction.Ignore))
                    y = ground.point.y + 1.5f;
                zoneLine.SetPosition(i, new Vector3(x, y, z));
            }
        }
        private bool InvalidPosition(Vector3 p) => !WorldValidator.Finite(p.x) || !WorldValidator.Finite(p.y) || !WorldValidator.Finite(p.z) || p.y < -50 || p.x < worldMin.x - 10 || p.z < worldMin.y - 10 || p.x > worldMax.x + 10 || p.z > worldMax.y + 10;
        private void ResetProp(int i) { props[i].position = propStarts[i]; props[i].rotation = propRotations[i]; props[i].linearVelocity = props[i].angularVelocity = Vector3.zero; props[i].WakeUp(); }
        public void DamagePlayer(double amount)
        {
            if (Outcome != LocalMatchOutcome.Running || !WorldValidator.Finite(amount) || amount <= 0) return;
            PlayerHealth = System.Math.Max(0, PlayerHealth - amount);
            if (PlayerHealth <= 0)
            {
                if (botDirector != null && settings.bots != null && settings.bots.enabled) EndMatch(false);
                else ResetSandbox();
            }
        }
        public void EndMatch(bool winner)
        {
            if (Outcome != LocalMatchOutcome.Running) return;
            Outcome = winner ? LocalMatchOutcome.Won : LocalMatchOutcome.Lost;
            if (pawn != null) pawn.enabled = false;
            if (weapon != null) weapon.enabled = false;
            if (input != null) input.Clear();
        }
        public void ResetSandbox()
        {
            if (pawn == null) return;
            pawn.Teleport(playerStart); input.Clear(); weapon.ResetWeapon(); cameraRig.ResetView();
            PlayerHealth = 100; Outcome = LocalMatchOutcome.Running;
            pawn.enabled = true; weapon.enabled = true;
            zoneClock = 0; nextZoneVisualUpdate = 0;
            if (settings.zone != null && settings.zone.enabled) CurrentZone = BattleZoneTimeline.At(settings.zone, 0);
            foreach (var target in targets) target.ResetHealth();
            if (botDirector != null) botDirector.ResetMatch();
            foreach (var item in loot) if (item != null) item.gameObject.SetActive(true);
            for (int i = 0; i < props.Length; i++) ResetProp(i);
            Physics.SyncTransforms(); // Explicit reset only; ordinary movement stays in the solver.
        }
        private void OnDisable() { ReleaseGlobals(); }
        private void OnDestroy() { ReleaseGlobals(); }
        private void ReleaseGlobals()
        {
            if (!ownsGlobals) return;
            Physics.gravity = oldGravity; Time.fixedDeltaTime = oldStep; Time.maximumDeltaTime = oldMaxTime;
            Physics.simulationMode = oldMode; Physics.autoSyncTransforms = oldSync; Physics.reuseCollisionCallbacks = oldReuse;
            Input.simulateMouseWithTouches = oldMouseSimulation;
            for (int a = 0; a < 4; a++) for (int b = a; b < 4; b++) Physics.IgnoreLayerCollision(8 + a, 8 + b, oldCollisions[a, b]);
            if (owner == this) owner = null;
            ownsGlobals = false;
        }
    }
}

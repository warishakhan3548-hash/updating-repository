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
        public Vector3 playerStart;
        public Vector3[] propStarts;
        public Quaternion[] propRotations;
        public Vector2 worldMin, worldMax;
        public LineRenderer zoneLine;
        // Authored once by the editor from the validated world source; no dynamic collider bodies.
        public LootSpawn[] lootSpawns = System.Array.Empty<LootSpawn>();
        public Transform[] lootVisuals = System.Array.Empty<Transform>();
        public int PickupsCollected { get; private set; }
        public double PlayerHealth { get; private set; } = 100;
        public BattleZoneSnapshot CurrentZone { get; private set; }
        private double zoneClock, nextZoneVisualUpdate;
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
            PlayerHealth = 100; PickupsCollected = 0; zoneClock = 0; nextZoneVisualUpdate = 0;
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
            if (pawn == null) return;
            Vector3 feet = pawn.Body.position;
            if (settings.zone != null && settings.zone.enabled)
            {
                zoneClock += Time.fixedDeltaTime;
                CurrentZone = BattleZoneTimeline.At(settings.zone, zoneClock);
                if (CurrentZone.Outside(feet.x, feet.z, settings.movement.radius))
                {
                    PlayerHealth = System.Math.Max(0, PlayerHealth - settings.zone.damagePerSecond * Time.fixedDeltaTime);
                    if (PlayerHealth <= 0) { ResetSandbox(); return; } // Local practice restart.
                }
            }
            // Pure radius check followed by a physical world line of sight. No wall-through pickups.
            if (weapon == null || lootSpawns == null || lootVisuals == null) return;
            Vector3 chest = feet + Vector3.up * 1f;
            var scene = gameObject.scene.GetPhysicsScene();
            int count = System.Math.Min(lootSpawns.Length, lootVisuals.Length);
            for (int i = 0; i < count; i++)
            {
                Transform visual = lootVisuals[i];
                if (visual == null || !visual.gameObject.activeSelf) continue;
                Vector3 ray = visual.position - chest;
                float distance = ray.magnitude;
                if (distance > 1.8f || distance <= 0.0001f) continue;
                if (scene.Raycast(chest, ray / distance, out _, distance, 1 << SandboxLayers.World, QueryTriggerInteraction.Ignore))
                    continue;
                bool used;
                if (lootSpawns[i].kind == LootKind.Medkit)
                {
                    used = PlayerHealth < 100;
                    if (used) PlayerHealth = System.Math.Min(100, PlayerHealth + lootSpawns[i].amount);
                }
                else used = weapon.State != null && weapon.State.GrantReserve(lootSpawns[i].amount) > 0;
                if (!used) continue;
                visual.gameObject.SetActive(false);
                PickupsCollected++;
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
        public void ResetSandbox()
        {
            if (pawn == null) return;
            pawn.Teleport(playerStart); input.Clear(); weapon.ResetWeapon(); cameraRig.ResetView();
            PlayerHealth = 100; PickupsCollected = 0; zoneClock = 0; nextZoneVisualUpdate = 0;
            if (settings.zone != null && settings.zone.enabled) CurrentZone = BattleZoneTimeline.At(settings.zone, 0);
            foreach (var target in targets) target.ResetHealth();
            foreach (var loot in lootVisuals) if (loot != null) loot.gameObject.SetActive(true);
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

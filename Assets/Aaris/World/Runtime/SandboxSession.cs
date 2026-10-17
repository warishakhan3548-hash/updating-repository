using UnityEngine;

namespace Aaris.World
{
    public sealed class SandboxSession : MonoBehaviour
    {
        public SandboxSpec settings = new SandboxSpec();
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
        private bool InvalidPosition(Vector3 p) => !WorldValidator.Finite(p.x) || !WorldValidator.Finite(p.y) || !WorldValidator.Finite(p.z) || p.y < -50 || p.x < worldMin.x - 10 || p.z < worldMin.y - 10 || p.x > worldMax.x + 10 || p.z > worldMax.y + 10;
        private void ResetProp(int i) { props[i].position = propStarts[i]; props[i].rotation = propRotations[i]; props[i].linearVelocity = props[i].angularVelocity = Vector3.zero; props[i].WakeUp(); }
        public void ResetSandbox()
        {
            if (pawn == null) return;
            pawn.Teleport(playerStart); input.Clear(); weapon.ResetWeapon(); cameraRig.ResetView();
            foreach (var target in targets) target.ResetHealth();
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

using System;
using UnityEngine;
using UnityEngine.SceneManagement;

namespace Aaris.World
{
    [RequireComponent(typeof(Rigidbody), typeof(CapsuleCollider))]
    [DisallowMultipleComponent]
    [DefaultExecutionOrder(-100)]
    public sealed class PhysicsPawn : MonoBehaviour
    {
        public MovementSpec settings = new MovementSpec();
        public SandboxInput input;
        public ThirdPersonRig cameraRig;
        public Transform visual;
        private Rigidbody body;
        private JumpGate jump;
        private double ignoreGroundUntil;
        public bool Grounded { get; private set; }
        public Vector3 GroundNormal { get; private set; } = Vector3.up;
        public Rigidbody Body => body;

        private void Awake() { Configure(); }
        public void Configure()
        {
            body = GetComponent<Rigidbody>();
            body.mass = (float)settings.mass; body.useGravity = true; body.isKinematic = false;
            body.linearDamping = 0; body.angularDamping = 0.05f;
            body.constraints = RigidbodyConstraints.FreezeRotation;
            body.interpolation = RigidbodyInterpolation.Interpolate;
            body.collisionDetectionMode = CollisionDetectionMode.ContinuousDynamic;
            body.solverIterations = 8; body.solverVelocityIterations = 2;
            body.maxDepenetrationVelocity = 4; body.maxLinearVelocity = 60;
            var capsule = GetComponent<CapsuleCollider>();
            capsule.radius = (float)settings.radius; capsule.height = (float)settings.height;
            capsule.center = Vector3.up * (float)(settings.height * 0.5); capsule.direction = 1;
            jump = new JumpGate(settings.coyoteTime, settings.jumpBuffer);
        }

        private void FixedUpdate()
        {
            if (input == null || cameraRig == null) return;
            Step(input.Move, cameraRig.Yaw, input.Sprint && !input.Aim, input.ConsumeJump(), Time.fixedDeltaTime, Time.fixedTimeAsDouble);
            if (visual != null) visual.localRotation = Quaternion.Euler(0, cameraRig.Yaw, 0);
        }

        // Shared entry point for the local input harness and isolated native-physics tests.
        // Only forces affect ordinary movement; there is no per-frame Transform teleport.
        public void Step(Vector2 move, float yaw, bool sprint, bool requestJump, float dt, double now)
        {
            if (body == null) Configure();
            if (dt <= 0 || dt > 1f / 20 || !WorldValidator.Finite(move.x) || !WorldValidator.Finite(move.y) || !WorldValidator.Finite(yaw) || !WorldValidator.Finite(dt) || !WorldValidator.Finite(now)) throw new ArgumentException("Finite fixed-step pawn input required.");
            var scene = gameObject.scene.GetPhysicsScene();
            float radius = (float)settings.radius;
            Vector3 origin = body.position + Vector3.up * (radius + 0.08f);
            bool support = scene.SphereCast(origin, radius * 0.9f, Vector3.down, out var hit, 0.08f + radius * 0.1f + 0.09f, SandboxLayers.SolidMask, QueryTriggerInteraction.Ignore);
            GroundNormal = support ? hit.normal : Vector3.up;
            Vector3 supportVelocity = support && hit.rigidbody != null ? hit.rigidbody.GetPointVelocity(hit.point) : Vector3.zero;
            Grounded = support && now >= ignoreGroundUntil && hit.normal.y >= Mathf.Cos((float)settings.maxSlope * Mathf.Deg2Rad) && Vector3.Dot(body.linearVelocity - supportVelocity, hit.normal) < 2;
            if (!Grounded) supportVelocity = Vector3.zero;
            move = Vector2.ClampMagnitude(move, 1);
            Vector3 wish = Quaternion.Euler(0, yaw, 0) * new Vector3(move.x, 0, move.y);
            float speed = (float)(sprint ? settings.sprintSpeed : settings.walkSpeed);
            Vector3 normal = Grounded ? GroundNormal : Vector3.up;
            Vector3 target = Vector3.ProjectOnPlane(wish, normal).normalized * (speed * move.magnitude);
            if (!Grounded && support && hit.normal.y > 0.01f && hit.normal.y < Mathf.Cos((float)settings.maxSlope * Mathf.Deg2Rad))
            {
                Vector3 downhill = Vector3.ProjectOnPlane(hit.normal, Vector3.up).normalized;
                float uphill = Vector3.Dot(target, downhill); if (uphill < 0) target -= downhill * uphill;
            }
            Vector3 current = Vector3.ProjectOnPlane(body.linearVelocity - supportVelocity, normal);
            float acceleration = (float)(Grounded ? settings.groundAcceleration : settings.airAcceleration);
            body.AddForce(Vector3.ClampMagnitude(target - current, acceleration * dt), ForceMode.VelocityChange);
            if (requestJump) jump.Request(now);
            if (jump.Tick(now, Grounded))
            {
                float jumpSpeed = Mathf.Sqrt(2 * Mathf.Abs(Physics.gravity.y) * (float)settings.jumpHeight);
                body.AddForce(Vector3.up * Mathf.Max(0, jumpSpeed + Mathf.Max(0, supportVelocity.y) - body.linearVelocity.y), ForceMode.VelocityChange);
                Grounded = false; ignoreGroundUntil = now + 0.14;
            }
            else if (Grounded)
            {
                // Cancel tangential gravity while supported, preserving normal collision pressure.
                body.AddForce(-Vector3.ProjectOnPlane(Physics.gravity, GroundNormal), ForceMode.Acceleration);
            }
        }

        public void Teleport(Vector3 feet)
        {
            if (body == null) Configure();
            body.position = feet; body.linearVelocity = body.angularVelocity = Vector3.zero;
            jump.Reset(); Grounded = false; ignoreGroundUntil = 0;
        }
    }
}

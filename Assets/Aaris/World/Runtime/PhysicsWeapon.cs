using UnityEngine;
using UnityEngine.SceneManagement;

namespace Aaris.World
{
    public struct ShotTrace
    {
        public bool hit, blockedAtOrigin;
        public RaycastHit contact;
        public Vector3 end;
    }

    [DefaultExecutionOrder(-50)]
    public sealed class PhysicsWeapon : MonoBehaviour
    {
        public WeaponSpec settings = new WeaponSpec();
        public SandboxInput input;
        public ThirdPersonRig cameraRig;
        public Transform muzzle;
        public float barrelHeight = 1.35f;
        public LineRenderer tracer;
        private readonly Collider[] originOverlap = new Collider[1];
        private WeaponState state;
        private Rigidbody ownerBody;
        private double tracerUntil, hitUntil;
        public WeaponState State => state;
        public bool LastHit { get; private set; }
        public bool LastHeadshot { get; private set; }
        public bool BarrelBlocked { get; private set; }
        public bool HitMarker => LastHit && Time.timeAsDouble < hitUntil;
        public void ResetWeapon() { state = new WeaponState(settings); LastHit = LastHeadshot = BarrelBlocked = false; if (tracer != null) tracer.enabled = false; }
        private void Awake() { ownerBody = GetComponent<Rigidbody>(); ResetWeapon(); }
        private void FixedUpdate()
        {
            if (input == null || cameraRig == null || muzzle == null) return;
            if (state == null) ResetWeapon();
            double now = Time.fixedTimeAsDouble;
            if (!state.Tick(now, input.Fire, input.ConsumeReload())) return;
            Vector3 feet = ownerBody != null ? ownerBody.position : transform.position;
            // Physics uses the current body pose, not the renderer's interpolated position.
            Vector3 barrelPoint = feet + (muzzle.position - transform.position);
            Vector3 chest = feet + Vector3.up * barrelHeight;
            var view = cameraRig.View;
            var result = Trace(gameObject.scene.GetPhysicsScene(), view.transform.position, view.transform.forward, chest, barrelPoint, (float)settings.range, originOverlap);
            LastHit = LastHeadshot = false; BarrelBlocked = result.blockedAtOrigin;
            if (result.hit)
            {
                var region = result.contact.collider.GetComponent<HitRegion>();
                if (region != null && region.receiver != null)
                {
                    LastHeadshot = region.head;
                    LastHit = region.receiver.Apply((float)(settings.damage * (region.head ? settings.headMultiplier : 1)));
                }
                var body = result.contact.rigidbody;
                if (body != null && !body.isKinematic)
                {
                    Vector3 direction = result.contact.point - barrelPoint;
                    if (direction.sqrMagnitude > 0.0001f) body.AddForceAtPosition(direction.normalized * (float)settings.impactImpulse, result.contact.point, ForceMode.Impulse);
                }
            }
            if (tracer != null)
            {
                tracer.SetPosition(0, barrelPoint); tracer.SetPosition(1, result.end);
                tracer.enabled = !result.blockedAtOrigin; tracerUntil = now + 0.045;
                tracer.startColor = tracer.endColor = LastHit ? Color.red : new Color(1, 0.85f, 0.4f);
            }
            if (LastHit) hitUntil = now + 0.18;
            cameraRig.Recoil(input.Aim ? 0.6f : 1.1f);
        }
        private void Update() { if (tracer != null && Time.timeAsDouble > tracerUntil) tracer.enabled = false; }

        public static ShotTrace Trace(PhysicsScene scene, Vector3 eye, Vector3 aim, Vector3 chest, Vector3 muzzle, float range, Collider[] scratch)
        {
            // A chest inside solid geometry is a blocked shot, never a ray starting inside a wall.
            if (scene.OverlapSphere(chest, 0.04f, scratch, SandboxLayers.SolidMask, QueryTriggerInteraction.Ignore) > 0)
                return new ShotTrace { blockedAtOrigin = true, end = chest };
            Vector3 aimPoint = eye + aim.normalized * range;
            if (scene.Raycast(eye, aim.normalized, out var cameraHit, range, SandboxLayers.SolidMask, QueryTriggerInteraction.Ignore)) aimPoint = cameraHit.point;
            Vector3 barrel = muzzle - chest;
            if (barrel.sqrMagnitude > 0.0001f && scene.Raycast(chest, barrel.normalized, out var obstruction, barrel.magnitude, SandboxLayers.SolidMask, QueryTriggerInteraction.Ignore))
                return new ShotTrace { hit = true, contact = obstruction, end = obstruction.point };
            Vector3 direction = aimPoint - muzzle;
            float distance = Mathf.Min(range, direction.magnitude);
            if (distance > 0.0001f && scene.Raycast(muzzle, direction.normalized, out var hit, distance + 0.002f, SandboxLayers.SolidMask, QueryTriggerInteraction.Ignore))
                return new ShotTrace { hit = true, contact = hit, end = hit.point };
            return new ShotTrace { end = muzzle + direction.normalized * distance };
        }
    }
}

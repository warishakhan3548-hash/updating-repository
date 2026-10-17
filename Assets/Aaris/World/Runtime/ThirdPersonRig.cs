using UnityEngine;
using UnityEngine.SceneManagement;

namespace Aaris.World
{
    [RequireComponent(typeof(Camera))]
    public sealed class ThirdPersonRig : MonoBehaviour
    {
        public Transform target;
        public SandboxInput input;
        public float initialYaw;
        public float pivotHeight = 1.5f;
        private float yaw, pitch = 12, recoil, distance = 3.7f;
        private Camera view;
        private Renderer[] playerRenderers;
        public float Yaw => yaw;
        public Camera View => view != null ? view : GetComponent<Camera>();
        public void Recoil(float degrees) { recoil = Mathf.Min(8, recoil + degrees); }
        public void ResetView() { yaw = initialYaw; pitch = 12; recoil = 0; distance = 3.7f; }
        private void Awake()
        {
            view = GetComponent<Camera>(); ResetView();
            if (target != null && target.TryGetComponent<PhysicsPawn>(out var pawn) && pawn.visual != null) playerRenderers = pawn.visual.GetComponentsInChildren<Renderer>();
        }
        private void OnDisable() { if (playerRenderers != null) foreach (var renderer in playerRenderers) renderer.forceRenderingOff = false; }
        private void LateUpdate()
        {
            if (target == null || input == null) return;
            yaw = Mathf.Repeat(yaw + input.Look.x * 165, 360); pitch = Mathf.Clamp(pitch - input.Look.y * 165, -35, 65);
            recoil = Mathf.MoveTowards(recoil, 0, Time.deltaTime * 7);
            Quaternion rotation = Quaternion.Euler(pitch - recoil, yaw, 0);
            Vector3 pivot = target.position + Vector3.up * pivotHeight;
            Vector3 offset = rotation * new Vector3(0.6f, 0, -3.7f);
            float desired = offset.magnitude;
            var scene = gameObject.scene.GetPhysicsScene();
            if (scene.SphereCast(pivot, 0.18f, offset.normalized, out var hit, desired, SandboxLayers.SolidMask, QueryTriggerInteraction.Ignore)) desired = Mathf.Max(0.05f, hit.distance - 0.04f);
            // Retract immediately at an obstruction; only the safe recovery is smoothed.
            distance = desired < distance ? desired : Mathf.MoveTowards(distance, desired, Time.deltaTime * 5);
            if (playerRenderers != null) foreach (var renderer in playerRenderers) renderer.forceRenderingOff = distance < 0.65f;
            transform.SetPositionAndRotation(pivot + offset.normalized * distance, rotation);
            view.fieldOfView = Mathf.MoveTowards(view.fieldOfView, input.Aim ? 48 : 65, Time.deltaTime * 90);
        }
    }
}

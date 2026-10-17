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
        private PhysicsPawn pawn;
        private readonly Collider[] overlap = new Collider[8];
        public bool ClearView { get; private set; }
        public float Yaw => yaw;
        public Camera View => view != null ? view : GetComponent<Camera>();
        public void Recoil(float degrees) { recoil = Mathf.Min(8, recoil + degrees); }
        public void ResetView() { yaw = initialYaw; pitch = 12; recoil = 0; distance = 3.7f; ClearView = false; }
        private void Awake()
        {
            view = GetComponent<Camera>(); ResetView();
            if (target != null && target.TryGetComponent(out pawn) && pawn.visual != null) playerRenderers = pawn.visual.GetComponentsInChildren<Renderer>();
        }
        private void OnDisable() { if (playerRenderers != null) foreach (var renderer in playerRenderers) renderer.forceRenderingOff = false; if (view != null) view.enabled = true; }
        private void LateUpdate()
        {
            if (target == null || input == null) return;
            // Generated scenes assign target after AddComponent/Awake; resolve on first use.
            if (pawn == null && target.TryGetComponent(out pawn) && pawn.visual != null)
                playerRenderers = pawn.visual.GetComponentsInChildren<Renderer>();
            yaw = Mathf.Repeat(yaw + input.Look.x * 165, 360); pitch = Mathf.Clamp(pitch - input.Look.y * 165, -35, 65);
            recoil = Mathf.MoveTowards(recoil, 0, Time.deltaTime * 7);
            Quaternion rotation = Quaternion.Euler(pitch - recoil, yaw, 0);
            float activePivot = pawn != null && pawn.Crouched ? (float)pawn.settings.crouchHeight * 0.82f : pivotHeight;
            Vector3 pivot = target.position + Vector3.up * activePivot;
            Vector3 offset = rotation * new Vector3(0.6f, 0, -3.7f);
            var scene = gameObject.scene.GetPhysicsScene();
            ClearView = CameraCollision.TryLimit(scene, pivot, offset, overlap, out float desired);
            if (!ClearView && pawn != null && pawn.Body != null)
            {
                pivot = pawn.Body.position + Vector3.up * activePivot;
                ClearView = CameraCollision.TryLimit(scene, pivot, offset, overlap, out desired);
                if (!ClearView)
                {
                    pivot = pawn.Body.position + Vector3.up * (float)(pawn.settings.height * 0.5);
                    ClearView = CameraCollision.TryLimit(scene, pivot, offset, overlap, out desired);
                }
            }
            view.enabled = ClearView;
            if (!ClearView) return; // Invalid embedded pawn state: no wall view or shooting from a stale camera pose.
            // Retract immediately at an obstruction; only the safe recovery is smoothed.
            distance = desired < distance ? desired : Mathf.MoveTowards(distance, desired, Time.deltaTime * 5);
            if (playerRenderers != null) foreach (var renderer in playerRenderers) renderer.forceRenderingOff = distance < 0.65f;
            transform.SetPositionAndRotation(pivot + offset.normalized * distance, rotation);
            view.fieldOfView = Mathf.MoveTowards(view.fieldOfView, input.Aim ? 48 : 65, Time.deltaTime * 90);
        }
    }
}

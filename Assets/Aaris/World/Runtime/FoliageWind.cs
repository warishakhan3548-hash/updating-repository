using System;
using UnityEngine;

namespace Aaris.World
{
    // One lightweight behaviour per authored tree, NOT one per leaf.
    // Canopy-only pivots share the original static meshes/materials; trunks stay collidable.
    [DisallowMultipleComponent]
    public sealed class FoliageWind : MonoBehaviour
    {
        public Transform[] canopyPivots = Array.Empty<Transform>();
        public float frequencyHz = 0.18f;
        public float maximumDegrees = 2.4f;
        public float activeDistance = 260f;

        private Quaternion[] neutralRotations;
        private Camera viewCamera;
        private int nextCameraRefresh;
        private bool isNeutral = true;

        private void Awake()
        {
            neutralRotations = new Quaternion[canopyPivots.Length];
            for (int i = 0; i < canopyPivots.Length; i++)
                neutralRotations[i] = canopyPivots[i] != null ? canopyPivots[i].localRotation : Quaternion.identity;
        }

        private void LateUpdate()
        {
            if (neutralRotations == null || canopyPivots.Length == 0 || maximumDegrees <= 0) return;

            // Cache camera lookup. An absent camera falls back to active animation instead
            // of accidentally freezing foliage in the editor's generated review scene.
            if (viewCamera == null || Time.frameCount >= nextCameraRefresh)
            {
                viewCamera = Camera.main;
                nextCameraRefresh = Time.frameCount + 90;
            }

            if (viewCamera != null && (viewCamera.transform.position - transform.position).sqrMagnitude >
                activeDistance * activeDistance)
            {
                RestoreNeutral();
                return;
            }

            Vector3 position = transform.position;
            FoliageTilt tilt = FoliageWindMath.Sample(Time.timeAsDouble, position.x, position.z,
                frequencyHz, maximumDegrees);
            Quaternion offset = Quaternion.Euler((float)tilt.pitchDegrees, 0, (float)tilt.rollDegrees);
            for (int i = 0; i < canopyPivots.Length; i++)
                if (canopyPivots[i] != null)
                    canopyPivots[i].localRotation = neutralRotations[i] * offset;
            isNeutral = false;
        }

        private void OnDisable() { RestoreNeutral(); }

        private void RestoreNeutral()
        {
            if (isNeutral || neutralRotations == null) return;
            for (int i = 0; i < canopyPivots.Length; i++)
                if (canopyPivots[i] != null)
                    canopyPivots[i].localRotation = neutralRotations[i];
            isNeutral = true;
        }
    }
}

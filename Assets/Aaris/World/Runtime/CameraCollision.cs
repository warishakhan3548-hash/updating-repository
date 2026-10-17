using UnityEngine;

namespace Aaris.World
{
    public static class CameraCollision
    {
        public const float Radius = 0.18f;
        public static bool TryLimit(PhysicsScene scene, Vector3 pivot, Vector3 offset, Collider[] scratch, out float distance)
        {
            if (scratch == null || scratch.Length == 0 || !WorldValidator.Finite(pivot.x) || !WorldValidator.Finite(pivot.y) || !WorldValidator.Finite(pivot.z) || !WorldValidator.Finite(offset.x) || !WorldValidator.Finite(offset.y) || !WorldValidator.Finite(offset.z)) throw new System.ArgumentException("Finite camera pose and overlap buffer required.");
            distance = 0;
            if (scene.OverlapSphere(pivot, Radius, scratch, SandboxLayers.SolidMask, QueryTriggerInteraction.Ignore) > 0) return false;
            float length = offset.magnitude; if (length < 0.001f) return true;
            Vector3 direction = offset / length; distance = length;
            if (scene.SphereCast(pivot, Radius, direction, out var hit, length, SandboxLayers.SolidMask, QueryTriggerInteraction.Ignore)) distance = Mathf.Max(0, hit.distance - 0.04f);
            // Sphere sweeps do not cover initial overlaps. Also validate the final volume;
            // closed concave meshes and contact tolerances can otherwise place the camera in solid geometry.
            if (scene.OverlapSphere(pivot + direction * distance, Radius, scratch, SandboxLayers.SolidMask, QueryTriggerInteraction.Ignore) > 0)
            {
                float low = 0, high = distance;
                for (int i = 0; i < 10; i++)
                {
                    float middle = (low + high) * 0.5f;
                    if (scene.OverlapSphere(pivot + direction * middle, Radius, scratch, SandboxLayers.SolidMask, QueryTriggerInteraction.Ignore) == 0) low = middle; else high = middle;
                }
                distance = low;
            }
            return true;
        }
    }
}

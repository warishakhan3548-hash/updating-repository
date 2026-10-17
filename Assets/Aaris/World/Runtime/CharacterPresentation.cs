using System;
using UnityEngine;

namespace Aaris.World
{
    // Original articulated development art, not a production skinned/animated character.
    // All pose writes stay below PhysicsPawn.visual: collision and locomotion remain native physics.
    [DisallowMultipleComponent]
    [DefaultExecutionOrder(100)]
    public sealed class CharacterPresentation : MonoBehaviour
    {
        public PhysicsPawn pawn;
        public Transform hips, chest, head, rifle, muzzle;
        public Transform leftThigh, leftShin, leftFoot, rightThigh, rightShin, rightFoot;
        public Transform leftArm, leftForearm, rightArm, rightForearm;
        public Transform leftGrip, rightGrip;
        public float height = 1.8f;
        private float phase, movementBlend, aimBlend, sprintBlend, groundBlend = 1;
        private bool Ready => hips != null && chest != null && head != null && rifle != null &&
            leftThigh != null && leftShin != null && leftFoot != null && rightThigh != null &&
            rightShin != null && rightFoot != null && leftArm != null && leftForearm != null &&
            rightArm != null && rightForearm != null && leftGrip != null && rightGrip != null;

        private void LateUpdate()
        {
            if (pawn == null || pawn.Body == null) return;
            var input = pawn.input;
            float pitch = pawn.cameraRig != null ? Mathf.DeltaAngle(0, pawn.cameraRig.View.transform.eulerAngles.x) : 0;
            UpdatePose(Time.deltaTime, pawn.Body.linearVelocity, pawn.Grounded,
                input != null && input.Aim, input != null && input.Sprint && !input.Aim, pitch);
        }

        // Explicit pose entry point also permits EditMode checks without running a physics scene.
        // No meshes, materials or objects are allocated here, and no physics root is repositioned.
        public void UpdatePose(float deltaTime, Vector3 worldVelocity, bool grounded, bool aiming, bool sprinting, float aimPitch)
        {
            if (!WorldValidator.Finite(deltaTime) || deltaTime < 0 || !WorldValidator.Finite(aimPitch) ||
                !WorldValidator.Finite(worldVelocity.x) || !WorldValidator.Finite(worldVelocity.y) || !WorldValidator.Finite(worldVelocity.z))
                throw new ArgumentException("A finite presentation pose is required.");
            if (!Ready || !WorldValidator.Finite(height) || height < 0.5f || height > 3) return;
            float dt = Mathf.Min(deltaTime, 0.05f); // A hitch cannot create an unbounded pose/phase jump.
            // Clamp before matrix multiplication, so even finite extreme test values stay finite.
            Vector3 local = transform.InverseTransformDirection(new Vector3(Mathf.Clamp(worldVelocity.x, -60, 60), 0, Mathf.Clamp(worldVelocity.z, -60, 60)));
            local.y = 0;
            float speed = Mathf.Min(local.magnitude, height * 6);
            Vector3 direction = local.sqrMagnitude > 0.0001f ? local.normalized : Vector3.forward;
            float walkSpeed = pawn != null ? Mathf.Max(0.1f, (float)pawn.settings.walkSpeed) : height * 2.5f;
            movementBlend = Mathf.MoveTowards(movementBlend, Mathf.Clamp01(speed / walkSpeed), dt * 7);
            aimBlend = Mathf.MoveTowards(aimBlend, aiming ? 1 : 0, dt * 7);
            sprintBlend = Mathf.MoveTowards(sprintBlend, sprinting && speed > walkSpeed * 0.9f ? 1 : 0, dt * 5);
            groundBlend = Mathf.MoveTowards(groundBlend, grounded ? 1 : 0, dt * 9);
            // Driven by measured planar velocity, never by a held movement key against a wall.
            phase = Mathf.Repeat(phase + Mathf.Min(speed / (height * 1.6f), 2.7f) * dt * Mathf.PI * 2, Mathf.PI * 2);
            float stride = movementBlend * groundBlend;
            float breath = Mathf.Sin(Time.time * 1.8f) * height * 0.0015f * (1 - movementBlend);
            hips.localPosition = new Vector3(0, height * (0.52f - 0.025f * stride), 0);
            chest.localPosition = new Vector3(0, height * 0.61f + breath - height * 0.012f * stride, 0);
            chest.localRotation = Quaternion.Euler(5 * sprintBlend, 0, -direction.x * stride * 5);
            head.localRotation = Quaternion.Euler(Mathf.Clamp(aimPitch, -30, 50) * 0.25f, 0, direction.x * stride * 2);
            // Muzzle and both grips are children of the same animated rifle pivot.
            // PhysicsWeapon continues to check its chest-to-muzzle obstruction segment.
            rifle.localRotation = Quaternion.Euler(Mathf.Clamp(aimPitch, -30, 55) * Mathf.Lerp(0.35f, 1, aimBlend) + sprintBlend * 13, 0, -sprintBlend * 8);

            PoseLeg(leftThigh, leftShin, leftFoot, -1, phase, direction, stride);
            PoseLeg(rightThigh, rightShin, rightFoot, 1, phase + Mathf.PI, direction, stride);
            SolveLimb(leftArm, leftForearm, leftGrip.position,
                chest.TransformPoint(new Vector3(-height * 0.4f, -height * 0.3f, -height * 0.05f)), height * 0.17f, height * 0.16f);
            SolveLimb(rightArm, rightForearm, rightGrip.position,
                chest.TransformPoint(new Vector3(height * 0.4f, -height * 0.3f, -height * 0.05f)), height * 0.17f, height * 0.16f);
        }

        private void PoseLeg(Transform thigh, Transform shin, Transform foot, float side, float cycle, Vector3 direction, float stride)
        {
            float swing = Mathf.Sin(cycle) * height * Mathf.Lerp(0.12f, 0.18f, sprintBlend) * stride;
            float lift = Mathf.Max(0, Mathf.Cos(cycle)) * height * 0.075f * stride;
            Vector3 ankle = new Vector3(side * height * 0.079f + direction.x * swing, height * 0.055f + lift, direction.z * swing);
            ankle.y += height * 0.08f * (1 - groundBlend);
            SolveLimb(thigh, shin, transform.TransformPoint(ankle),
                transform.TransformPoint(new Vector3(side * height * 0.079f, height * 0.25f, height)), height * 0.245f, height * 0.245f);
            foot.rotation = transform.rotation;
        }

        private static void SolveLimb(Transform upper, Transform lower, Vector3 target, Vector3 pole, float upperLength, float lowerLength)
        {
            Vector3 shoulder = upper.position;
            Vector3 toTarget = target - shoulder;
            float distance = Mathf.Clamp(toTarget.magnitude, 0.001f, upperLength + lowerLength - 0.0001f);
            Vector3 forward = toTarget.sqrMagnitude > 0.000001f ? toTarget.normalized : Vector3.down;
            Vector3 bend = Vector3.ProjectOnPlane(pole - shoulder, forward);
            if (bend.sqrMagnitude < 0.0001f)
            {
                // A collinear pole has no bend plane. Pick an axis that cannot
                // be parallel to the bone, rather than normalizing a zero cross.
                Vector3 reference = upper.parent.right;
                if (Mathf.Abs(Vector3.Dot(forward, reference)) > 0.9f)
                    reference = upper.parent.forward;
                bend = Vector3.Cross(forward, reference);
            }
            bend.Normalize();
            float along = Mathf.Clamp((upperLength * upperLength - lowerLength * lowerLength + distance * distance) / (2 * distance), -upperLength, upperLength);
            Vector3 elbow = shoulder + forward * along + bend * Mathf.Sqrt(Mathf.Max(0, upperLength * upperLength - along * along));
            upper.localRotation = Quaternion.FromToRotation(Vector3.down, upper.parent.InverseTransformDirection(elbow - shoulder));
            lower.localRotation = Quaternion.FromToRotation(Vector3.down, upper.InverseTransformDirection(shoulder + forward * distance - elbow));
        }
    }
}

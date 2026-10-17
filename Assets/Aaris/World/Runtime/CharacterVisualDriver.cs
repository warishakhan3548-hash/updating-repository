using System;
using System.Collections.Generic;
using UnityEngine;

namespace Aaris.World
{
    // Presentation only. Never moves the authoritative Rigidbody or collider.
    [DisallowMultipleComponent]
    public sealed class CharacterVisualDriver : MonoBehaviour
    {
        private static readonly int Speed = Animator.StringToHash("Speed");
        private static readonly int MoveX = Animator.StringToHash("MoveX");
        private static readonly int MoveY = Animator.StringToHash("MoveY");
        private static readonly int VerticalSpeed = Animator.StringToHash("VerticalSpeed");
        private static readonly int Grounded = Animator.StringToHash("Grounded");
        private static readonly int Aiming = Animator.StringToHash("Aiming");
        private static readonly int Sprinting = Animator.StringToHash("Sprinting");
        private readonly HashSet<int> floatParameters = new HashSet<int>();
        private readonly HashSet<int> boolParameters = new HashSet<int>();
        private PhysicsPawn pawn;
        private Animator animator;

        public void Bind(PhysicsPawn source, Animator controller)
        {
            if (source == null || controller == null)
                throw new ArgumentNullException(source == null ? nameof(source) : nameof(controller));
            pawn = source;
            animator = controller;
            floatParameters.Clear();
            boolParameters.Clear();
            foreach (var parameter in animator.parameters)
            {
                if (parameter.type == AnimatorControllerParameterType.Float) floatParameters.Add(parameter.nameHash);
                else if (parameter.type == AnimatorControllerParameterType.Bool) boolParameters.Add(parameter.nameHash);
            }
            // Root motion cannot override physical capsule movement.
            animator.applyRootMotion = false;
        }

        private void Update()
        {
            if (pawn == null || animator == null || pawn.Body == null || pawn.visual == null) return;
            float dt = Mathf.Min(Time.deltaTime, 0.05f);
            if (dt <= 0) return;
            Vector3 velocity = pawn.Body.linearVelocity;
            if (!WorldValidator.Finite(velocity.x) || !WorldValidator.Finite(velocity.y) || !WorldValidator.Finite(velocity.z)) return;
            float sprintSpeed = Mathf.Max(0.1f, (float)pawn.settings.sprintSpeed);
            Vector3 flat = new Vector3(velocity.x, 0, velocity.z);
            Vector3 local = Quaternion.Inverse(pawn.visual.rotation) * flat;
            SetFloat(Speed, Mathf.Clamp01(flat.magnitude / sprintSpeed), dt);
            SetFloat(MoveX, Mathf.Clamp(local.x / sprintSpeed, -1f, 1f), dt);
            SetFloat(MoveY, Mathf.Clamp(local.z / sprintSpeed, -1f, 1f), dt);
            SetFloat(VerticalSpeed, Mathf.Clamp(velocity.y, -20f, 20f), dt);
            SetBool(Grounded, pawn.Grounded);
            SetBool(Aiming, pawn.input != null && pawn.input.Aim);
            SetBool(Sprinting, pawn.input != null && pawn.input.Sprint && !pawn.input.Aim && flat.sqrMagnitude > 1f);
        }

        private void SetFloat(int id, float value, float dt)
        {
            if (floatParameters.Contains(id)) animator.SetFloat(id, value, 0.12f, dt);
        }
        private void SetBool(int id, bool value)
        {
            if (boolParameters.Contains(id)) animator.SetBool(id, value);
        }
    }

    // Original low-cost blockout gait, independent of solver, collision and shooting.
    [DisallowMultipleComponent]
    public sealed class PrototypeGait : MonoBehaviour
    {
        private PhysicsPawn pawn;
        private Transform leftLeg, rightLeg, leftArm, rightArm;
        private float cycle, blend;

        public void Bind(PhysicsPawn source, Transform leftHip, Transform rightHip, Transform leftShoulder, Transform rightShoulder)
        {
            pawn = source; leftLeg = leftHip; rightLeg = rightHip;
            leftArm = leftShoulder; rightArm = rightShoulder;
        }

        private void Update()
        {
            if (pawn == null || pawn.Body == null || leftLeg == null || rightLeg == null || leftArm == null || rightArm == null) return;
            Vector3 v = pawn.Body.linearVelocity;
            if (!WorldValidator.Finite(v.x) || !WorldValidator.Finite(v.z)) return;
            float dt = Mathf.Min(Time.deltaTime, 0.05f);
            if (dt <= 0) return;
            float speed = new Vector2(v.x, v.z).magnitude;
            float target = pawn.Grounded ? Mathf.Clamp01(speed / Mathf.Max(0.1f, (float)pawn.settings.walkSpeed)) : 0;
            blend = Mathf.MoveTowards(blend, target, dt * 6f);
            if (blend > 0.001f) cycle = Mathf.Repeat(cycle + dt * (4.5f + speed * 0.7f), 2f * Mathf.PI);
            float swing = Mathf.Sin(cycle) * 26f * blend;
            leftLeg.localRotation = Quaternion.Euler(swing, 0, 0);
            rightLeg.localRotation = Quaternion.Euler(-swing, 0, 0);
            leftArm.localRotation = Quaternion.Euler(-swing * 0.7f, 0, 0);
            rightArm.localRotation = Quaternion.Euler(swing * 0.7f, 0, 0);
        }
    }
}

using UnityEngine;

namespace Aaris.World
{
    [DefaultExecutionOrder(-200)]
    public sealed class SandboxInput : MonoBehaviour
    {
        private readonly TouchOwnership ownership = new TouchOwnership();
        private readonly InputPulse jump = new InputPulse(), reload = new InputPulse(), fireTap = new InputPulse();
        private bool autoSprint, focused = true, paused;
        private Rect safe;
        private Vector3 previousMouse;
        public Vector2 Move { get; private set; }
        public Vector2 Look { get; private set; } // Displacement / safe short edge; not multiplied by frame delta time.
        public bool Fire { get; private set; }
        public bool Sprint { get; private set; }
        public bool Aim { get; private set; }
        public Rect SafeArea => safe;
        public bool ConsumeJump() => jump.Consume(Time.realtimeSinceStartupAsDouble, 0.15);
        public bool ConsumeReload() => reload.Consume(Time.realtimeSinceStartupAsDouble, 0.3);
        // A press-and-release inside one render frame must survive until a physics tick.
        public bool ConsumeFireTap() => fireTap.Consume(Time.realtimeSinceStartupAsDouble, 0.16);
        public void Clear()
        {
            ownership.Clear(); Move = Look = Vector2.zero;
            Fire = Sprint = Aim = autoSprint = false; jump.Clear(); reload.Clear(); fireTap.Clear(); previousMouse = Input.mousePosition;
        }
        private void OnEnable() { safe = Screen.safeArea; Clear(); }
        private void OnDisable() { Clear(); }
        private void OnApplicationFocus(bool value) { focused = value; if (!focused) Clear(); }
        private void OnApplicationPause(bool value) { paused = value; if (paused) Clear(); }

        private void Update()
        {
            if (!focused || paused) { Clear(); return; }
            if (safe != Screen.safeArea) { safe = Screen.safeArea; Clear(); }
            Look = Vector2.zero;
            if (safe.width <= 0 || safe.height <= 0) return;
            if (Input.touchCount > 0)
            {
                // Inspect up to 32 touches so a valid owner is not pruned when other fingers arrive.
                System.Span<int> active = stackalloc int[32]; int count = Mathf.Min(32, Input.touchCount);
                for (int i = 0; i < count; i++) active[i] = Input.GetTouch(i).fingerId;
                if (Input.touchCount <= 32) ownership.Prune(active.Slice(0, count));
                if (!ownership.Held(TouchRole.Move)) { Move = Vector2.zero; autoSprint = false; }
                float shortEdge = Mathf.Min(safe.width, safe.height);
                for (int i = 0; i < count; i++)
                {
                    var touch = Input.GetTouch(i);
                    double x = (touch.position.x - safe.x) / safe.width, y = (touch.position.y - safe.y) / safe.height;
                    if (touch.phase == TouchPhase.Began && ownership.Begin(touch.fingerId, x, y) && ownership.Get(touch.fingerId, out var begun, out _))
                    { if (begun == TouchRole.Jump) jump.Request(Time.realtimeSinceStartupAsDouble); if (begun == TouchRole.Reload) reload.Request(Time.realtimeSinceStartupAsDouble); if (begun == TouchRole.Fire) fireTap.Request(Time.realtimeSinceStartupAsDouble); }
                    if (!ownership.Get(touch.fingerId, out var role, out var origin)) continue;
                    if (touch.phase == TouchPhase.Ended || touch.phase == TouchPhase.Canceled)
                    {
                        ownership.End(touch.fingerId);
                        if (role == TouchRole.Move) { Move = Vector2.zero; autoSprint = false; }
                        if (touch.phase == TouchPhase.Canceled) { if (role == TouchRole.Jump) jump.Clear(); if (role == TouchRole.Reload) reload.Clear(); }
                        continue;
                    }
                    if (role == TouchRole.Move)
                    {
                        var delta = new Vector2((float)(x - origin.x) * safe.width, (float)(y - origin.z) * safe.height) / (shortEdge * 0.14f);
                        float magnitude = delta.magnitude;
                        Move = magnitude < 0.12f ? Vector2.zero : delta.normalized * Mathf.Clamp01((magnitude - 0.12f) / 0.88f);
                        autoSprint = magnitude > 1.25f && Move.y > 0.65f;
                    }
                    else if ((role == TouchRole.Look || role == TouchRole.Fire) && touch.phase == TouchPhase.Moved) Look += touch.deltaPosition / shortEdge;
                }
                Fire = ownership.Held(TouchRole.Fire); Sprint = autoSprint || ownership.Held(TouchRole.Sprint); Aim = ownership.Held(TouchRole.Aim);
            }
            else
            {
                // A missing/cancelled touch must never leave the gun or joystick stuck.
                ownership.Clear();
                autoSprint = false;
                Move = Vector2.ClampMagnitude(new Vector2((Input.GetKey(KeyCode.D) ? 1 : 0) - (Input.GetKey(KeyCode.A) ? 1 : 0),
                    (Input.GetKey(KeyCode.W) ? 1 : 0) - (Input.GetKey(KeyCode.S) ? 1 : 0)), 1);
                Fire = Input.GetMouseButton(0); Aim = Input.GetMouseButton(1); Sprint = Input.GetKey(KeyCode.LeftShift);
                if (Input.GetMouseButtonDown(0)) fireTap.Request(Time.realtimeSinceStartupAsDouble);
                if (Aim) Look = (Vector2)(Input.mousePosition - previousMouse) / Mathf.Min(safe.width, safe.height);
                if (Input.GetKeyDown(KeyCode.Space)) jump.Request(Time.realtimeSinceStartupAsDouble);
                if (Input.GetKeyDown(KeyCode.R)) reload.Request(Time.realtimeSinceStartupAsDouble);
            }
            previousMouse = Input.mousePosition;
        }
    }
}

using UnityEngine;

namespace Aaris.World
{
    [DefaultExecutionOrder(-200)]
    public sealed class SandboxInput : MonoBehaviour
    {
        private readonly TouchOwnership ownership = new TouchOwnership();
        private bool jumpQueued, reloadQueued, autoSprint;
        private Rect safe;
        private Vector3 previousMouse;
        public Vector2 Move { get; private set; }
        public Vector2 Look { get; private set; } // Displacement / safe short edge; not multiplied by frame delta time.
        public bool Fire { get; private set; }
        public bool Sprint { get; private set; }
        public bool Aim { get; private set; }
        public Rect SafeArea => safe;
        public bool ConsumeJump() { bool value = jumpQueued; jumpQueued = false; return value; }
        public bool ConsumeReload() { bool value = reloadQueued; reloadQueued = false; return value; }
        public void Clear()
        {
            ownership.Clear(); Move = Look = Vector2.zero;
            Fire = Sprint = Aim = jumpQueued = reloadQueued = autoSprint = false; previousMouse = Input.mousePosition;
        }
        private void OnEnable() { safe = Screen.safeArea; Clear(); }
        private void OnDisable() { Clear(); }
        private void OnApplicationFocus(bool focused) { if (!focused) Clear(); }
        private void OnApplicationPause(bool paused) { if (paused) Clear(); }

        private void Update()
        {
            if (safe != Screen.safeArea) { safe = Screen.safeArea; Clear(); }
            Look = Vector2.zero;
            if (safe.width <= 0 || safe.height <= 0) return;
            if (Input.touchCount > 0)
            {
                float shortEdge = Mathf.Min(safe.width, safe.height);
                for (int i = 0; i < Input.touchCount; i++)
                {
                    var touch = Input.GetTouch(i);
                    double x = (touch.position.x - safe.x) / safe.width, y = (touch.position.y - safe.y) / safe.height;
                    if (touch.phase == TouchPhase.Began && ownership.Begin(touch.fingerId, x, y) && ownership.Get(touch.fingerId, out var begun, out _))
                    { jumpQueued |= begun == TouchRole.Jump; reloadQueued |= begun == TouchRole.Reload; }
                    if (!ownership.Get(touch.fingerId, out var role, out var origin)) continue;
                    if (touch.phase == TouchPhase.Ended || touch.phase == TouchPhase.Canceled)
                    { ownership.End(touch.fingerId); if (role == TouchRole.Move) { Move = Vector2.zero; autoSprint = false; } continue; }
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
                if (Aim) Look = (Vector2)(Input.mousePosition - previousMouse) / Mathf.Min(safe.width, safe.height);
                jumpQueued |= Input.GetKeyDown(KeyCode.Space); reloadQueued |= Input.GetKeyDown(KeyCode.R);
            }
            previousMouse = Input.mousePosition;
        }
    }
}

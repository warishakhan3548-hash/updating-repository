using UnityEngine;

namespace Aaris.World
{
    // Native Unity development harness. Production HUD/art/accessibility is a separate milestone.
    public sealed class SandboxHud : MonoBehaviour
    {
        public SandboxSession session;
        private GUIStyle label, button;
        private static readonly TouchRole[] Buttons = { TouchRole.Move, TouchRole.Fire, TouchRole.Jump, TouchRole.Reload, TouchRole.Aim, TouchRole.Sprint, TouchRole.Crouch };
        private void OnGUI()
        {
            if (session == null || session.input == null || session.weapon.State == null) return;
            if (label == null)
            {
                label = new GUIStyle(GUI.skin.box) { alignment = TextAnchor.MiddleLeft, fontSize = 18, wordWrap = true };
                button = new GUIStyle(GUI.skin.box) { alignment = TextAnchor.MiddleCenter, fontSize = 18, wordWrap = true };
            }
            Rect safe = session.input.SafeArea;
            Rect GuiRect(ControlRect r) => new Rect(safe.x + (float)r.x * safe.width, Screen.height - safe.y - (float)(r.y + r.height) * safe.height, (float)r.width * safe.width, (float)r.height * safe.height);
            foreach (var role in Buttons)
            {
                string text = role == TouchRole.Move ? "MOVE\nDrag left thumb" : role.ToString().ToUpperInvariant();
                GUI.Box(GuiRect(ControlLayout.Rect(role)), text, button);
            }
            var state = session.weapon.State; int alive = 0; foreach (var target in session.targets) if (!target.Dead) alive++;
            GUI.Box(new Rect(safe.x + 12, Screen.height - safe.yMax + 12, Mathf.Min(650, safe.width - 24), 72),
                "AARIS / LOCAL PHYSICS SANDBOX\n" + (state.Reloading ? "RELOADING" : state.Ammo + " / " + state.Reserve) + "   Targets: " + alive + "/" + session.targets.Length + "   " + (!session.cameraRig.ClearView ? "VIEW BLOCKED" : session.pawn.Crouched ? "CROUCHED" : session.pawn.Grounded ? "GROUNDED" : "AIRBORNE"), label);
            if (GUI.Button(new Rect(safe.xMax - 160, Screen.height - safe.yMax + 95, 145, 42), "RESET SANDBOX")) session.ResetSandbox();
            GUI.color = session.weapon.HitMarker ? Color.red : Color.white;
            GUI.Label(new Rect(Screen.width / 2f - 8, Screen.height / 2f - 14, 28, 28), "+"); GUI.color = Color.white;
        }
    }
}

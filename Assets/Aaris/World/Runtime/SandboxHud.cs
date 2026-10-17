using UnityEngine;

namespace Aaris.World
{
    // Local practice telemetry, not a multiplayer match HUD. Input uses ControlLayout.
    public sealed class SandboxHud : MonoBehaviour
    {
        public SandboxSession session;
        private readonly TacticalMinimap minimap = new TacticalMinimap();
        private GUIStyle text, title, control, reset;
        private double nextTextUpdate;
        private string ammunition = "", navigation = "", zoneStatus = "", health = "";
        private bool outsideZone;
        private static readonly string[] Headings = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" };
        private static readonly TouchRole[] Buttons = { TouchRole.Move, TouchRole.Fire, TouchRole.Jump, TouchRole.Reload, TouchRole.Aim, TouchRole.Sprint };
        private static readonly string[] ButtonLabels = { "MOVE", "FIRE", "JUMP", "RELOAD", "AIM", "SPRINT" };
        private static readonly Color Panel = new Color(0.035f, 0.065f, 0.08f, 0.88f);
        private static readonly Color Accent = new Color(0.4f, 0.9f, 0.84f);
        private static readonly Color Warning = new Color(1f, 0.67f, 0.25f);

        private void OnEnable() { nextTextUpdate = 0; }
        private void OnDisable() { minimap.Dispose(); }
        private void OnDestroy() { minimap.Dispose(); }

        private bool Ready => session != null && session.input != null && session.weapon != null &&
            session.weapon.State != null && session.pawn != null && session.pawn.Body != null && session.cameraRig != null;

        private void Update()
        {
            if (!Ready) return;
            // Build once per source revision, outside OnGUI's multiple event passes.
            minimap.EnsureWorld(session.world);
            if (Time.unscaledTimeAsDouble < nextTextUpdate) return;
            nextTextUpdate = Time.unscaledTimeAsDouble + 0.1;
            var state = session.weapon.State;
            int active = 0;
            foreach (var target in session.targets) if (target != null && !target.Dead) active++;
            ammunition = (state.Reloading ? "RELOADING" : state.Ammo + " / " + state.Reserve) +
                "   TARGETS " + active + "/" + session.targets.Length;
            int supplies = 0;
            if (session.loot != null)
                foreach (var item in session.loot)
                    if (item != null && item.gameObject.activeSelf) supplies++;
            int heading = Mathf.RoundToInt((float)TacticalNavigation.NormalizeHeading(session.cameraRig.Yaw)) % 360;
            navigation = Headings[((heading + 22) / 45) % 8] + " " + heading.ToString("000") + "   " +
                (!session.cameraRig.ClearView ? "VIEW BLOCKED" : session.weapon.BarrelBlocked ? "BARREL BLOCKED" :
                session.pawn.Grounded ? "GROUNDED" : "AIRBORNE") + "   LOOT " + supplies;
            health = "HP " + Mathf.CeilToInt((float)session.PlayerHealth);
            outsideZone = false;
            if (session.settings.zone != null && session.settings.zone.enabled)
            {
                var zone = session.CurrentZone;
                Vector3 p = session.pawn.Body.position;
                var guide = TacticalNavigation.ToSafeZone(zone, p.x, p.z, session.settings.movement.radius);
                outsideZone = guide.outside;
                int seconds = Mathf.CeilToInt((float)zone.timeRemaining);
                string phase = zone.phase == BattleZonePhase.Waiting ? "WAIT " : zone.phase == BattleZonePhase.Shrinking ? "CLOSE " : "FINAL";
                string countdown = zone.phase == BattleZonePhase.Final ? "" : seconds / 60 + ":" + (seconds % 60).ToString("00");
                zoneStatus = phase + countdown + (guide.outside ? " DIRECT " + Mathf.CeilToInt((float)guide.distance) + "m" : " SAFE");
            }
            else zoneStatus = "LOCAL PRACTICE / ZONE OFF";
        }

        // Screen.safeArea is bottom-left; IMGUI is top-left. Panels stay above sprint/fire.
        public static void CalculatePanels(Rect safeArea, int screenHeight, out Rect info, out Rect map)
        {
            float shortEdge = Mathf.Min(safeArea.width, safeArea.height);
            float scale = Mathf.Clamp(shortEdge / 540f, 0.6f, 1.5f);
            float padding = Mathf.Min(Mathf.Clamp(shortEdge * 0.018f, 6f, 20f), shortEdge * 0.04f);
            float top = screenHeight - safeArea.yMax + padding;
            float mapSize = Mathf.Max(0, Mathf.Min(218f * scale, Mathf.Min(safeArea.height * 0.46f - padding * 2, safeArea.width * 0.38f)));
            map = new Rect(safeArea.xMax - padding - mapSize, top, mapSize, mapSize);
            info = new Rect(safeArea.x + padding, top,
                Mathf.Max(0, Mathf.Min(550f * scale, safeArea.width - mapSize - padding * 3)),
                Mathf.Max(0, Mathf.Min(110f * scale, safeArea.height * 0.33f - padding * 2)));
        }

        private void OnGUI()
        {
            if (!Ready) return;
            Rect safe = session.input.SafeArea;
            if (safe.width <= 0 || safe.height <= 0) return;
            EnsureStyles();
            float scale = Mathf.Clamp(Mathf.Min(safe.width, safe.height) / 540f, 0.6f, 1.5f);
            text.fontSize = Mathf.Max(10, Mathf.RoundToInt(15f * scale));
            title.fontSize = control.fontSize = Mathf.Max(10, Mathf.RoundToInt(14f * scale));
            reset.fontSize = Mathf.Max(9, Mathf.RoundToInt(12f * scale));
            CalculatePanels(safe, Screen.height, out Rect info, out Rect map);
            Color oldColor = GUI.color;
            try
            {
                GUI.color = Color.white;
                DrawInformation(info, scale);
                if (Event.current.type != EventType.Repaint) return;
                Vector3 p = session.pawn.Body.position;
                minimap.Draw(map, p, session.cameraRig.Yaw, session.CurrentZone,
                    session.settings.zone, (float)session.settings.movement.radius);
                for (int i = 0; i < Buttons.Length; i++)
                {
                    ControlRect r = ControlLayout.Rect(Buttons[i]);
                    Rect rect = new Rect(safe.x + (float)r.x * safe.width,
                        Screen.height - safe.y - (float)(r.y + r.height) * safe.height,
                        (float)r.width * safe.width, (float)r.height * safe.height);
                    bool held = Buttons[i] == TouchRole.Move ? session.input.Move.sqrMagnitude > 0 :
                        Buttons[i] == TouchRole.Fire ? session.input.Fire : Buttons[i] == TouchRole.Aim ? session.input.Aim :
                        Buttons[i] == TouchRole.Sprint ? session.input.Sprint : Buttons[i] == TouchRole.Reload && session.weapon.State.Reloading;
                    DrawControl(rect, ButtonLabels[i], held, Buttons[i] == TouchRole.Move, scale);
                }
                DrawReticle(scale);
            }
            finally { GUI.color = oldColor; }
        }

        private void EnsureStyles()
        {
            if (text != null) return;
            text = new GUIStyle(GUI.skin.label) { alignment = TextAnchor.MiddleLeft, wordWrap = false, clipping = TextClipping.Clip, padding = new RectOffset(0, 0, 0, 0) };
            text.normal.textColor = new Color(0.9f, 0.95f, 0.95f);
            title = new GUIStyle(text) { fontStyle = FontStyle.Bold };
            title.normal.textColor = Accent;
            control = new GUIStyle(text) { alignment = TextAnchor.MiddleCenter };
            reset = new GUIStyle(GUI.skin.button) { alignment = TextAnchor.MiddleCenter, padding = new RectOffset(1, 1, 1, 1) };
        }

        private void DrawInformation(Rect area, float scale)
        {
            if (area.width < 1 || area.height < 1) return;
            Fill(area, Panel);
            GUI.BeginGroup(area);
            try
            {
                float margin = 7 * scale;
                float row = Mathf.Max(1, (area.height - margin * 2 - 5 * scale) / 4f);
                float width = Mathf.Max(1, area.width - margin * 2);
                float resetWidth = Mathf.Min(66 * scale, width * 0.3f);
                GUI.Label(new Rect(margin, margin, width - resetWidth - 4, row), "AARIS / PRACTICE", title);
                if (GUI.Button(new Rect(area.width - margin - resetWidth, margin, resetWidth, row), "RESET", reset))
                { session.ResetSandbox(); nextTextUpdate = 0; }
                GUI.Label(new Rect(margin, margin + row, width, row), ammunition, text);
                GUI.Label(new Rect(margin, margin + row * 2, width, row), navigation, text);
                Color old = GUI.color;
                GUI.color = outsideZone ? Warning : Color.white;
                float healthWidth = Mathf.Max(44, 61 * scale);
                GUI.Label(new Rect(margin, margin + row * 3, Mathf.Max(0, width - healthWidth), row), zoneStatus, text);
                GUI.color = old;
                GUI.Label(new Rect(area.width - margin - healthWidth, margin + row * 3, healthWidth, row), health, text);
                Rect bar = new Rect(margin, area.height - margin - 4 * scale, width, 4 * scale);
                Fill(bar, new Color(0.2f, 0.25f, 0.27f));
                bar.width *= Mathf.Clamp01((float)session.PlayerHealth / 100);
                Fill(bar, outsideZone || session.PlayerHealth <= 30 ? Warning : Accent);
            }
            finally { GUI.EndGroup(); }
        }

        private void DrawControl(Rect rect, string caption, bool held, bool movement, float scale)
        {
            Color tint = held ? new Color(0.4f, 0.9f, 0.84f, 0.75f) : new Color(0.75f, 0.85f, 0.88f, 0.27f);
            // Visuals only: GUI buttons here would compete with touch ownership.
            Fill(rect, new Color(0.025f, 0.05f, 0.06f, movement ? 0.05f : 0.19f));
            TacticalMinimap.Frame(rect, tint, 1);
            if (movement)
            {
                float radius = Mathf.Min(rect.width, rect.height) * 0.24f;
                Vector2 center = rect.center;
                TacticalMinimap.Circle(center, new Vector2(radius, radius), tint, 1, false, 24);
                Vector2 knob = center + new Vector2(session.input.Move.x, -session.input.Move.y) * radius;
                Fill(new Rect(knob.x - 5 * scale, knob.y - 5 * scale, 10 * scale, 10 * scale), tint);
                GUI.Label(new Rect(rect.x, rect.yMax - 22 * scale, rect.width, 18 * scale), caption, control);
            }
            else GUI.Label(rect, caption, control);
        }

        private void DrawReticle(float scale)
        {
            if (!session.cameraRig.ClearView) return;
            Vector2 center = new Vector2(Screen.width * 0.5f, Screen.height * 0.5f);
            float gap = (session.input.Aim ? 4 : 7) * scale, length = 5 * scale;
            Color tint = session.weapon.HitMarker ? new Color(1, 0.3f, 0.3f) : session.weapon.BarrelBlocked ? Warning : Color.white;
            Fill(new Rect(center.x - gap - length, center.y - scale * 0.5f, length, scale), tint);
            Fill(new Rect(center.x + gap, center.y - scale * 0.5f, length, scale), tint);
            Fill(new Rect(center.x - scale * 0.5f, center.y - gap - length, scale, length), tint);
            Fill(new Rect(center.x - scale * 0.5f, center.y + gap, scale, length), tint);
        }

        private static void Fill(Rect rect, Color color)
        {
            Color previous = GUI.color; GUI.color = color;
            GUI.DrawTexture(rect, Texture2D.whiteTexture);
            GUI.color = previous;
        }
    }
}

using System;
using UnityEngine;

namespace Aaris.World
{
    // Authored, north-up schematic. No extra camera, render target, actor scan or target markers.
    public sealed class TacticalMinimap : IDisposable
    {
        private const int Resolution = 192;
        private Texture2D texture;
        private WorldSpec source;
        private int revision;
        private TacticalMapProjection projection;
        private GUIContent[] landmarkLabels = Array.Empty<GUIContent>();
        private TacticalMapPoint[] landmarkPoints = Array.Empty<TacticalMapPoint>();
        private GUIStyle label;
        private GUIContent scaleLabel;
        private float scaleFraction;
        private static readonly Color CurrentZoneColor = new Color(0.35f, 0.94f, 0.92f);
        private static readonly Color FinalZoneColor = new Color(0.96f, 0.97f, 0.88f, 0.85f);
        private static readonly Color GuidanceColor = new Color(1f, 0.72f, 0.25f);
        private static readonly Color AmmoColor = new Color(1f, 0.76f, 0.25f);
        private static readonly Color MedkitColor = new Color(0.32f, 1f, 0.55f);

        public void EnsureWorld(WorldSpec world)
        {
            if (world == null || world.grid == null || world.terrain == null)
            { Dispose(); return; }
            if (texture != null && source == world && revision == world.revision) return;
            Dispose();
            projection = new TacticalMapProjection(world.grid);
            source = world; revision = world.revision;
            var pixels = new Color32[Resolution * Resolution];
            var terrain = new TerrainSampler(world);
            var biomeColors = new Color[world.biomes.Length];
            for (int i = 0; i < biomeColors.Length; i++)
                if (!ColorUtility.TryParseHtmlString(world.biomes[i].color, out biomeColors[i])) biomeColors[i] = new Color(0.3f, 0.42f, 0.3f);
            for (int y = 0; y < Resolution; y++) for (int x = 0; x < Resolution; x++)
            {
                double wx = world.grid.originX + x * world.grid.sizeX / (Resolution - 1);
                double wz = world.grid.originZ + y * world.grid.sizeZ / (Resolution - 1);
                Color color = new Color(0.25f, 0.36f, 0.26f);
                for (int i = 0; i < world.biomes.Length; i++)
                {
                    var biome = world.biomes[i];
                    double dx = (wx - biome.x) / biome.radiusX, dz = (wz - biome.z) / biome.radiusZ;
                    float blend = Mathf.Clamp01((float)((1 - dx * dx - dz * dz) * 2));
                    color = Color.Lerp(color, biomeColors[i] * 0.63f, blend);
                }
                float elevation = (float)(terrain.VertexHeight(wx, wz) - world.terrain.baseHeight);
                color *= Mathf.Clamp(0.87f + elevation * 0.009f, 0.68f, 1.35f);
                foreach (var lake in world.terrain.lakes)
                {
                    double dx = (wx - lake.x) / lake.radiusX, dz = (wz - lake.z) / lake.radiusZ;
                    double ellipse = dx * dx + dz * dz;
                    if (ellipse <= 1) color = new Color(0.13f, 0.31f, 0.4f);
                    else if (ellipse < 1.12) color = Color.Lerp(color, new Color(0.55f, 0.53f, 0.36f), 0.6f);
                }
                color.a = 1;
                pixels[y * Resolution + x] = color;
            }
            foreach (var route in world.routes) RasterPath(pixels, route.points, new Color32(173, 156, 99, 255), 0, true);
            foreach (var road in world.roads)
            {
                int radius = Mathf.Clamp(Mathf.RoundToInt((float)(road.width * Resolution / Math.Min(world.grid.sizeX, world.grid.sizeZ)) * 0.5f), 0, 2);
                RasterPath(pixels, road.points, new Color32(41, 48, 42, 255), radius + 1, false);
                RasterPath(pixels, road.points, new Color32(184, 178, 145, 255), radius, false);
            }
            landmarkLabels = new GUIContent[world.landmarks.Length];
            landmarkPoints = new TacticalMapPoint[world.landmarks.Length];
            for (int i = 0; i < world.landmarks.Length; i++)
            {
                var landmark = world.landmarks[i];
                landmarkLabels[i] = new GUIContent(landmark.name);
                landmarkPoints[i] = projection.Project(landmark.x, landmark.z);
                Vector2 point = TexturePoint(landmarkPoints[i]);
                Stamp(pixels, Mathf.RoundToInt(point.x), Mathf.RoundToInt(point.y), 1, new Color32(231, 221, 156, 255));
            }
            texture = new Texture2D(Resolution, Resolution, TextureFormat.RGBA32, false)
            { name = "Aaris authored tactical map", wrapMode = TextureWrapMode.Clamp, filterMode = FilterMode.Bilinear, hideFlags = HideFlags.DontSave };
            texture.SetPixels32(pixels);
            texture.Apply(false, true); // Release CPU storage; dynamic overlays never rebuild this texture.
            double desired = world.grid.sizeX * 0.2;
            double magnitude = Math.Pow(10, Math.Floor(Math.Log10(desired)));
            double units = desired / magnitude;
            double metres = (units >= 5 ? 5 : units >= 2 ? 2 : 1) * magnitude;
            scaleFraction = (float)(metres / world.grid.sizeX);
            scaleLabel = new GUIContent(metres.ToString("0") + " m");
        }

        public void Draw(Rect panel, Vector3 position, float yaw, BattleZoneSnapshot zone, BattleZoneSpec settings, float capsuleRadius,
            LootSpawn[] supplies, Transform[] supplyVisuals)
        {
            if (texture == null || source == null || panel.width < 24 || panel.height < 24) return;
            if (label == null)
            {
                label = new GUIStyle(GUI.skin.label) { alignment = TextAnchor.MiddleCenter, wordWrap = false, clipping = TextClipping.Clip };
                label.normal.textColor = new Color(0.98f, 0.96f, 0.85f);
            }
            label.fontSize = Mathf.Clamp(Mathf.RoundToInt(panel.width / 19), 8, 12);
            Color previous = GUI.color;
            GUI.color = Color.white;
            Fill(panel, new Color(0.025f, 0.05f, 0.065f, 0.94f));
            Rect map = new Rect(panel.x + 3, panel.y + 3, panel.width - 6, panel.height - 6);
            float aspect = (float)(source.grid.sizeX / source.grid.sizeZ);
            if (aspect > 1) { float height = map.width / aspect; map.y += (map.height - height) * 0.5f; map.height = height; }
            else { float width = map.height * aspect; map.x += (map.width - width) * 0.5f; map.width = width; }
            GUI.BeginGroup(map);
            try
            {
                Rect local = new Rect(0, 0, map.width, map.height);
                GUI.DrawTexture(local, texture, ScaleMode.StretchToFill);
                if (settings != null && settings.enabled && zone.radius > 0)
                {
                    DrawZone(local, settings.endX, settings.endZ, settings.endRadius, FinalZoneColor, true);
                    DrawZone(local, zone.x, zone.z, zone.radius, CurrentZoneColor, false);
                    var guide = TacticalNavigation.ToSafeZone(zone, position.x, position.z, capsuleRadius);
                    if (guide.outside)
                    {
                        Vector2 from = MapPoint(local, projection.Project(position.x, position.z));
                        Vector2 to = MapPoint(local, projection.Project(guide.safePoint.x, guide.safePoint.z));
                        // Direct bearing only; this is not a collision-aware walking route.
                        Line(from, to, GuidanceColor, 1.5f);
                        Fill(new Rect(to.x - 2, to.y - 2, 4, 4), GuidanceColor);
                    }
                }
                if (panel.width >= 110)
                {
                    for (int i = 0; i < landmarkLabels.Length; i++)
                    {
                        Vector2 point = MapPoint(local, landmarkPoints[i]);
                        float width = Mathf.Min(label.CalcSize(landmarkLabels[i]).x + 6, local.width * 0.55f);
                        Rect caption = new Rect(Mathf.Clamp(point.x - width * 0.5f, 1, Mathf.Max(1, local.width - width - 1)),
                            Mathf.Clamp(point.y + 3, 13, Mathf.Max(13, local.height - 25)), width, 13);
                        Fill(caption, new Color(0.025f, 0.045f, 0.04f, 0.78f));
                        GUI.Label(caption, landmarkLabels[i], label);
                    }
                }
                // Cheap live pickup overlay; consumed objects disappear without rebaking the cached terrain texture.
                if (supplies != null && supplyVisuals != null)
                {
                    int count = Math.Min(supplies.Length, supplyVisuals.Length);
                    for (int i = 0; i < count; i++)
                    {
                        if (supplyVisuals[i] == null || !supplyVisuals[i].gameObject.activeSelf) continue;
                        var projected = projection.Project(supplies[i].x, supplies[i].z);
                        if (projected.clipped) continue;
                        Vector2 point = MapPoint(local, projected);
                        Color tint = supplies[i].kind == LootKind.Medkit ? MedkitColor : AmmoColor;
                        Fill(new Rect(point.x - 1.7f, point.y - 1.7f, 3.4f, 3.4f), tint);
                    }
                }
                DrawPlayer(local, position, yaw);
                Frame(local, new Color(0.64f, 0.78f, 0.75f, 0.8f), 1);
                GUI.Label(new Rect(local.width * 0.5f - 10, 0, 20, 14), "N", label);
                if (local.width >= 90 && local.height >= 55)
                {
                    float length = local.width * scaleFraction;
                    Line(new Vector2(7, local.height - 8), new Vector2(7 + length, local.height - 8), Color.white, 2);
                    GUI.Label(new Rect(4, local.height - 25, length + 8, 15), scaleLabel, label);
                }
            }
            finally { GUI.EndGroup(); GUI.color = previous; }
        }

        private void DrawZone(Rect map, double x, double z, double radius, Color color, bool dashed)
        {
            var circle = projection.ProjectCircle(x, z, radius);
            Circle(MapPoint(map, circle.center), new Vector2((float)circle.radiusU * map.width, (float)circle.radiusV * map.height), color, dashed ? 1 : 1.7f, dashed, 64);
        }

        private void DrawPlayer(Rect map, Vector3 position, float yaw)
        {
            var projected = projection.Project(position.x, position.z);
            Vector2 center = MapPoint(map, projected);
            center.x = Mathf.Clamp(center.x, 6, Mathf.Max(6, map.width - 6));
            center.y = Mathf.Clamp(center.y, 6, Mathf.Max(6, map.height - 6));
            float angle = (float)TacticalNavigation.NormalizeHeading(yaw) * Mathf.Deg2Rad;
            Vector2 forward = new Vector2(Mathf.Sin(angle), -Mathf.Cos(angle));
            Vector2 right = new Vector2(-forward.y, forward.x);
            Vector2 tip = center + forward * 7, left = center - forward * 4 - right * 4, rightPoint = center - forward * 4 + right * 4;
            Color color = projected.clipped ? GuidanceColor : Color.white;
            Line(tip, left, Color.black, 4); Line(left, rightPoint, Color.black, 4); Line(rightPoint, tip, Color.black, 4);
            Line(tip, left, color, 2); Line(left, rightPoint, color, 2); Line(rightPoint, tip, color, 2);
        }

        private static Vector2 MapPoint(Rect map, TacticalMapPoint p) => new Vector2(map.x + (float)p.u * map.width, map.y + (float)p.v * map.height);
        private static Vector2 TexturePoint(TacticalMapPoint p) => new Vector2((float)p.u * (Resolution - 1), (1 - (float)p.v) * (Resolution - 1));

        private void RasterPath(Color32[] pixels, Point2[] points, Color32 color, int radius, bool dotted)
        {
            for (int i = 1; i < points.Length; i++)
            {
                Vector2 a = TexturePoint(projection.Project(points[i - 1].x, points[i - 1].z));
                Vector2 b = TexturePoint(projection.Project(points[i].x, points[i].z));
                int steps = Mathf.Max(1, Mathf.CeilToInt(Vector2.Distance(a, b)));
                for (int step = 0; step <= steps; step++)
                {
                    if (dotted && step % 6 >= 3) continue;
                    Vector2 point = Vector2.Lerp(a, b, (float)step / steps);
                    Stamp(pixels, Mathf.RoundToInt(point.x), Mathf.RoundToInt(point.y), radius, color);
                }
            }
        }

        private static void Stamp(Color32[] pixels, int x, int y, int radius, Color32 color)
        {
            for (int py = Mathf.Max(0, y - radius); py <= Mathf.Min(Resolution - 1, y + radius); py++)
                for (int px = Mathf.Max(0, x - radius); px <= Mathf.Min(Resolution - 1, x + radius); px++) pixels[py * Resolution + px] = color;
        }

        internal static void Frame(Rect rect, Color color, float width)
        {
            Fill(new Rect(rect.x, rect.y, rect.width, width), color);
            Fill(new Rect(rect.x, rect.yMax - width, rect.width, width), color);
            Fill(new Rect(rect.x, rect.y, width, rect.height), color);
            Fill(new Rect(rect.xMax - width, rect.y, width, rect.height), color);
        }

        internal static void Circle(Vector2 center, Vector2 radius, Color color, float width, bool dashed, int segments)
        {
            Vector2 previous = center + new Vector2(radius.x, 0);
            for (int i = 1; i <= segments; i++)
            {
                float angle = i * (2 * Mathf.PI / segments);
                Vector2 point = center + new Vector2(Mathf.Cos(angle) * radius.x, Mathf.Sin(angle) * radius.y);
                if (!dashed || i % 4 < 2) Line(previous, point, color, width);
                previous = point;
            }
        }

        private static void Line(Vector2 a, Vector2 b, Color color, float width)
        {
            Vector2 delta = b - a;
            if (delta.sqrMagnitude < 0.0001f) return;
            Matrix4x4 previous = GUI.matrix;
            try
            {
                GUIUtility.RotateAroundPivot(Mathf.Atan2(delta.y, delta.x) * Mathf.Rad2Deg, a);
                Fill(new Rect(a.x, a.y - width * 0.5f, delta.magnitude, width), color);
            }
            finally { GUI.matrix = previous; }
        }

        private static void Fill(Rect rect, Color color)
        {
            Color previous = GUI.color; GUI.color = color;
            GUI.DrawTexture(rect, Texture2D.whiteTexture);
            GUI.color = previous;
        }

        public void Dispose()
        {
            if (texture != null)
            {
                if (Application.isPlaying) UnityEngine.Object.Destroy(texture);
                else UnityEngine.Object.DestroyImmediate(texture);
            }
            texture = null; source = null;
            landmarkLabels = Array.Empty<GUIContent>(); landmarkPoints = Array.Empty<TacticalMapPoint>();
        }
    }
}

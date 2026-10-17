using UnityEngine;
using Object = UnityEngine.Object;

namespace Aaris.World.Editor
{
    // Original procedural architectural review geometry. Replaced via asset registry later.
    internal static class ArchitecturalBlockout
    {
        public static GameObject Create(AssetSpec asset, Material material)
        {
            var root = new GameObject("BLOCKOUT_" + asset.id);
            float w = (float)asset.width, d = (float)asset.depth, h = (float)asset.height;
            if (asset.previewShape == "building")
            {
                Part(root, material, new Vector3(0, 0.15f, 0), new Vector3(w, 0.3f, d));
                Part(root, material, new Vector3(0, h - 0.15f, 0), new Vector3(w + 0.4f, 0.3f, d + 0.4f));
                // Door opening on local +Z; segmented walls leave real window apertures.
                float door = Mathf.Min(2, w / 3), side = (w - door) / 2;
                Part(root, material, new Vector3(-(door + side) / 2, h / 2, d / 2), new Vector3(side, h, 0.3f));
                Part(root, material, new Vector3((door + side) / 2, h / 2, d / 2), new Vector3(side, h, 0.3f));
                Part(root, material, new Vector3(0, (h + 2.5f) / 2, d / 2), new Vector3(door, Mathf.Max(0.2f, h - 2.5f), 0.3f));
                Part(root, material, new Vector3(0, h / 2, -d / 2), new Vector3(w, h, 0.3f));
                foreach (float x in new[] { -w / 2, w / 2 })
                {
                    Part(root, material, new Vector3(x, 0.7f, 0), new Vector3(0.3f, 1.4f, d));
                    Part(root, material, new Vector3(x, (h + 3) / 2, 0), new Vector3(0.3f, Mathf.Max(0.2f, h - 3), d));
                    foreach (float z in new[] { -d * 0.38f, 0, d * 0.38f })
                        Part(root, material, new Vector3(x, 2.2f, z), new Vector3(0.3f, 1.6f, d * 0.15f));
                }
            }
            else if (asset.previewShape == "tower")
            {
                foreach (float x in new[] { -w * 0.35f, w * 0.35f })
                    foreach (float z in new[] { -d * 0.35f, d * 0.35f })
                        Part(root, material, new Vector3(x, h * 0.4f, z), new Vector3(0.5f, h * 0.8f, 0.5f));
                Part(root, material, new Vector3(0, h * 0.8f, 0), new Vector3(w, 0.3f, d));
                Part(root, material, new Vector3(0, h, 0), new Vector3(w, 0.25f, d));
            }
            else if (asset.previewShape == "tree")
            {
                Part(root, material, new Vector3(0, h * 0.3f, 0), new Vector3(w * 0.16f, h * 0.6f, d * 0.16f), PrimitiveType.Cylinder);
                Part(root, material, new Vector3(0, h * 0.7f, 0), new Vector3(w, h * 0.6f, d), PrimitiveType.Sphere);
            }
            else Part(root, material, new Vector3(0, h * 0.5f, 0), new Vector3(w, h, d), PrimitiveType.Sphere);
            return root;
        }

        private static void Part(GameObject parent, Material material, Vector3 position, Vector3 size, PrimitiveType type = PrimitiveType.Cube)
        {
            var part = GameObject.CreatePrimitive(type);
            part.name = "Architectural part"; part.transform.SetParent(parent.transform, false);
            part.transform.localPosition = position;
            part.transform.localScale = type == PrimitiveType.Cylinder ? new Vector3(size.x, size.y * 0.5f, size.z) : size;
            part.GetComponent<Renderer>().sharedMaterial = material;
            part.isStatic = true;
            // These colliders are review geometry, not validated final gameplay collision.
        }
    }
}

using UnityEngine;

namespace Aaris.World
{
    public static class SandboxLayers
    {
        public const int World = 8, Prop = 9, Player = 10, Target = 11;
        public const int SolidMask = (1 << World) | (1 << Prop) | (1 << Target);
        public static void SetRecursively(GameObject root, int layer)
        {
            root.layer = layer;
            foreach (Transform child in root.transform) SetRecursively(child.gameObject, layer);
        }
    }
}

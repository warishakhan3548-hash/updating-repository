using UnityEngine;

namespace Aaris.World
{
    // Static local-practice marker: presentation and reward metadata only.
    // No Rigidbody, gameplay collider, Update loop or per-frame allocation.
    public sealed class LocalLootPickup : MonoBehaviour
    {
        public LootKind kind;
        public int amount;
    }
}

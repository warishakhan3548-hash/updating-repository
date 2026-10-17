using UnityEngine;

namespace Aaris.World
{
    [DisallowMultipleComponent]
    public sealed class WorldObjectIdentity : MonoBehaviour
    {
        public string objectId;
        public string assetId;
        public string ownerCell;
        public int worldRevision;
    }
}

using UnityEngine;

namespace Aaris.World
{
    public sealed class Damageable : MonoBehaviour
    {
        public float maxHealth = 100;
        public float Health { get; private set; }
        public bool Dead => Health <= 0;
        private Collider[] colliders;
        private Renderer[] renderers;
        private MaterialPropertyBlock tint;
        private void Awake() { ResetHealth(); }
        public void ResetHealth()
        {
            Health = maxHealth; colliders = GetComponentsInChildren<Collider>(true); renderers = GetComponentsInChildren<Renderer>(true);
            foreach (var c in colliders) c.enabled = true;
            Paint(new Color(0.75f, 0.3f, 0.15f));
        }
        public bool Apply(float damage)
        {
            if (!WorldValidator.Finite(damage) || damage <= 0 || Dead) return false;
            Health = Mathf.Max(0, Health - damage);
            if (colliders == null) { colliders = GetComponentsInChildren<Collider>(true); renderers = GetComponentsInChildren<Renderer>(true); }
            if (Dead) foreach (var c in colliders) c.enabled = false;
            Paint(Dead ? Color.gray : new Color(1, 0.55f, 0.18f)); return true;
        }
        private void Paint(Color color)
        {
            if (tint == null) tint = new MaterialPropertyBlock();
            tint.SetColor("_BaseColor", color);
            if (renderers != null) foreach (var r in renderers) r.SetPropertyBlock(tint);
        }
    }
}

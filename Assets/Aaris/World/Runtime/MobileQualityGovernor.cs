using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace Aaris.World
{
    // Sandbox-only adaptive URP quality; restores every global it changes on disable.
    // CPU-bound frames may not improve from resolution scaling. Profile on real phones.
    [DisallowMultipleComponent]
    [RequireComponent(typeof(Camera))]
    public sealed class MobileQualityGovernor : MonoBehaviour
    {
        public int targetFps = 60;
        private static MobileQualityGovernor owner;
        private MobileFrameBudget policy;
        private UniversalRenderPipelineAsset pipeline;
        private float originalScale, originalLod, originalShadow;
        private bool active;

        private void OnEnable()
        {
            if (!Application.isPlaying || !Application.isMobilePlatform) return;
            if (owner != null && owner != this)
            {
                Debug.LogWarning("Only one MobileQualityGovernor may own runtime quality settings.");
                enabled = false;
                return;
            }
            pipeline = GraphicsSettings.currentRenderPipeline as UniversalRenderPipelineAsset;
            if (pipeline == null)
            {
                Debug.LogWarning("Adaptive graphics disabled: an active URP asset is required.");
                enabled = false;
                return;
            }
            owner = this;
            originalScale = pipeline.renderScale;
            originalLod = QualitySettings.lodBias;
            originalShadow = QualitySettings.shadowDistance;
            policy = new MobileFrameBudget(Mathf.Clamp(targetFps, 30, 120));
            active = true;
        }

        private void Update()
        {
            if (!active) return;
            if (policy.Observe(Time.unscaledDeltaTime)) ApplyTier();
        }

        private void ApplyTier()
        {
            int edge = Mathf.Max(1, Mathf.Min(Screen.width, Screen.height));
            // Never raise render cost above the author-chosen URP quality baseline.
            pipeline.renderScale = Mathf.Min(originalScale, originalScale * (float)policy.RenderScale(edge));
            QualitySettings.lodBias = Mathf.Max(0.1f, originalLod * (float)policy.LodMultiplier);
            QualitySettings.shadowDistance = Mathf.Min(originalShadow, (float)policy.ShadowDistanceMetres);
        }

        private void OnDisable() { Restore(); }
        private void OnDestroy() { Restore(); }

        private void Restore()
        {
            if (!active) return;
            // A different scene may replace the pipeline; never mutate that scene's asset.
            if (pipeline != null) pipeline.renderScale = originalScale;
            QualitySettings.lodBias = originalLod;
            QualitySettings.shadowDistance = originalShadow;
            active = false;
            if (owner == this) owner = null;
        }
    }
}

using UnityEngine;

namespace Aaris.World
{
    // Render-only local clock. Physics, world IDs and authored transforms remain unchanged.
    // Source scene remains static in EditMode; runtime lighting starts at source values.
    [DisallowMultipleComponent]
    public sealed class AtmosphereCycle : MonoBehaviour
    {
        public Light sun;
        [Min(120f)] public float cycleSeconds = 720f;
        [Range(0.05f, 1f)] public float updateIntervalSeconds = 0.12f;

        private bool activeCycle;
        private double startTime;
        private double lastSampleTime;
        private float originalSunIntensity;
        private Color originalSunColor;
        private Quaternion originalSunRotation;
        private Color originalFog;
        private float originalFogDensity;
        private Color originalSky;
        private Color originalEquator;
        private Color originalGround;
        private Material originalSkybox;
        private Material runtimeSkybox;
        private float originalSkyExposure;

        private void OnValidate()
        {
            if (float.IsNaN(cycleSeconds) || float.IsInfinity(cycleSeconds)) cycleSeconds = 720f;
            if (float.IsNaN(updateIntervalSeconds) || float.IsInfinity(updateIntervalSeconds)) updateIntervalSeconds = 0.12f;
            cycleSeconds = Mathf.Clamp(cycleSeconds, 120f, 7200f);
            updateIntervalSeconds = Mathf.Clamp(updateIntervalSeconds, 0.05f, 1f);
        }

        private void OnEnable()
        {
            if (!Application.isPlaying) return;
            if (sun == null) sun = GetComponent<Light>();
            if (sun == null || !sun.isActiveAndEnabled) return;

            OnValidate();
            originalSunIntensity = sun.intensity;
            originalSunColor = sun.color;
            originalSunRotation = sun.transform.rotation;
            originalFog = RenderSettings.fogColor;
            originalFogDensity = RenderSettings.fogDensity;
            originalSky = RenderSettings.ambientSkyColor;
            originalEquator = RenderSettings.ambientEquatorColor;
            originalGround = RenderSettings.ambientGroundColor;
            originalSkybox = RenderSettings.skybox;

            // Never mutate the generated project skybox asset at runtime.
            if (originalSkybox != null && originalSkybox.HasProperty("_Exposure"))
            {
                originalSkyExposure = originalSkybox.GetFloat("_Exposure");
                runtimeSkybox = new Material(originalSkybox) { name = "Aaris Runtime Atmosphere" };
                RenderSettings.skybox = runtimeSkybox;
            }

            startTime = Time.timeAsDouble;
            lastSampleTime = double.NegativeInfinity;
            activeCycle = true;
            Apply(AtmosphereTimeline.Sample(0, cycleSeconds));
        }

        private void Update()
        {
            if (!activeCycle) return;
            double elapsed = Time.timeAsDouble - startTime;
            if (elapsed < 0 || elapsed - lastSampleTime < updateIntervalSeconds) return;
            lastSampleTime = elapsed;
            Apply(AtmosphereTimeline.Sample(elapsed, cycleSeconds));
        }

        private void Apply(AtmosphereFrame frame)
        {
            float darkness = (float)frame.darkness;
            float warmth = (float)frame.duskWarmth;
            float ambient = (float)frame.ambientFactor;
            sun.intensity = originalSunIntensity * (float)frame.sunFactor;
            Color eveningSun = Color.Lerp(new Color(0.64f, 0.73f, 0.96f),
                new Color(1f, 0.66f, 0.43f), warmth);
            sun.color = Color.Lerp(originalSunColor, eveningSun, Mathf.Clamp01(0.75f * darkness + 0.25f * warmth));
            sun.transform.rotation = originalSunRotation * Quaternion.Euler((float)frame.sunPitchOffsetDegrees, 0, 0);
            RenderSettings.ambientSkyColor = originalSky * ambient;
            RenderSettings.ambientEquatorColor = originalEquator * ambient;
            RenderSettings.ambientGroundColor = originalGround * ambient;
            RenderSettings.fogColor = Color.Lerp(originalFog, new Color(0.14f, 0.19f, 0.28f), 0.75f * darkness);
            RenderSettings.fogDensity = Mathf.Min(0.02f, originalFogDensity * (float)frame.fogFactor);
            if (runtimeSkybox != null)
                runtimeSkybox.SetFloat("_Exposure", originalSkyExposure * (float)frame.skyExposureFactor);
        }

        private void OnDisable()
        {
            if (!activeCycle) return;
            activeCycle = false;
            if (sun != null)
            {
                sun.intensity = originalSunIntensity;
                sun.color = originalSunColor;
                sun.transform.rotation = originalSunRotation;
            }
            RenderSettings.fogColor = originalFog;
            RenderSettings.fogDensity = originalFogDensity;
            RenderSettings.ambientSkyColor = originalSky;
            RenderSettings.ambientEquatorColor = originalEquator;
            RenderSettings.ambientGroundColor = originalGround;
            if (runtimeSkybox != null)
            {
                if (RenderSettings.skybox == runtimeSkybox) RenderSettings.skybox = originalSkybox;
                Destroy(runtimeSkybox);
                runtimeSkybox = null;
            }
        }
    }
}

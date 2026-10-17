using System;
using System.IO;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using Object = UnityEngine.Object;

namespace Aaris.World.Editor
{
    public static class WorldReview
    {
        [MenuItem("Aaris/World/Render Review PNGs (No APK)")]
        public static void Render()
        {
            if (SystemInfo.graphicsDeviceType == GraphicsDeviceType.Null)
                throw new InvalidOperationException("Review PNGs need a graphics device (Xvfb/Mesa or GPU). Do not use -nographics. Use the .NET schematic review without Unity.");
            UnityWorldCompiler.Compile();
            var world = UnityWorldCompiler.ReadWorld();
            string output = "Review/unity"; Directory.CreateDirectory(output);
            var camera = Camera.main;
            if (camera == null) throw new InvalidOperationException("Generated review camera is missing.");
            var centre = new Vector3((float)(world.grid.originX + world.grid.sizeX / 2), 0, (float)(world.grid.originZ + world.grid.sizeZ / 2));
            float span = (float)Math.Max(world.grid.sizeX, world.grid.sizeZ);
            camera.orthographic = true; camera.orthographicSize = span * 0.55f;
            Capture(camera, centre + Vector3.up * span, centre, Vector3.forward, output + "/top.png");
            camera.orthographic = false; camera.fieldOfView = 55;
            Capture(camera, centre + new Vector3(0, span * 0.6f, -span * 0.65f), centre, Vector3.up, output + "/overview.png");
            foreach (var landmark in world.landmarks)
            {
                var target = new Vector3((float)landmark.x, (float)new TerrainSampler(world).Height(landmark.x, landmark.z), (float)landmark.z);
                float radius = (float)landmark.radius;
                Capture(camera, target + new Vector3(radius, radius * 1.1f, -radius * 1.4f), target, Vector3.up, output + "/" + landmark.id + ".png");
            }
            File.WriteAllText(output + "/source.json", "{\"world\":\"" + world.id + "\",\"revision\":" + world.revision + "}");
            Debug.Log("Unity review PNGs saved. No Android player was compiled.");
        }

        private static void Capture(Camera camera, Vector3 position, Vector3 target, Vector3 up, string path)
        {
            camera.transform.position = position;
            camera.transform.rotation = Quaternion.LookRotation(target - position, up);
            const int resolution = 1024;
            var rt = new RenderTexture(resolution, resolution, 24, RenderTextureFormat.ARGB32);
            var previous = RenderTexture.active;
            Texture2D image = null;
            try
            {
                rt.Create();
                var request = new UniversalRenderPipeline.SingleCameraRequest { destination = rt };
                if (!RenderPipeline.SupportsRenderRequest(camera, request))
                    throw new InvalidOperationException("Configured URP pipeline does not support a SingleCameraRequest.");
                RenderPipeline.SubmitRenderRequest(camera, request);
                RenderTexture.active = rt;
                image = new Texture2D(resolution, resolution, TextureFormat.RGB24, false);
                image.ReadPixels(new Rect(0, 0, resolution, resolution), 0, 0);
                image.Apply(); File.WriteAllBytes(path, image.EncodeToPNG());
            }
            finally
            {
                RenderTexture.active = previous;
                rt.Release(); Object.DestroyImmediate(rt);
                if (image != null) Object.DestroyImmediate(image);
            }
        }
    }
}

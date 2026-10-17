using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;
using Object = UnityEngine.Object;

namespace Aaris.World.Editor
{
    public static class PhysicsSandboxCompiler
    {
        public const string Source = "Assets/GameData/World/sandbox.json";
        public const string ScenePath = UnityWorldCompiler.Generated + "/PhysicsSandbox.unity";
        public static SandboxSpec Read() => JsonUtility.FromJson<SandboxSpec>(File.ReadAllText(Source));

        [MenuItem("Aaris/Gameplay/Compile Physics Sandbox (No APK)")]
        public static void Compile()
        {
            if (EditorApplication.isPlayingOrWillChangePlaymode) throw new InvalidOperationException("Stop Play Mode before compiling a sandbox scene.");
            var spec = Read(); var world = UnityWorldCompiler.ReadWorld(); var registry = UnityWorldCompiler.ReadRegistry();
            var errors = SandboxValidator.Validate(spec, world, registry);
            if (errors.Count != 0) throw new InvalidDataException(string.Join("\n", errors));
            ConfigureLayers();
            UnityWorldCompiler.Compile();
            var scene = SceneManager.GetActiveScene();
            foreach (var root in scene.GetRootGameObjects()) SandboxLayers.SetRecursively(root, SandboxLayers.World);
            var oldCamera = Camera.main; if (oldCamera != null) Object.DestroyImmediate(oldCamera.gameObject);
            var terrain = new TerrainSampler(world);
            Vector3 Feet(SpawnSpec p) => new Vector3((float)p.x, (float)terrain.Height(p.x, p.z) + 0.12f, (float)p.z);
            var neutral = Material("SandboxNeutral", new Color(0.28f, 0.37f, 0.43f));
            var playerArt = Material("SandboxPlayer", new Color(0.2f, 0.65f, 0.8f));
            var targetArt = Material("SandboxTarget", new Color(0.85f, 0.35f, 0.18f));
            var propArt = Material("SandboxCrates", new Color(0.47f, 0.33f, 0.18f));
            var playerSurface = new PhysicsMaterial("Pawn friction") { dynamicFriction = 0, staticFriction = 0, bounciness = 0, frictionCombine = PhysicsMaterialCombine.Minimum, bounceCombine = PhysicsMaterialCombine.Minimum };
            var propSurface = new PhysicsMaterial("Prop friction") { dynamicFriction = 0.5f, staticFriction = 0.65f, bounciness = 0.05f, frictionCombine = PhysicsMaterialCombine.Average, bounceCombine = PhysicsMaterialCombine.Minimum };
            AssetDatabase.CreateAsset(playerSurface, UnityWorldCompiler.Generated + "/Materials/PawnPhysics.asset");
            AssetDatabase.CreateAsset(propSurface, UnityWorldCompiler.Generated + "/Materials/PropPhysics.asset");
            var rootObject = new GameObject("Local Physics Session");
            var session = rootObject.AddComponent<SandboxSession>(); session.settings = spec;
            var input = rootObject.AddComponent<SandboxInput>(); session.input = input;
            var player = new GameObject(spec.player.id); player.transform.position = Feet(spec.player);
            var pawn = player.AddComponent<PhysicsPawn>(); pawn.settings = spec.movement; pawn.Configure(); pawn.input = input;
            float height = (float)spec.movement.height, radius = (float)spec.movement.radius, barrelHeight = height * 0.75f;
            player.GetComponent<CapsuleCollider>().sharedMaterial = playerSurface;
            var visual = new GameObject("Development character").transform; visual.SetParent(player.transform, false); pawn.visual = visual;
            visual.localRotation = Quaternion.Euler(0, (float)spec.player.yaw, 0);
            Part(visual, PrimitiveType.Capsule, Vector3.up * (height * 0.5f), new Vector3(radius * 1.7f, height * 0.5f, radius * 1.7f), playerArt, false);
            var gun = Part(visual, PrimitiveType.Cube, new Vector3(radius * 0.57f, barrelHeight - 0.05f, 0.32f), new Vector3(0.12f, 0.14f, 0.65f), neutral, false);
            gun.name = "Development rifle";
            var muzzle = new GameObject("Muzzle").transform; muzzle.SetParent(visual, false); muzzle.localPosition = new Vector3(radius * 0.57f, barrelHeight, 0.66f);
            SandboxLayers.SetRecursively(player, SandboxLayers.Player);
            var cameraObject = new GameObject("Third Person Camera"); cameraObject.tag = "MainCamera";
            var camera = cameraObject.AddComponent<Camera>(); camera.nearClipPlane = 0.03f; camera.farClipPlane = 1400; camera.fieldOfView = 65;
            cameraObject.transform.SetPositionAndRotation(player.transform.position + Quaternion.Euler(12, (float)spec.player.yaw, 0) * new Vector3(0.6f, 1.5f, -3.7f), Quaternion.Euler(12, (float)spec.player.yaw, 0));
            var rig = cameraObject.AddComponent<ThirdPersonRig>(); rig.target = player.transform; rig.input = input; rig.initialYaw = (float)spec.player.yaw; rig.pivotHeight = height * 0.83f; rig.ResetView(); pawn.cameraRig = rig;
            var weapon = player.AddComponent<PhysicsWeapon>(); weapon.settings = spec.weapon; weapon.input = input; weapon.cameraRig = rig; weapon.muzzle = muzzle; weapon.barrelHeight = barrelHeight; weapon.ResetWeapon();
            var trace = new GameObject("Shot tracer").AddComponent<LineRenderer>(); trace.transform.SetParent(player.transform, false);
            trace.positionCount = 2; trace.useWorldSpace = true; trace.widthMultiplier = 0.018f; trace.enabled = false;
            var shader = Shader.Find("Universal Render Pipeline/Unlit"); if (shader == null) throw new InvalidOperationException("Missing URP Unlit shader.");
            var tracerMaterial = new Material(shader); tracerMaterial.SetColor("_BaseColor", new Color(1, 0.85f, 0.4f));
            AssetDatabase.CreateAsset(tracerMaterial, UnityWorldCompiler.Generated + "/Materials/Tracer.asset"); trace.sharedMaterial = tracerMaterial; weapon.tracer = trace;
            var props = new List<Rigidbody>();
            foreach (var p in spec.props)
            {
                var go = Part(null, PrimitiveType.Cube, Feet(p) + Vector3.up * (float)(p.sizeY * 0.5 + p.dropHeight), new Vector3((float)p.sizeX, (float)p.sizeY, (float)p.sizeZ), propArt, true);
                go.name = p.id; go.transform.rotation = Quaternion.Euler(0, (float)p.yaw, 0); go.GetComponent<Collider>().sharedMaterial = propSurface;
                var body = go.AddComponent<Rigidbody>(); body.mass = (float)p.mass; body.interpolation = RigidbodyInterpolation.Interpolate;
                body.collisionDetectionMode = CollisionDetectionMode.ContinuousDynamic; body.solverIterations = 8; body.solverVelocityIterations = 2;
                body.linearDamping = 0.02f; body.angularDamping = 0.1f; body.maxDepenetrationVelocity = 4; body.maxLinearVelocity = 50;
                SandboxLayers.SetRecursively(go, SandboxLayers.Prop); props.Add(body);
            }
            var targets = new List<Damageable>();
            foreach (var t in spec.targets)
            {
                var go = new GameObject(t.id); go.transform.SetPositionAndRotation(Feet(t), Quaternion.Euler(0, (float)t.yaw, 0));
                var receiver = go.AddComponent<Damageable>();
                var torso = Part(go.transform, PrimitiveType.Capsule, new Vector3(0, 0.75f, 0), new Vector3(0.6f, 0.75f, 0.6f), targetArt, true);
                var head = Part(go.transform, PrimitiveType.Sphere, new Vector3(0, 1.68f, 0), Vector3.one * 0.44f, targetArt, true);
                var bodyRegion = torso.AddComponent<HitRegion>(); bodyRegion.receiver = receiver;
                var headRegion = head.AddComponent<HitRegion>(); headRegion.receiver = receiver; headRegion.head = true;
                receiver.ResetHealth(); SandboxLayers.SetRecursively(go, SandboxLayers.Target); targets.Add(receiver);
            }
            session.pawn = pawn; session.weapon = weapon; session.cameraRig = rig; session.targets = targets.ToArray(); session.props = props.ToArray();
            session.playerStart = player.transform.position; session.propStarts = props.Select(p => p.position).ToArray(); session.propRotations = props.Select(p => p.rotation).ToArray();
            session.worldMin = new Vector2((float)world.grid.originX, (float)world.grid.originZ);
            session.worldMax = session.worldMin + new Vector2((float)world.grid.sizeX, (float)world.grid.sizeZ);
            if (spec.zone != null && spec.zone.enabled)
            {
                var zoneObject = new GameObject("Battle Zone Boundary");
                zoneObject.transform.SetParent(rootObject.transform, false);
                var ring = zoneObject.AddComponent<LineRenderer>();
                ring.positionCount = 96; ring.loop = true; ring.useWorldSpace = true;
                ring.widthMultiplier = 1.7f;
                ring.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
                ring.receiveShadows = false;
                var ringMaterial = new Material(shader);
                ringMaterial.SetColor("_BaseColor", new Color(0.2f, 0.85f, 1f));
                AssetDatabase.CreateAsset(ringMaterial, UnityWorldCompiler.Generated + "/Materials/BattleZone.asset");
                ring.sharedMaterial = ringMaterial;
                session.zoneLine = ring;
            }
            rootObject.AddComponent<SandboxHud>().session = session;
            AssetDatabase.SaveAssets();
            if (!EditorSceneManager.SaveScene(scene, ScenePath)) throw new IOException("Unable to save physics sandbox scene.");
            Debug.Log("Physics sandbox authored: native Rigidbody capsule, bounded props, touch controls and local target shooting. No APK compiled; run Unity physics tests and Play Mode before acceptance.");
        }

        private static GameObject Part(Transform parent, PrimitiveType primitive, Vector3 position, Vector3 scale, Material material, bool collision)
        {
            var go = GameObject.CreatePrimitive(primitive); if (parent != null) go.transform.SetParent(parent, false);
            go.transform.localPosition = position; go.transform.localScale = scale; go.GetComponent<Renderer>().sharedMaterial = material;
            if (!collision) Object.DestroyImmediate(go.GetComponent<Collider>()); return go;
        }
        private static Material Material(string name, Color color)
        {
            var shader = Shader.Find("Universal Render Pipeline/Lit"); if (shader == null) throw new InvalidOperationException("Missing URP Lit shader.");
            var material = new Material(shader) { name = name }; material.SetColor("_BaseColor", color); material.SetFloat("_Smoothness", 0.25f);
            AssetDatabase.CreateAsset(material, UnityWorldCompiler.Generated + "/Materials/" + name + ".asset"); return material;
        }
        private static void ConfigureLayers()
        {
            var tags = new SerializedObject(AssetDatabase.LoadAllAssetsAtPath("ProjectSettings/TagManager.asset")[0]);
            var layers = tags.FindProperty("layers");
            var names = new[] { "AarisWorld", "AarisProp", "AarisPlayer", "AarisTarget" };
            for (int i = 0; i < names.Length; i++)
            {
                var slot = layers.GetArrayElementAtIndex(8 + i);
                if (!string.IsNullOrEmpty(slot.stringValue) && slot.stringValue != names[i]) throw new InvalidOperationException("Layer " + (8 + i) + " is already used; resolve the layer contract explicitly.");
                slot.stringValue = names[i];
            }
            tags.ApplyModifiedPropertiesWithoutUndo();
        }
    }
}

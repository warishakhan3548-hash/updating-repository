using System;
using UnityEngine;
using Object = UnityEngine.Object;

namespace Aaris.World.Editor
{
    // Finite original development art made from shared Unity primitive meshes.
    // No downloaded/licensed character likeness, runtime mesh generation or render-time allocation.
    public static class CharacterArtBuilder
    {
        public static CharacterPresentation Build(Transform parent, float height, Material cloth, Material armour, Material dark, Material skin, Material accent)
        {
            if (parent == null || !WorldValidator.Finite(height) || height < 0.5f || height > 3 ||
                cloth == null || armour == null || dark == null || skin == null || accent == null)
                throw new ArgumentException("A parent, bounded height and five shared development-art materials are required.");
            var root = Joint(parent, "Original ranger - development art", Vector3.zero);
            var pose = root.gameObject.AddComponent<CharacterPresentation>(); pose.height = height;
            pose.pawn = parent.GetComponent<PhysicsPawn>();
            pose.hips = Joint(root, "Hips", Vector3.up * height * 0.52f);
            Part(pose.hips, "Trousers", PrimitiveType.Cube, Vector3.zero, new Vector3(0.26f, 0.105f, 0.16f) * height, cloth);
            Part(pose.hips, "Belt", PrimitiveType.Cube, Vector3.up * height * 0.045f, new Vector3(0.27f, 0.035f, 0.17f) * height, dark);
            pose.chest = Joint(root, "Chest", Vector3.up * height * 0.61f);
            Part(pose.chest, "Jacket", PrimitiveType.Capsule, Vector3.up * height * 0.025f, new Vector3(0.29f, 0.145f, 0.18f) * height, cloth);
            Part(pose.chest, "Plate carrier", PrimitiveType.Cube, new Vector3(0, 0.035f, 0.071f) * height, new Vector3(0.245f, 0.225f, 0.07f) * height, armour);
            Part(pose.chest, "Backpack", PrimitiveType.Cube, new Vector3(0, 0.025f, -0.118f) * height, new Vector3(0.22f, 0.24f, 0.11f) * height, dark);
            Part(pose.chest, "Pack panel", PrimitiveType.Cube, new Vector3(0, 0.035f, -0.177f) * height, new Vector3(0.17f, 0.15f, 0.02f) * height, armour);
            for (int side = -1; side <= 1; side += 2)
            {
                Part(pose.chest, "Shoulder webbing", PrimitiveType.Cube, new Vector3(side * 0.093f, 0.105f, 0.081f) * height, new Vector3(0.035f, 0.12f, 0.028f) * height, dark);
                Part(pose.chest, "Utility pouch", PrimitiveType.Cube, new Vector3(side * 0.07f, -0.015f, 0.12f) * height, new Vector3(0.085f, 0.08f, 0.035f) * height, armour);
            }
            Part(pose.chest, "Ranger marker", PrimitiveType.Cube, new Vector3(0, 0.105f, 0.109f) * height, new Vector3(0.065f, 0.018f, 0.008f) * height, accent);
            Part(pose.chest, "Neck", PrimitiveType.Capsule, new Vector3(0, 0.168f, 0) * height, new Vector3(0.07f, 0.06f, 0.07f) * height, skin);
            pose.head = Joint(pose.chest, "Head", Vector3.up * height * 0.265f);
            Part(pose.head, "Face", PrimitiveType.Sphere, Vector3.zero, new Vector3(0.145f, 0.18f, 0.15f) * height, skin);
            Part(pose.head, "Helmet", PrimitiveType.Sphere, Vector3.up * height * 0.06f, new Vector3(0.17f, 0.13f, 0.18f) * height, armour);
            Part(pose.head, "Visor", PrimitiveType.Cube, new Vector3(0, 0.018f, 0.074f) * height, new Vector3(0.125f, 0.048f, 0.026f) * height, dark);
            Part(pose.head, "Helmet band", PrimitiveType.Cube, new Vector3(0, 0.065f, 0.089f) * height, new Vector3(0.055f, 0.018f, 0.012f) * height, accent);
            BuildLeg(pose.hips, height, -1, cloth, armour, dark, out pose.leftThigh, out pose.leftShin, out pose.leftFoot);
            BuildLeg(pose.hips, height, 1, cloth, armour, dark, out pose.rightThigh, out pose.rightShin, out pose.rightFoot);
            BuildArm(pose.chest, height, -1, cloth, dark, out pose.leftArm, out pose.leftForearm);
            BuildArm(pose.chest, height, 1, cloth, dark, out pose.rightArm, out pose.rightForearm);
            pose.rifle = Joint(pose.chest, "Original practice rifle", new Vector3(0.09f, 0.14f, 0.12f) * height);
            Part(pose.rifle, "Receiver", PrimitiveType.Cube, Vector3.zero, new Vector3(0.045f, 0.06f, 0.22f) * height, dark);
            Part(pose.rifle, "Stock", PrimitiveType.Cube, new Vector3(0, 0, -0.153f) * height, new Vector3(0.04f, 0.07f, 0.10f) * height, armour);
            Part(pose.rifle, "Handguard", PrimitiveType.Cube, new Vector3(0, 0, 0.14f) * height, new Vector3(0.045f, 0.05f, 0.11f) * height, armour);
            var barrel = Part(pose.rifle, "Barrel", PrimitiveType.Cylinder, new Vector3(0, 0.01f, 0.2475f) * height, new Vector3(0.018f, 0.0525f, 0.018f) * height, dark);
            barrel.localRotation = Quaternion.Euler(90, 0, 0);
            var magazine = Part(pose.rifle, "Magazine", PrimitiveType.Cube, new Vector3(0, -0.065f, 0.005f) * height, new Vector3(0.035f, 0.10f, 0.055f) * height, dark);
            magazine.localRotation = Quaternion.Euler(-12, 0, 0);
            Part(pose.rifle, "Sight", PrimitiveType.Cube, new Vector3(0, 0.045f, 0.025f) * height, new Vector3(0.032f, 0.035f, 0.065f) * height, dark);
            pose.muzzle = Joint(pose.rifle, "Muzzle", new Vector3(0, 0.01f, 0.301f) * height);
            pose.leftGrip = Joint(pose.rifle, "Support grip", new Vector3(-0.025f, -0.018f, 0.105f) * height);
            pose.rightGrip = Joint(pose.rifle, "Trigger grip", new Vector3(0, -0.04f, -0.04f) * height);
            pose.UpdatePose(0, Vector3.zero, true, false, false, 0);
            return pose;
        }

        private static void BuildLeg(Transform hips, float height, int side, Material cloth, Material armour, Material dark, out Transform thigh, out Transform shin, out Transform foot)
        {
            string label = side < 0 ? "Left" : "Right";
            thigh = Joint(hips, label + " thigh", Vector3.right * side * height * 0.079f);
            Part(thigh, "Trouser leg", PrimitiveType.Capsule, Vector3.down * height * 0.1225f, new Vector3(0.135f, 0.1225f, 0.145f) * height, cloth);
            shin = Joint(thigh, label + " knee", Vector3.down * height * 0.245f);
            Part(shin, "Shin", PrimitiveType.Capsule, Vector3.down * height * 0.1225f, new Vector3(0.10f, 0.1225f, 0.11f) * height, cloth);
            Part(shin, "Knee pad", PrimitiveType.Cube, new Vector3(0, -0.015f, 0.058f) * height, new Vector3(0.09f, 0.09f, 0.04f) * height, armour);
            foot = Joint(shin, label + " ankle", Vector3.down * height * 0.245f);
            Part(foot, "Boot", PrimitiveType.Cube, new Vector3(0, -0.01f, 0.035f) * height, new Vector3(0.105f, 0.09f, 0.19f) * height, dark);
        }

        private static void BuildArm(Transform chest, float height, int side, Material cloth, Material dark, out Transform arm, out Transform forearm)
        {
            string label = side < 0 ? "Left" : "Right";
            arm = Joint(chest, label + " shoulder", new Vector3(side * 0.16f, 0.14f, 0) * height);
            Part(arm, "Sleeve", PrimitiveType.Capsule, Vector3.down * height * 0.085f, new Vector3(0.095f, 0.085f, 0.10f) * height, cloth);
            forearm = Joint(arm, label + " elbow", Vector3.down * height * 0.17f);
            Part(forearm, "Forearm", PrimitiveType.Capsule, Vector3.down * height * 0.08f, new Vector3(0.075f, 0.08f, 0.08f) * height, cloth);
            Part(forearm, "Glove", PrimitiveType.Sphere, Vector3.down * height * 0.16f, new Vector3(0.065f, 0.08f, 0.075f) * height, dark);
        }

        private static Transform Joint(Transform parent, string name, Vector3 localPosition)
        {
            var joint = new GameObject(name).transform;
            joint.SetParent(parent, false); joint.localPosition = localPosition; return joint;
        }

        private static Transform Part(Transform parent, string name, PrimitiveType primitive, Vector3 localPosition, Vector3 scale, Material material)
        {
            var part = GameObject.CreatePrimitive(primitive);
            part.name = name; part.transform.SetParent(parent, false);
            part.transform.localPosition = localPosition; part.transform.localScale = scale;
            part.GetComponent<Renderer>().sharedMaterial = material;
            Object.DestroyImmediate(part.GetComponent<Collider>());
            return part.transform;
        }
    }
}

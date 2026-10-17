using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using Aaris.World;

namespace Aaris.Tools;

public static class WorldFiles
{
    public const string WorldPath = "Assets/GameData/World/world.json";
    public const string RegistryPath = "Assets/GameData/World/assets.json";
    public static readonly JsonSerializerOptions Json = new()
    {
        IncludeFields = true,
        WriteIndented = true,
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    public static T Read<T>(string path)
    {
        string text = File.ReadAllText(path);
        // Json parsers normally accept repeated keys with last-value-wins. Reject ambiguity.
        using var document = JsonDocument.Parse(text);
        CheckKeys(document.RootElement);
        return JsonSerializer.Deserialize<T>(text, Json) ?? throw new InvalidDataException("Empty document: " + path);
    }

    private static void CheckKeys(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            var keys = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in element.EnumerateObject())
            {
                if (!keys.Add(property.Name)) throw new InvalidDataException("Duplicate JSON key: " + property.Name);
                CheckKeys(property.Value);
            }
        }
        else if (element.ValueKind == JsonValueKind.Array)
            foreach (var child in element.EnumerateArray()) CheckKeys(child);
    }

    public static string Serialize<T>(T value) => JsonSerializer.Serialize(value, Json) + "\n";
    public static string Fingerprint(string worldPath = WorldPath, string registryPath = RegistryPath)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        foreach (string path in new[] { worldPath, registryPath })
        {
            byte[] bytes = File.ReadAllBytes(path);
            hash.AppendData(BitConverter.GetBytes((long)bytes.Length)); hash.AppendData(bytes);
        }
        return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
    }

    public static void AtomicWrite(string path, string content)
    {
        string full = Path.GetFullPath(path);
        string temp = full + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temp, content, new System.Text.UTF8Encoding(false));
            File.Move(temp, full, true);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
}

[Serializable]
public sealed class MoveRequest
{
    public string objectId = "";
    public int expectedRevision;
    public double? x;
    public double? z;
    public double? yaw;
    // Set either markerId OR explicit x/z/yaw. Unknown markers never resolve to origin.
    public string markerId = "";
}

public static class WorldEditor
{
    public static WorldSpec Move(WorldSpec original, AssetRegistry assets, MoveRequest move)
    {
        if (move == null || move.expectedRevision != original.revision)
            throw new InvalidOperationException("Stale world revision; read current world before editing.");
        var before = WorldValidator.Validate(original, assets);
        if (before.Count != 0) throw new InvalidDataException(string.Join("\n", before));
        var copy = JsonSerializer.Deserialize<WorldSpec>(WorldFiles.Serialize(original), WorldFiles.Json);
        var target = copy.objects.SingleOrDefault(o => o.id == move.objectId)
            ?? throw new InvalidOperationException("Unknown object ID: " + move.objectId);
        if (!string.IsNullOrEmpty(move.markerId))
        {
            if (move.x.HasValue || move.z.HasValue || move.yaw.HasValue)
                throw new ArgumentException("Specify markerId or explicit x/z/yaw, not both.");
            var marker = copy.markers.SingleOrDefault(m => m.id == move.markerId)
                ?? throw new InvalidOperationException("Unknown marker ID: " + move.markerId);
            target.x = marker.x; target.z = marker.z; target.yaw = marker.yaw;
        }
        else
        {
            if (!move.x.HasValue || !move.z.HasValue || !move.yaw.HasValue)
                throw new ArgumentException("A move requires markerId or all three explicit fields: x, z, yaw.");
            target.x = move.x.Value; target.z = move.z.Value; target.yaw = move.yaw.Value;
        }
        copy.revision = checked(copy.revision + 1);
        var errors = WorldValidator.Validate(copy, assets);
        if (errors.Count != 0) throw new InvalidOperationException("Move rejected; source is unchanged:\n" + string.Join("\n", errors));
        return copy;
    }
}

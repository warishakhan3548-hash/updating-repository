using Aaris.Tools;
using Aaris.World;

try
{
    if (args.Length == 0)
        throw new ArgumentException("Commands: validate [--production], review [output-directory], move request.json [--apply], self-test. Run from repository root.");
    if (args[0] == "self-test")
    {
        if (args.Length != 1) throw new ArgumentException("self-test takes no arguments.");
        return SelfTests.Run();
    }
    var world = WorldFiles.Read<WorldSpec>(WorldFiles.WorldPath);
    var assets = WorldFiles.Read<AssetRegistry>(WorldFiles.RegistryPath);
    switch (args[0])
    {
        case "validate":
        {
            if (args.Length > 2 || (args.Length == 2 && args[1] != "--production")) throw new ArgumentException("validate [--production]");
            var errors = WorldValidator.Validate(world, assets, args.Contains("--production"));
            foreach (var error in errors) Console.Error.WriteLine(error);
            if (errors.Count != 0) return 1;
            Console.WriteLine($"VALID {world.id} r{world.revision}: {world.objects.Length} objects; no APK compiled.");
            return 0;
        }
        case "review":
        {
            if (args.Length > 2) throw new ArgumentException("review [output-directory]");
            string output = args.Length == 2 ? args[1] : "Review/latest";
            ReviewWriter.Write(world, assets, output);
            Console.WriteLine("World plan, schematic and metrics written to " + output + "; no Unity license or APK required.");
            return 0;
        }
        case "move":
        {
            if (args.Length < 2 || args.Length > 3 || (args.Length == 3 && args[2] != "--apply")) throw new ArgumentException("move request.json [--apply]");
            byte[] original = File.ReadAllBytes(WorldFiles.WorldPath);
            var move = WorldFiles.Read<MoveRequest>(args[1]);
            var edited = WorldEditor.Move(world, assets, move);
            var target = edited.objects.Single(o => o.id == move.objectId);
            Console.WriteLine($"VALID MOVE {target.id}: ({target.x}, {target.z}), yaw {target.yaw}; revision {world.revision} -> {edited.revision}");
            if (args.Contains("--apply"))
            {
                if (!original.SequenceEqual(File.ReadAllBytes(WorldFiles.WorldPath))) throw new IOException("World changed during editing; read and retry.");
                WorldFiles.AtomicWrite(WorldFiles.WorldPath, WorldFiles.Serialize(edited));
                Console.WriteLine("Applied atomically. Commit world.json to preserve the edit. No APK compiled.");
            }
            else Console.WriteLine("Dry run only. --apply writes the validated edit.");
            return 0;
        }
        default: throw new ArgumentException("Unknown command: " + args[0]);
    }
}
catch (Exception error) when (error is ArgumentException || error is InvalidOperationException || error is IOException || error is System.Text.Json.JsonException || error is OverflowException)
{
    Console.Error.WriteLine(error.Message);
    return 1;
}

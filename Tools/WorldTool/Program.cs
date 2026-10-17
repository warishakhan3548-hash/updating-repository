using Aaris.Tools;
using Aaris.World;

try
{
    if (args.Length == 0)
        throw new ArgumentException("Commands: validate [--production], validate-sandbox, review [directory], review-tactical [directory], review-visibility [directory], refine-cover request.json [directory], move request.json [--apply], plan-route request.json [directory], export-geometry [directory], prepare-highlands-v2, self-test. Run from repository root.");
    if (args[0] == "self-test")
    {
        if (args.Length != 1) throw new ArgumentException("self-test takes no arguments.");
        return SelfTests.Run();
    }
    var world = WorldFiles.Read<WorldSpec>(WorldFiles.WorldPath);
    var assets = WorldFiles.Read<AssetRegistry>(WorldFiles.RegistryPath);
    switch (args[0])
    {
        case "refine-cover":
        {
            if (args.Length < 2 || args.Length > 3) throw new ArgumentException("refine-cover request.json [directory]");
            CoverRefiner.Write(world, assets, WorldFiles.Read<CoverRefineRequest>(args[1]), args.Length == 3 ? args[2] : "Review/cover-proposal");
            return 0;
        }
        case "review-tactical":
        {
            if (args.Length > 2) throw new ArgumentException("review-tactical [directory]");
            TacticalExposureReview.Write(world, assets, args.Length == 2 ? args[1] : "Review/latest/tactical");
            return 0;
        }
        case "review-visibility":
        {
            if (args.Length > 2) throw new ArgumentException("review-visibility [directory]");
            VisibilityReview.Write(world, assets, args.Length == 2 ? args[1] : "Review/visibility");
            return 0;
        }
        case "validate-sandbox":
        {
            if (args.Length != 1) throw new ArgumentException("validate-sandbox takes no arguments.");
            var sandbox = WorldFiles.Read<SandboxSpec>("Assets/GameData/World/sandbox.json");
            var errors = SandboxValidator.Validate(sandbox, world, assets);
            foreach (var error in errors) Console.Error.WriteLine(error);
            if (errors.Count != 0) return 1;
            Console.WriteLine($"VALID sandbox r{sandbox.revision}: {sandbox.fixedHz} Hz, {sandbox.props.Length + 1} dynamic bodies, {sandbox.targets.Length} targets. Native physics is tested separately in Unity; no APK compiled.");
            return 0;
        }
        case "plan-route":
        {
            if (args.Length < 2 || args.Length > 3) throw new ArgumentException("plan-route request.json [directory]");
            RouteCommand.Write(world, assets, WorldFiles.Read<RouteRequest>(args[1]), args.Length == 3 ? args[2] : "Review/route");
            return 0;
        }
        case "export-geometry":
        {
            if (args.Length > 2) throw new ArgumentException("export-geometry [directory]");
            GeometryExporter.Write(world, assets, args.Length == 2 ? args[1] : "Review/geometry");
            return 0;
        }
        case "prepare-highlands-v2":
        {
            if (args.Length != 1) throw new ArgumentException("prepare-highlands-v2 takes no arguments and only writes a proposal.");
            var proposal = HighlandsRecipe.Create(world);
            Directory.CreateDirectory("Review/proposal");
            File.WriteAllText("Review/proposal/world.json", WorldFiles.Serialize(proposal.world));
            File.WriteAllText("Review/proposal/assets.json", WorldFiles.Serialize(proposal.assets));
            Console.WriteLine("Validated v2 proposal saved. Current source was not rewritten. Review and promote both JSON files together.");
            return 0;
        }
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

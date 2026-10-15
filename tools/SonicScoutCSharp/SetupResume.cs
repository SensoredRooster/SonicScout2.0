using System.IO;
using System.Text.Json;

namespace SonicScout;

/// <summary>Persists the SETUP choices needed to auto-resume after the driver-install reboot.</summary>
public static class SetupResume
{
    public const string CommandLineFlag = "--resume-setup";

    public static string StatePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SonicScout", "setup-resume.json");

    public static void SaveSelectedOutput(string displayName)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(StatePath)!);
            File.WriteAllText(StatePath, JsonSerializer.Serialize(new { selectedOutput = displayName }));
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    public static string? LoadSelectedOutput()
    {
        try
        {
            if (!File.Exists(StatePath)) return null;
            using JsonDocument doc = JsonDocument.Parse(File.ReadAllText(StatePath));
            return doc.RootElement.TryGetProperty("selectedOutput", out JsonElement v) ? v.GetString() : null;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException) { return null; }
    }
}

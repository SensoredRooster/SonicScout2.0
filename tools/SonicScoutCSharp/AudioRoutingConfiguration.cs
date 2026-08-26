using System.IO;
using System.Text.Json;

namespace SonicScout;

public sealed class SonicRoutingConfiguration
{
    public string SonicScoutAlias { get; set; } = "Sonic Scout";
    public string SetupStyle { get; set; } = "Sonic Scout Direct Route";
    public string? SelectedPhysicalOutputId { get; set; }
    public string? SelectedPhysicalOutputName { get; set; }
    public string? SonicScoutEndpointId { get; set; }
    public string? SonicScoutEndpointName { get; set; }
    public bool SonicScoutProvisioned { get; set; }
    public bool SonicScoutEngaged { get; set; }
    public bool UseVoicemeeterCompatibility { get; set; }
    public bool UseWaveLinkCompatibility { get; set; }
    public bool UseSoundBlasterCompatibility { get; set; }
    public bool UseOtherMixerCompatibility { get; set; }
    public string? ActiveOutputDeviceId { get; set; }
    public string? ActiveOutputDeviceName { get; set; }
    public string? LastRoutingNote { get; set; }
    public bool PostInstallVerified { get; set; }
    public DateTime? PostInstallVerifiedUtc { get; set; }
    public DateTime LastUpdatedUtc { get; set; } = DateTime.UtcNow;

    public bool HasCompatibilityMixer =>
        UseVoicemeeterCompatibility ||
        UseWaveLinkCompatibility ||
        UseSoundBlasterCompatibility ||
        UseOtherMixerCompatibility;
}

internal static class SonicRoutingConfigurationStore
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = true
    };

    public static SonicRoutingConfiguration Load(string configurationPath)
    {
        if (!File.Exists(configurationPath))
        {
            return new SonicRoutingConfiguration();
        }

        try
        {
            string json = File.ReadAllText(configurationPath);
            SonicRoutingConfiguration? configuration = JsonSerializer.Deserialize<SonicRoutingConfiguration>(json, SerializerOptions);
            return configuration ?? new SonicRoutingConfiguration();
        }
        catch (JsonException)
        {
            return new SonicRoutingConfiguration();
        }
        catch (IOException)
        {
            return new SonicRoutingConfiguration();
        }
        catch (UnauthorizedAccessException)
        {
            return new SonicRoutingConfiguration();
        }
    }

    public static bool Save(string configurationPath, SonicRoutingConfiguration configuration)
    {
        try
        {
            string? folderPath = Path.GetDirectoryName(configurationPath);
            if (!string.IsNullOrWhiteSpace(folderPath))
            {
                Directory.CreateDirectory(folderPath);
            }

            configuration.LastUpdatedUtc = DateTime.UtcNow;
            string json = JsonSerializer.Serialize(configuration, SerializerOptions);
            File.WriteAllText(configurationPath, json);
            return true;
        }
        catch (IOException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }
}

using System.IO;
using Microsoft.Win32;
using Path = System.IO.Path;

namespace SonicScout;

/// <summary>
/// Raw facts about the Equalizer APO installation. Gathered by <see cref="EapoInstallation.Probe"/>
/// and evaluated by pure functions so they can be unit tested without a registry.
/// </summary>
public sealed record EapoInstallationFacts(
    bool RegistryKeyPresent,
    string InstallPath,
    bool EditorPresent,
    bool ConfiguratorPresent,
    bool PreMixClsidRegistered,
    bool PostMixClsidRegistered);

public enum EqRuntimeStatus
{
    NotInstalled,
    SetupRequired,
    NoAudio,
    Running
}

public static class EapoInstallation
{
    // The APO classes setup actually binds to endpoints (apo_automation.ps1 / LEQ-Engine.ps1).
    // NOTE: {C18E2F7E-933D-4965-B7D1-1EEF228D2AF3} is AUDIO_SIGNALPROCESSINGMODE_DEFAULT, a
    // processing-mode GUID, not a COM class, so it is never a valid "APO registered" check.
    public const string PreMixClsid = "{EACD2258-FCAC-4FF4-B36D-419E924A6D79}";
    public const string PostMixClsid = "{EC1CC9CE-FAED-4822-828A-82A81A6F018F}";
    public const string RegistryKeyPath = @"SOFTWARE\EqualizerAPO";

    /// <summary>User-writable file that runtime EQ writes go to. config.txt includes it (added once by setup).</summary>
    public static string UserIncludePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "SonicScout", "eapo", "sonicscout.txt");

    public static EapoInstallationFacts Probe()
    {
        bool keyPresent = false;
        string installPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "EqualizerAPO");
        bool pre = false, post = false;
        try
        {
            using RegistryKey hklm = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
            using RegistryKey? key = hklm.OpenSubKey(RegistryKeyPath);
            keyPresent = key is not null;
            if (key?.GetValue("InstallPath") is string registered && !string.IsNullOrWhiteSpace(registered))
                installPath = registered.Trim().Trim('"');

            using RegistryKey hkcr = RegistryKey.OpenBaseKey(RegistryHive.ClassesRoot, RegistryView.Registry64);
            pre = IsClsidRegistered(hkcr, PreMixClsid);
            post = IsClsidRegistered(hkcr, PostMixClsid);
        }
        catch (Exception exception) when (exception is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            // Treated as "not verified" below; never assume installed.
        }

        return new EapoInstallationFacts(
            keyPresent,
            installPath,
            File.Exists(Path.Combine(installPath, "Editor.exe")),
            // Equalizer APO 1.3+ renamed Configurator.exe to DeviceSelector.exe.
            File.Exists(Path.Combine(installPath, "Configurator.exe")) || File.Exists(Path.Combine(installPath, "DeviceSelector.exe")),
            pre,
            post);
    }

    private static bool IsClsidRegistered(RegistryKey classesRoot, string clsid)
    {
        using RegistryKey? server = classesRoot.OpenSubKey($@"CLSID\{clsid}\InprocServer32");
        if (server?.GetValue(string.Empty) is not string dll) return false;
        return Path.GetFileName(dll.Trim().Trim('"')).Equals("EqualizerAPO.dll", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Every reason the installation is not verified; empty means verified.</summary>
    public static IReadOnlyList<string> GetProblems(EapoInstallationFacts facts)
    {
        List<string> problems = new();
        if (!facts.RegistryKeyPresent) problems.Add(@"HKLM\SOFTWARE\EqualizerAPO is missing (Equalizer APO is not installed).");
        if (!facts.EditorPresent) problems.Add($"Editor.exe was not found in {facts.InstallPath}.");
        if (!facts.ConfiguratorPresent) problems.Add($"Neither DeviceSelector.exe nor Configurator.exe was found in {facts.InstallPath}.");
        if (!facts.PreMixClsidRegistered || !facts.PostMixClsidRegistered)
            problems.Add($"The Equalizer APO COM classes ({PreMixClsid} / {PostMixClsid}) are not registered to EqualizerAPO.dll under HKCR\\CLSID.");
        return problems;
    }

    public static bool IsVerified(EapoInstallationFacts facts) => GetProblems(facts).Count == 0;

    public static string BuildIncludeLine(string path) => $"Include: {path}";

    /// <summary>True when config.txt has an Include: line pointing at <paramref name="userIncludePath"/>.</summary>
    public static bool ConfigIncludesUserFile(IEnumerable<string> configLines, string userIncludePath)
    {
        string target = Path.GetFullPath(userIncludePath);
        foreach (string raw in configLines)
        {
            string line = raw.Trim();
            if (!line.StartsWith("Include:", StringComparison.OrdinalIgnoreCase)) continue;
            string value = line["Include:".Length..].Trim().Trim('"');
            if (value.Length == 0 || !Path.IsPathRooted(value)) continue;
            if (string.Equals(Path.GetFullPath(value), target, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    public static EqRuntimeStatus EvaluateStatus(bool apoVerified, bool linked, bool audioArriving) =>
        !apoVerified ? EqRuntimeStatus.NotInstalled
        : !linked ? EqRuntimeStatus.SetupRequired
        : !audioArriving ? EqRuntimeStatus.NoAudio
        : EqRuntimeStatus.Running;

    public static (string Label, string Guidance) Describe(EqRuntimeStatus status) => status switch
    {
        EqRuntimeStatus.NotInstalled => ("NOT INSTALLED", "Equalizer APO is not installed or not registered. Run SETUP (as administrator) to install it."),
        EqRuntimeStatus.SetupRequired => ("SETUP REQUIRED", "Equalizer APO is installed but config.txt does not include Sonic Scout's EQ file. Run SETUP once to add it."),
        EqRuntimeStatus.NoAudio => ("NO AUDIO", "Equalizer APO is installed, but no audio is arriving on the selected device. Play audio, or pick the device you actually hear sound from."),
        _ => ("RUNNING", "Equalizer APO is active and audio is arriving on the selected device.")
    };
}

/// <summary>Exponential backoff for re-acquiring the audio meter after a device change.</summary>
public sealed class MeterBackoff
{
    private readonly TimeSpan initial;
    private readonly TimeSpan max;
    public int Failures { get; private set; }
    public DateTime RetryAtUtc { get; private set; } = DateTime.MinValue;

    public MeterBackoff(TimeSpan? initial = null, TimeSpan? max = null)
    {
        this.initial = initial ?? TimeSpan.FromMilliseconds(250);
        this.max = max ?? TimeSpan.FromSeconds(8);
    }

    public bool CanAttempt(DateTime nowUtc) => nowUtc >= RetryAtUtc;

    public TimeSpan RecordFailure(DateTime nowUtc)
    {
        Failures++;
        double ms = Math.Min(max.TotalMilliseconds, initial.TotalMilliseconds * Math.Pow(2, Math.Min(Failures - 1, 16)));
        TimeSpan delay = TimeSpan.FromMilliseconds(ms);
        RetryAtUtc = nowUtc + delay;
        return delay;
    }

    public void RecordSuccess()
    {
        Failures = 0;
        RetryAtUtc = DateTime.MinValue;
    }
}

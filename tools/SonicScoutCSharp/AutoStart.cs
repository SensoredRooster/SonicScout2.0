using System.IO;
using System.Text.Json;
using Microsoft.Win32;

namespace SonicScout;

/// <summary>
/// Per-user "start with Windows": HKCU\...\Run\SonicScout = "&lt;exe&gt;" --autostart, so SonicPass
/// comes back after a reboot. On by default; the tray menu toggles it. The app (re)writes or removes
/// the value on every start, and the uninstaller removes it.
/// </summary>
public static class AutoStart
{
    public const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public const string RunOnceKeyPath = @"Software\Microsoft\Windows\CurrentVersion\RunOnce";
    public const string ValueName = "SonicScout";
    public const string ResumeValueName = "SonicScoutResumeSetup";
    public const string Flag = "--autostart";

    public static string SettingsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SonicScout", "settings.json");

    public static bool IsAutoStartLaunch(IEnumerable<string> args) =>
        args.Any(a => string.Equals(a, Flag, StringComparison.OrdinalIgnoreCase));

    public static string BuildCommand(string exePath) => $"\"{exePath}\" {Flag}";

    /// <summary>Reads the setting; missing or unreadable file means enabled (the default).</summary>
    public static bool LoadEnabled(string? path = null)
    {
        try
        {
            path ??= SettingsPath;
            if (!File.Exists(path)) return true;
            using JsonDocument doc = JsonDocument.Parse(File.ReadAllText(path));
            return !doc.RootElement.TryGetProperty("startWithWindows", out JsonElement v) || v.ValueKind != JsonValueKind.False;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { return true; }
    }

    public static void SaveEnabled(bool enabled, string? path = null)
    {
        path ??= SettingsPath;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, JsonSerializer.Serialize(new { startWithWindows = enabled }));
    }

    /// <summary>Makes the Run value match the setting. Returns true when the key was changed.</summary>
    public static bool Apply(RegistryKey runKey, bool enabled, string exePath)
    {
        string desired = BuildCommand(exePath);
        string? current = runKey.GetValue(ValueName) as string;
        if (enabled)
        {
            if (string.Equals(current, desired, StringComparison.OrdinalIgnoreCase)) return false;
            runKey.SetValue(ValueName, desired, RegistryValueKind.String);
            return true;
        }
        if (current is null) return false;
        runKey.DeleteValue(ValueName, throwOnMissingValue: false);
        return true;
    }

    /// <summary>Applies to HKCU for the running executable. Never throws.</summary>
    public static bool ApplyForCurrentUser(bool enabled)
    {
        try
        {
            string? exe = Environment.ProcessPath;
            if (string.IsNullOrEmpty(exe) || !exe.EndsWith("SonicScout.exe", StringComparison.OrdinalIgnoreCase)) return false;
            using RegistryKey key = Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true);
            Apply(key, enabled, exe);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException) { return false; }
    }

    /// <summary>True while a post-driver-reboot SETUP resume is still queued for this sign-in.</summary>
    public static bool ResumePending()
    {
        try
        {
            using RegistryKey? key = Registry.CurrentUser.OpenSubKey(RunOnceKeyPath);
            return key?.GetValue(ResumeValueName) is string;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException) { return false; }
    }
}

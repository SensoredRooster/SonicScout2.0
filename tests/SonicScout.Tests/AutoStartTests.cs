using Microsoft.Win32;
using SonicScout;
using Xunit;

namespace SonicScout.Tests;

public class AutoStartTests
{
    [Fact]
    public void CommandQuotesPathAndCarriesFlag()
    {
        string cmd = AutoStart.BuildCommand(@"C:\Program Files\SonicScout\SonicScout.exe");
        Assert.Equal("\"C:\\Program Files\\SonicScout\\SonicScout.exe\" --autostart", cmd);
        Assert.True(AutoStart.IsAutoStartLaunch(new[] { "--AutoStart" }));
        Assert.False(AutoStart.IsAutoStartLaunch(new[] { "--resume-setup" }));
    }

    [Fact]
    public void SettingDefaultsToEnabledAndRoundTrips()
    {
        string path = Path.Combine(Path.GetTempPath(), "ss-autostart-" + Guid.NewGuid().ToString("N"), "settings.json");
        Assert.True(AutoStart.LoadEnabled(path));          // missing file
        AutoStart.SaveEnabled(false, path);
        Assert.False(AutoStart.LoadEnabled(path));
        AutoStart.SaveEnabled(true, path);
        Assert.True(AutoStart.LoadEnabled(path));
        File.WriteAllText(path, "{not json");
        Assert.True(AutoStart.LoadEnabled(path));          // corrupt file -> default on
        Directory.Delete(Path.GetDirectoryName(path)!, true);
    }

    [Fact]
    public void ApplyWritesUpdatesAndRemovesRunValue()
    {
        string sub = @"Software\SonicScoutTests\" + Guid.NewGuid().ToString("N");
        using RegistryKey key = Registry.CurrentUser.CreateSubKey(sub, writable: true);
        try
        {
            Assert.True(AutoStart.Apply(key, true, @"C:\A\SonicScout.exe"));
            Assert.Equal("\"C:\\A\\SonicScout.exe\" --autostart", key.GetValue(AutoStart.ValueName));
            Assert.False(AutoStart.Apply(key, true, @"C:\A\SonicScout.exe"));   // idempotent
            Assert.True(AutoStart.Apply(key, true, @"C:\B\SonicScout.exe"));    // moved install
            Assert.Equal("\"C:\\B\\SonicScout.exe\" --autostart", key.GetValue(AutoStart.ValueName));
            Assert.True(AutoStart.Apply(key, false, @"C:\B\SonicScout.exe"));
            Assert.Null(key.GetValue(AutoStart.ValueName));
            Assert.False(AutoStart.Apply(key, false, @"C:\B\SonicScout.exe"));
        }
        finally { Registry.CurrentUser.DeleteSubKeyTree(sub, throwOnMissingSubKey: false); }
    }
}

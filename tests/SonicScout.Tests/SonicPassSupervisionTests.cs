using System;
using SonicScout;
using Xunit;

namespace SonicScout.Tests;

public class SonicPassSupervisionTests
{
    [Fact]
    public void RestartBacksOffThenGivesUpWithinWindow()
    {
        SonicPassRestartPolicy policy = new();
        DateTime t = new(2026, 10, 17, 8, 0, 0, DateTimeKind.Utc);
        Assert.Equal(TimeSpan.FromSeconds(1), policy.OnUnexpectedExit(t));
        Assert.Equal(TimeSpan.FromSeconds(3), policy.OnUnexpectedExit(t.AddSeconds(5)));
        Assert.Equal(TimeSpan.FromSeconds(10), policy.OnUnexpectedExit(t.AddSeconds(20)));
        Assert.Equal(TimeSpan.FromSeconds(30), policy.OnUnexpectedExit(t.AddSeconds(60)));
        Assert.Equal(TimeSpan.FromSeconds(60), policy.OnUnexpectedExit(t.AddSeconds(120)));
        Assert.Null(policy.OnUnexpectedExit(t.AddSeconds(200)));
    }

    [Fact]
    public void OldExitsAgeOutAndResetStartsOver()
    {
        SonicPassRestartPolicy policy = new();
        DateTime t = new(2026, 10, 17, 8, 0, 0, DateTimeKind.Utc);
        for (int i = 0; i < 5; i++) Assert.NotNull(policy.OnUnexpectedExit(t.AddSeconds(i)));
        Assert.Null(policy.OnUnexpectedExit(t.AddSeconds(10)));
        Assert.Equal(TimeSpan.FromSeconds(1), policy.OnUnexpectedExit(t.AddMinutes(11)));
        policy.Reset();
        Assert.Equal(0, policy.RecentExitCount);
        Assert.Equal(TimeSpan.FromSeconds(1), policy.OnUnexpectedExit(t.AddMinutes(12)));
    }

    [Theory]
    [InlineData(false, false, "Install")]
    [InlineData(true, false, "Preflight")]
    [InlineData(false, true, "Preflight")]
    [InlineData(true, true, "Preflight")]
    public void OnlyAUserInitiatedRunMayInstall(bool resumeVerifyOnly, bool automaticRun, string expected)
    {
        Assert.Equal(expected, SetupRunModePolicy.Choose(resumeVerifyOnly, automaticRun));
    }
}

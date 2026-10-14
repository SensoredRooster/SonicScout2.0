using SonicScout;
using Xunit;

public class EapoInstallationTests
{
    private static EapoInstallationFacts Full() => new(true, @"C:\Program Files\EqualizerAPO", true, true, true, true);

    [Fact]
    public void FullyRegisteredInstallIsVerified() => Assert.True(EapoInstallation.IsVerified(Full()));

    [Fact]
    public void FilePresenceAloneIsNotVerified()
    {
        var facts = Full() with { RegistryKeyPresent = false, PreMixClsidRegistered = false, PostMixClsidRegistered = false };
        var problems = EapoInstallation.GetProblems(facts);
        Assert.False(EapoInstallation.IsVerified(facts));
        Assert.Equal(2, problems.Count);
    }

    [Theory]
    [InlineData(false, true, true, true)]
    [InlineData(true, false, true, true)]
    [InlineData(true, true, false, true)]
    [InlineData(true, true, true, false)]
    public void AnyMissingPieceFailsVerification(bool key, bool editor, bool configurator, bool clsid)
    {
        var facts = new EapoInstallationFacts(key, @"C:\x", editor, configurator, clsid, clsid);
        Assert.False(EapoInstallation.IsVerified(facts));
    }

    [Fact]
    public void ConfigIncludeDetectionMatchesAbsolutePathCaseInsensitively()
    {
        string path = @"C:\Users\me\AppData\Local\SonicScout\eapo\sonicscout.txt";
        Assert.True(EapoInstallation.ConfigIncludesUserFile(new[] { "Device: all", "  include: C:\\USERS\\me\\AppData\\Local\\SonicScout\\eapo\\sonicscout.txt " }, path));
        Assert.False(EapoInstallation.ConfigIncludesUserFile(new[] { @"Include: SonicScout2.0\active-config\eq.txt", "# Include: " + path.Replace("Include", "") }, path));
    }

    [Theory]
    [InlineData(false, true, true, EqRuntimeStatus.NotInstalled)]
    [InlineData(true, false, true, EqRuntimeStatus.SetupRequired)]
    [InlineData(true, true, false, EqRuntimeStatus.NoAudio)]
    [InlineData(true, true, true, EqRuntimeStatus.Running)]
    public void StatusOnlyRunningWhenEverythingIsReal(bool apo, bool linked, bool audio, EqRuntimeStatus expected)
    {
        Assert.Equal(expected, EapoInstallation.EvaluateStatus(apo, linked, audio));
        Assert.Equal(expected == EqRuntimeStatus.Running, EapoInstallation.Describe(expected).Label == "RUNNING");
    }

    [Fact]
    public void MeterBackoffGrowsCapsAndResets()
    {
        var backoff = new MeterBackoff(TimeSpan.FromMilliseconds(100), TimeSpan.FromMilliseconds(500));
        var t0 = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        Assert.True(backoff.CanAttempt(t0));
        Assert.Equal(100, backoff.RecordFailure(t0).TotalMilliseconds);
        Assert.False(backoff.CanAttempt(t0.AddMilliseconds(50)));
        Assert.True(backoff.CanAttempt(t0.AddMilliseconds(100)));
        Assert.Equal(200, backoff.RecordFailure(t0).TotalMilliseconds);
        Assert.Equal(400, backoff.RecordFailure(t0).TotalMilliseconds);
        Assert.Equal(500, backoff.RecordFailure(t0).TotalMilliseconds);
        backoff.RecordSuccess();
        Assert.Equal(0, backoff.Failures);
        Assert.True(backoff.CanAttempt(t0));
    }
}

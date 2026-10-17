using System;
using System.Collections.Generic;

namespace SonicScout;

/// <summary>
/// Restart policy for the SonicPass audio engine. A tester must never lose audio silently:
/// when SonicPass exits without being asked to, Sonic Scout restarts it after a short delay,
/// backing off, and gives up (loudly) only after repeated crashes in a short window.
/// </summary>
public sealed class SonicPassRestartPolicy
{
    private static readonly TimeSpan[] Delays =
    {
        TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(3), TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(30), TimeSpan.FromSeconds(60)
    };

    private readonly List<DateTime> recentExits = new();

    public TimeSpan Window { get; init; } = TimeSpan.FromMinutes(10);
    public int MaxRestartsPerWindow { get; init; } = 5;

    /// <summary>Record an unexpected exit; returns the delay before restarting, or null to give up.</summary>
    public TimeSpan? OnUnexpectedExit(DateTime nowUtc)
    {
        recentExits.RemoveAll(t => nowUtc - t > Window);
        if (recentExits.Count >= MaxRestartsPerWindow) return null;
        TimeSpan delay = Delays[Math.Min(recentExits.Count, Delays.Length - 1)];
        recentExits.Add(nowUtc);
        return delay;
    }

    /// <summary>Called when the user deliberately starts SonicPass again: start over.</summary>
    public void Reset() => recentExits.Clear();

    public int RecentExitCount => recentExits.Count;
}

public static class SetupRunModePolicy
{
    /// <summary>
    /// Only an explicit user action may run the elevated Install. Automatic runs (resume after
    /// restart, a second launch, window show/restore) are verification-only, so they never raise
    /// a surprise UAC prompt or tear down the running audio route.
    /// </summary>
    public static string Choose(bool resumeVerifyOnly, bool automaticRun) =>
        resumeVerifyOnly || automaticRun ? "Preflight" : "Install";
}

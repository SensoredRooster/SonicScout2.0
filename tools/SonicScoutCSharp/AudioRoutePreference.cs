namespace SonicScout;

internal static class AudioRoutePreference
{
    // The normal route has LEQ; the +/16-channel route is an explicit alternative.
    internal static int Rank(string name)
    {
        if (name.Contains("16ch", StringComparison.OrdinalIgnoreCase) || name.Contains("SonicScout2.0 +", StringComparison.OrdinalIgnoreCase)) return 10;
        if (name.StartsWith("SonicScout2.0", StringComparison.OrdinalIgnoreCase)) return 0;
        if (name.Contains("Hi-Fi Cable Input", StringComparison.OrdinalIgnoreCase) || name.Contains("CABLE Input", StringComparison.OrdinalIgnoreCase)) return 1;
        return 5;
    }
}

using System.Globalization;
using System.IO;

namespace SonicScout;

internal static class EqProfileEdits
{
    internal const string Begin = "# SonicScout user EQ adjustments begin";
    internal const string End = "# SonicScout user EQ adjustments end";

    internal static string Adjustments(string content)
    {
        int start = content.IndexOf(Begin, StringComparison.Ordinal);
        int end = start < 0 ? -1 : content.IndexOf(End, start, StringComparison.Ordinal);
        return end < 0 ? string.Empty : content[start..end];
    }

    internal static string Apply(string content, IReadOnlyDictionary<string, double> gains, IReadOnlyList<int> frequencies)
    {
        int start = content.IndexOf(Begin, StringComparison.Ordinal);
        int end = start < 0 ? -1 : content.IndexOf(End, start, StringComparison.Ordinal);
        if (start >= 0 && end < 0) throw new InvalidDataException("The saved EQ adjustment block is incomplete.");
        if (start >= 0) content = content.Remove(start, end + End.Length - start);
        var lines = new List<string> { content.TrimEnd(), Begin };
        for (int index = 0; index < frequencies.Count; index++)
        {
            int frequency = frequencies[index];
            double gain = gains.TryGetValue(frequency.ToString(CultureInfo.InvariantCulture), out double value) ? value : 0;
            lines.Add($"Filter {1001 + index}: ON PK Fc {frequency} Hz Gain {gain.ToString("+0.0;-0.0;0.0", CultureInfo.InvariantCulture)} dB Q 1.00");
        }
        lines.Add(End);
        return string.Join(Environment.NewLine, lines) + Environment.NewLine;
    }
}

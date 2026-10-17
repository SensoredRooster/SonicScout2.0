using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Path = System.IO.Path;

namespace SonicScout;

/// <summary>One adjustable point of a user target curve.</summary>
public sealed record TargetPoint(double FrequencyHz, double GainDb);

/// <summary>
/// A named user target/EQ curve edited on the live graph and applied through Equalizer APO
/// (GraphicEQ). Pure logic so it can be unit tested without WPF or the registry.
/// </summary>
public sealed class TargetCurve
{
    public const string FileFormatId = "sonicscout-target";
    public const int FileFormatVersion = 1;
    public const double MinGainDb = -12;
    public const double MaxGainDb = 12;
    public const double MinFrequencyHz = 20;
    public const double MaxFrequencyHz = 20000;

    /// <summary>Handle frequencies shown on the graph (ISO octave centres).</summary>
    public static readonly double[] DefaultBands = { 32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 };

    private readonly double[] frequencies;
    private readonly double[] gains;

    public string Name { get; set; }
    public IReadOnlyList<double> Frequencies => frequencies;
    public IReadOnlyList<double> Gains => gains;
    public int Count => frequencies.Length;

    public TargetCurve(string name, IEnumerable<TargetPoint> points)
    {
        Name = string.IsNullOrWhiteSpace(name) ? "Custom Target" : name.Trim();
        TargetPoint[] ordered = points
            .Where(p => double.IsFinite(p.FrequencyHz) && double.IsFinite(p.GainDb) && p.FrequencyHz > 0)
            .GroupBy(p => p.FrequencyHz).Select(g => g.Last())
            .OrderBy(p => p.FrequencyHz)
            .ToArray();
        if (ordered.Length == 0) throw new FormatException("A target curve needs at least one valid frequency/gain point.");
        frequencies = ordered.Select(p => p.FrequencyHz).ToArray();
        gains = ordered.Select(p => ClampGain(p.GainDb)).ToArray();
    }

    public static TargetCurve Flat(string name = "Flat") =>
        new(name, DefaultBands.Select(f => new TargetPoint(f, 0)));

    public static double ClampGain(double db) =>
        double.IsFinite(db) ? Math.Round(Math.Clamp(db, MinGainDb, MaxGainDb), 1) : 0;

    public void SetGain(int index, double gainDb)
    {
        if ((uint)index >= (uint)gains.Length) throw new ArgumentOutOfRangeException(nameof(index));
        gains[index] = ClampGain(gainDb);
    }

    public bool IsFlat => gains.All(g => Math.Abs(g) < 0.05);

    /// <summary>Gain at any frequency, interpolated linearly on a log-frequency axis.</summary>
    public double GainAt(double frequencyHz)
    {
        if (frequencyHz <= frequencies[0]) return gains[0];
        if (frequencyHz >= frequencies[^1]) return gains[^1];
        for (int i = 1; i < frequencies.Length; i++)
        {
            if (frequencyHz <= frequencies[i])
            {
                double t = (Math.Log(frequencyHz) - Math.Log(frequencies[i - 1])) / (Math.Log(frequencies[i]) - Math.Log(frequencies[i - 1]));
                return gains[i - 1] + ((gains[i] - gains[i - 1]) * t);
            }
        }
        return gains[^1];
    }

    /// <summary>Headroom so boosts never clip: negative of the largest boost (0 when nothing is boosted).</summary>
    public double PreampDb => -Math.Max(0, gains.Max());

    public TargetCurve Clone(string? newName = null) =>
        new(newName ?? Name, frequencies.Select((f, i) => new TargetPoint(f, gains[i])));

    /// <summary>Resamples onto the graph's handle bands so imported curves stay editable.</summary>
    public TargetCurve ResampleToDefaultBands() =>
        new(Name, DefaultBands.Select(f => new TargetPoint(f, GainAt(f))));

    /// <summary>Equalizer APO configuration (Preamp + GraphicEQ) for this curve.</summary>
    public string ToApoConfig()
    {
        CultureInfo inv = CultureInfo.InvariantCulture;
        StringBuilder sb = new();
        sb.AppendLine($"# SonicScout user target: {SanitizeComment(Name)}");
        sb.AppendLine("# Written by SonicScout. Edit on the SonicScout graph; manual edits are overwritten.");
        if (IsFlat)
        {
            sb.AppendLine("# Flat target: no processing.");
            return sb.ToString();
        }
        sb.AppendLine(string.Format(inv, "Preamp: {0:0.0} dB", PreampDb));
        sb.Append("GraphicEQ: ");
        sb.Append(string.Join("; ", frequencies.Select((f, i) => string.Format(inv, "{0:0.##} {1:0.0}", f, gains[i]))));
        sb.AppendLine();
        return sb.ToString();
    }

    public string ToJson()
    {
        TargetFile file = new()
        {
            Format = FileFormatId,
            Version = FileFormatVersion,
            Name = Name,
            Points = frequencies.Select((f, i) => new TargetFilePoint { Hz = f, Db = gains[i] }).ToList()
        };
        return JsonSerializer.Serialize(file, JsonOptions);
    }

    /// <summary>
    /// Parses a SonicScout target JSON, an Equalizer APO "GraphicEQ:" line, or a two-column
    /// "frequency gain" text/CSV (AutoEQ / REW style). Throws FormatException on garbage.
    /// </summary>
    public static TargetCurve Parse(string text, string fallbackName)
    {
        if (string.IsNullOrWhiteSpace(text)) throw new FormatException("The file is empty.");
        string trimmed = text.TrimStart('\uFEFF', ' ', '\t', '\r', '\n');
        if (trimmed.StartsWith('{'))
        {
            TargetFile? file;
            try { file = JsonSerializer.Deserialize<TargetFile>(trimmed, JsonOptions); }
            catch (JsonException ex) { throw new FormatException("The target file is not valid JSON: " + ex.Message, ex); }
            if (file is null || !string.Equals(file.Format, FileFormatId, StringComparison.OrdinalIgnoreCase))
                throw new FormatException("This JSON file is not a SonicScout target.");
            if (file.Version > FileFormatVersion)
                throw new FormatException($"This target was made by a newer SonicScout (format v{file.Version}).");
            return Validated(new TargetCurve(string.IsNullOrWhiteSpace(file.Name) ? fallbackName : file.Name!,
                (file.Points ?? new()).Select(p => new TargetPoint(p.Hz, p.Db))));
        }

        List<TargetPoint> points = new();
        foreach (string rawLine in text.Split('\n'))
        {
            string line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith('#') || line.StartsWith('*')) continue;
            if (line.StartsWith("GraphicEQ:", StringComparison.OrdinalIgnoreCase))
            {
                points.Clear();
                foreach (string pair in line["GraphicEQ:".Length..].Split(';'))
                {
                    string[] parts = pair.Trim().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
                    if (parts.Length >= 2 && TryNum(parts[0], out double f) && TryNum(parts[1], out double g))
                        points.Add(new TargetPoint(f, g));
                }
                break;
            }
            string[] cols = line.Split(new[] { ',', ';', '\t', ' ' }, StringSplitOptions.RemoveEmptyEntries);
            if (cols.Length >= 2 && TryNum(cols[0], out double hz) && TryNum(cols[1], out double db))
                points.Add(new TargetPoint(hz, db));
        }
        if (points.Count == 0)
            throw new FormatException("No frequency/gain points were found. Use a SonicScout .sstarget.json, an Equalizer APO GraphicEQ line, or 'frequency gain' columns.");
        return Validated(new TargetCurve(fallbackName, points));
    }

    private static TargetCurve Validated(TargetCurve curve)
    {
        if (curve.frequencies.Any(f => f < 10 || f > 24000))
            throw new FormatException("Frequencies must be between 10 Hz and 24 kHz.");
        return curve;
    }

    private static bool TryNum(string s, out double value) =>
        double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out value) && double.IsFinite(value);

    private static string SanitizeComment(string s) => s.Replace('\r', ' ').Replace('\n', ' ');

    internal static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        NumberHandling = JsonNumberHandling.AllowReadingFromString
    };

    private sealed class TargetFile
    {
        public string? Format { get; set; }
        public int Version { get; set; }
        public string? Name { get; set; }
        public List<TargetFilePoint>? Points { get; set; }
    }

    private sealed class TargetFilePoint
    {
        public double Hz { get; set; }
        public double Db { get; set; }
    }
}

/// <summary>Named saved targets in %LOCALAPPDATA%\SonicScout\targets, plus the live APO file.</summary>
public sealed class TargetCurveStore
{
    public const string FileExtension = ".sstarget.json";
    public string Directory { get; }
    public string LiveApoPath { get; }

    public TargetCurveStore(string? directory = null, string? liveApoPath = null)
    {
        string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SonicScout");
        Directory = directory ?? Path.Combine(root, "targets");
        LiveApoPath = liveApoPath ?? DefaultLiveApoPath;
    }

    public static string DefaultLiveApoPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SonicScout", "eapo", "user_target.txt");

    public static string SanitizeFileName(string name)
    {
        char[] invalid = Path.GetInvalidFileNameChars().Concat(new[] { '/', '\\', ':', '*', '?', '"', '<', '>', '|' }).ToArray();
        string cleaned = new(name.Trim().Select(c => invalid.Contains(c) ? '_' : c).ToArray());
        cleaned = cleaned.Trim('.', ' ');
        if (cleaned.Length == 0) cleaned = "Custom Target";
        return cleaned.Length > 64 ? cleaned[..64] : cleaned;
    }

    public string PathFor(string name) => Path.Combine(Directory, SanitizeFileName(name) + FileExtension);

    public string Save(TargetCurve curve)
    {
        System.IO.Directory.CreateDirectory(Directory);
        string path = PathFor(curve.Name);
        AtomicWrite(path, curve.ToJson());
        return path;
    }

    public IReadOnlyList<string> ListNames()
    {
        if (!System.IO.Directory.Exists(Directory)) return Array.Empty<string>();
        List<string> names = new();
        foreach (string file in System.IO.Directory.GetFiles(Directory, "*" + FileExtension))
        {
            try { names.Add(TargetCurve.Parse(File.ReadAllText(file), Path.GetFileName(file)[..^FileExtension.Length]).Name); }
            catch (Exception ex) when (ex is FormatException or IOException or UnauthorizedAccessException) { }
        }
        return names.OrderBy(n => n, StringComparer.OrdinalIgnoreCase).ToList();
    }

    public TargetCurve Load(string name) => TargetCurve.Parse(File.ReadAllText(PathFor(name)), name);

    public bool Delete(string name)
    {
        string path = PathFor(name);
        if (!File.Exists(path)) return false;
        File.Delete(path);
        return true;
    }

    public static void Export(TargetCurve curve, string path)
    {
        string content = path.EndsWith(".txt", StringComparison.OrdinalIgnoreCase) ? curve.ToApoConfig() : curve.ToJson();
        AtomicWrite(path, content);
    }

    public static TargetCurve Import(string path)
    {
        string name = Path.GetFileName(path);
        if (name.EndsWith(FileExtension, StringComparison.OrdinalIgnoreCase)) name = name[..^FileExtension.Length];
        else name = Path.GetFileNameWithoutExtension(name);
        return TargetCurve.Parse(File.ReadAllText(path), name).ResampleToDefaultBands();
    }

    /// <summary>Writes the live Equalizer APO include. Returns true only when the content changed,
    /// so repeated calls never touch the file (Equalizer APO reloads on every file change).</summary>
    public bool ApplyLive(TargetCurve curve)
    {
        string content = curve.ToApoConfig();
        if (File.Exists(LiveApoPath) && File.ReadAllText(LiveApoPath) == content) return false;
        AtomicWrite(LiveApoPath, content);
        return true;
    }

    private static void AtomicWrite(string path, string content)
    {
        string? dir = Path.GetDirectoryName(Path.GetFullPath(path));
        if (dir is not null) System.IO.Directory.CreateDirectory(dir);
        string temp = path + ".tmp";
        File.WriteAllText(temp, content, new UTF8Encoding(false));
        File.Move(temp, path, overwrite: true);
    }
}

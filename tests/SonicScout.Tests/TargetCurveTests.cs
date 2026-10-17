using System.Numerics;
using SonicScout;
using Xunit;

public class TargetCurveTests
{
    [Fact]
    public void FlatCurveWritesNoProcessing()
    {
        string apo = TargetCurve.Flat().ToApoConfig();
        Assert.DoesNotContain("GraphicEQ", apo);
        Assert.DoesNotContain("Preamp", apo);
    }

    [Fact]
    public void BoostAddsMatchingNegativePreamp()
    {
        TargetCurve c = TargetCurve.Flat("Bass");
        c.SetGain(0, 6);
        c.SetGain(5, -3);
        string apo = c.ToApoConfig();
        Assert.Contains("Preamp: -6.0 dB", apo);
        Assert.Contains("GraphicEQ: 32 6.0; 64 0.0", apo);
        Assert.Contains("1000 -3.0", apo);
    }

    [Fact]
    public void GainIsClampedAndRounded()
    {
        TargetCurve c = TargetCurve.Flat();
        c.SetGain(1, 40);
        c.SetGain(2, -3.333);
        Assert.Equal(TargetCurve.MaxGainDb, c.Gains[1]);
        Assert.Equal(-3.3, c.Gains[2]);
        c.SetGain(3, double.NaN);
        Assert.Equal(0, c.Gains[3]);
    }

    [Fact]
    public void GainAtInterpolatesOnLogAxis()
    {
        TargetCurve c = new("t", new[] { new TargetPoint(100, 0), new TargetPoint(1000, 10) });
        Assert.Equal(5, c.GainAt(Math.Sqrt(100 * 1000)), 3);
        Assert.Equal(0, c.GainAt(20));
        Assert.Equal(10, c.GainAt(20000));
    }

    [Fact]
    public void JsonRoundTripPreservesNameAndGains()
    {
        TargetCurve c = TargetCurve.Flat("My HD600 tweak");
        c.SetGain(7, 2.5);
        TargetCurve back = TargetCurve.Parse(c.ToJson(), "fallback");
        Assert.Equal("My HD600 tweak", back.Name);
        Assert.Equal(c.Gains, back.Gains);
        Assert.Equal(c.Frequencies, back.Frequencies);
    }

    [Fact]
    public void ParsesApoGraphicEqLine()
    {
        TargetCurve c = TargetCurve.Parse("Preamp: -4 dB\nGraphicEQ: 20 1; 1000 -2.5; 20000 4", "apo");
        Assert.Equal(3, c.Count);
        Assert.Equal(-2.5, c.Gains[1]);
    }

    [Fact]
    public void ParsesTwoColumnCsvWithHeader()
    {
        TargetCurve c = TargetCurve.Parse("frequency,raw\n20,1.0\n1000,0\n10000,-3\n", "csv");
        Assert.Equal(3, c.Count);
        Assert.Equal("csv", c.Name);
    }

    [Theory]
    [InlineData("")]
    [InlineData("hello world")]
    [InlineData("{\"format\":\"other\"}")]
    [InlineData("{not json")]
    [InlineData("GraphicEQ: 5 1; 100000 2")]
    public void RejectsInvalidInput(string text) =>
        Assert.Throws<FormatException>(() => TargetCurve.Parse(text, "x"));

    [Fact]
    public void RejectsNewerFormat() =>
        Assert.Throws<FormatException>(() => TargetCurve.Parse("{\"format\":\"sonicscout-target\",\"version\":99,\"points\":[{\"hz\":100,\"db\":1}]}", "x"));

    [Fact]
    public void ApoConfigUsesInvariantCulture()
    {
        var prev = System.Globalization.CultureInfo.CurrentCulture;
        try
        {
            System.Globalization.CultureInfo.CurrentCulture = new System.Globalization.CultureInfo("de-DE");
            TargetCurve c = TargetCurve.Flat();
            c.SetGain(4, 1.5);
            Assert.Contains("500 1.5", c.ToApoConfig());
            Assert.Contains("Preamp: -1.5 dB", c.ToApoConfig());
        }
        finally { System.Globalization.CultureInfo.CurrentCulture = prev; }
    }

    [Fact]
    public void StoreSaveListLoadExportImportDelete()
    {
        string dir = Path.Combine(Path.GetTempPath(), "ss-target-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            TargetCurveStore store = new(Path.Combine(dir, "targets"), Path.Combine(dir, "eapo", "user_target.txt"));
            TargetCurve c = TargetCurve.Flat("Warzone / night");
            c.SetGain(6, 3);
            string saved = store.Save(c);
            Assert.True(File.Exists(saved));
            Assert.Contains("Warzone _ night", saved);
            Assert.Equal(new[] { "Warzone / night" }, store.ListNames());
            Assert.Equal(3, store.Load("Warzone / night").Gains[6]);

            string exportJson = Path.Combine(dir, "out", "w.sstarget.json");
            TargetCurveStore.Export(c, exportJson);
            TargetCurve imported = TargetCurveStore.Import(exportJson);
            Assert.Equal(c.Gains, imported.Gains);

            string exportTxt = Path.Combine(dir, "out", "w.txt");
            TargetCurveStore.Export(c, exportTxt);
            Assert.Contains("GraphicEQ:", File.ReadAllText(exportTxt));
            Assert.Equal(c.Gains, TargetCurveStore.Import(exportTxt).Gains);

            Assert.True(store.ApplyLive(c));
            DateTime first = File.GetLastWriteTimeUtc(store.LiveApoPath);
            Assert.False(store.ApplyLive(c));
            Assert.Equal(first, File.GetLastWriteTimeUtc(store.LiveApoPath));
            Assert.Contains("GraphicEQ:", File.ReadAllText(store.LiveApoPath));

            Assert.True(store.Delete("Warzone / night"));
            Assert.Empty(store.ListNames());
        }
        finally { if (Directory.Exists(dir)) Directory.Delete(dir, true); }
    }

    [Fact]
    public void ImportResamplesDenseCurveToHandles()
    {
        string dir = Path.Combine(Path.GetTempPath(), "ss-target-imp-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            string path = Path.Combine(dir, "dense.csv");
            File.WriteAllLines(path, Enumerable.Range(0, 200).Select(i => FormattableString.Invariant($"{20 * Math.Pow(1000, i / 199.0):0.###},{(i < 100 ? 4 : -2)}")));
            TargetCurve c = TargetCurveStore.Import(path);
            Assert.Equal(TargetCurve.DefaultBands.Length, c.Count);
            Assert.Equal(4, c.Gains[0]);
            Assert.Equal(-2, c.Gains[^1]);
        }
        finally { Directory.Delete(dir, true); }
    }
}

public class SpectrumAnalyzerTests
{
    private static double[] Analyze(double hz, double amplitude, int rate = 48000, int n = 4096, int bands = 48)
    {
        float[] s = new float[n];
        for (int i = 0; i < n; i++) s[i] = (float)(amplitude * Math.Sin(2 * Math.PI * hz * i / rate));
        double[] b = new double[bands];
        SpectrumAnalyzer.Compute(s, rate, b, new Complex[n]);
        return b;
    }

    [Theory]
    [InlineData(100)]
    [InlineData(1000)]
    [InlineData(8000)]
    public void SinePeaksInTheBandContainingItsFrequency(double hz)
    {
        double[] b = Analyze(hz, 0.5);
        int peak = Array.IndexOf(b, b.Max());
        int expected = (int)(SpectrumAnalyzer.FrequencyToX(hz) * b.Length);
        Assert.InRange(peak, expected - 1, expected + 1);
    }

    [Fact]
    public void LevelIsCalibratedInDbfs()
    {
        double[] b = Analyze(1000, 0.5); // -6 dBFS
        Assert.InRange(SpectrumAnalyzer.NormalizedToDb(b.Max()), -7.5, -5.0);
    }

    [Fact]
    public void SilenceIsFloor()
    {
        double[] b = Analyze(1000, 0);
        Assert.All(b, v => Assert.Equal(0, v));
    }

    [Fact]
    public void AxisMappingRoundTrips()
    {
        Assert.Equal(1000, SpectrumAnalyzer.XToFrequency(SpectrumAnalyzer.FrequencyToX(1000)), 6);
        Assert.Equal(0, SpectrumAnalyzer.FrequencyToX(20), 6);
        Assert.Equal(1, SpectrumAnalyzer.FrequencyToX(20000), 6);
    }

    [Fact]
    public void RejectsNonPowerOfTwo() =>
        Assert.Throws<ArgumentException>(() => SpectrumAnalyzer.Compute(new float[1000], 48000, new double[8], new Complex[1000]));
}

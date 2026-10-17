using System.Numerics;

namespace SonicScout;

/// <summary>
/// Real-time analyzer math: Hann-windowed FFT folded into log-spaced bands from 20 Hz to 20 kHz
/// so the bars line up with the target-curve graph's frequency axis. Pure and unit tested.
/// </summary>
public static class SpectrumAnalyzer
{
    public const double FloorDb = -90;
    public const double CeilingDb = 0;

    public static double FrequencyToX(double hz) =>
        Math.Clamp(Math.Log(Math.Max(hz, 1) / TargetCurve.MinFrequencyHz) / Math.Log(TargetCurve.MaxFrequencyHz / TargetCurve.MinFrequencyHz), 0, 1);

    public static double XToFrequency(double x) =>
        TargetCurve.MinFrequencyHz * Math.Pow(TargetCurve.MaxFrequencyHz / TargetCurve.MinFrequencyHz, Math.Clamp(x, 0, 1));

    public static double BandCenter(int index, int count) => XToFrequency((index + 0.5) / count);

    /// <summary>Band levels normalised 0..1 (FloorDb..CeilingDb dBFS; a full-scale sine = 0 dBFS).
    /// <paramref name="samples"/> length must be a power of two.</summary>
    public static void Compute(float[] samples, int sampleRate, double[] bands, Complex[] scratch)
    {
        int n = samples.Length;
        if (n < 2 || (n & (n - 1)) != 0) throw new ArgumentException("Sample window must be a power of two.", nameof(samples));
        if (scratch.Length < n) throw new ArgumentException("Scratch buffer too small.", nameof(scratch));
        if (sampleRate <= 0) throw new ArgumentOutOfRangeException(nameof(sampleRate));

        double windowSum = 0;
        for (int i = 0; i < n; i++)
        {
            double w = 0.5 * (1 - Math.Cos((2 * Math.PI * i) / (n - 1)));
            windowSum += w;
            scratch[i] = new Complex(samples[i] * w, 0);
        }
        Fft(scratch, n);

        int maxBin = n / 2;
        double binHz = sampleRate / (double)n;
        int count = bands.Length;
        for (int band = 0; band < count; band++)
        {
            double lo = XToFrequency(band / (double)count);
            double hi = XToFrequency((band + 1) / (double)count);
            int startBin = Math.Max(1, (int)Math.Ceiling(lo / binHz));
            int endBin = Math.Min(maxBin - 1, (int)Math.Floor(hi / binHz));
            double peak = 0;
            if (startBin <= endBin)
            {
                for (int bin = startBin; bin <= endBin; bin++) peak = Math.Max(peak, scratch[bin].Magnitude);
            }
            else
            {
                int nearest = Math.Clamp((int)Math.Round(BandCenter(band, count) / binHz), 1, maxBin - 1);
                peak = scratch[nearest].Magnitude;
            }
            double amplitude = (2 * peak) / windowSum;
            double db = amplitude > 1e-9 ? 20 * Math.Log10(amplitude) : FloorDb;
            bands[band] = Math.Clamp((db - FloorDb) / (CeilingDb - FloorDb), 0, 1);
        }
    }

    public static double NormalizedToDb(double normalized) => FloorDb + (Math.Clamp(normalized, 0, 1) * (CeilingDb - FloorDb));

    private static void Fft(Complex[] values, int length)
    {
        for (int i = 1, j = 0; i < length; i++)
        {
            int bit = length >> 1;
            for (; (j & bit) != 0; bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) (values[i], values[j]) = (values[j], values[i]);
        }
        for (int width = 2; width <= length; width <<= 1)
        {
            Complex step = Complex.FromPolarCoordinates(1, -2 * Math.PI / width);
            for (int start = 0; start < length; start += width)
            {
                Complex factor = Complex.One;
                for (int k = 0; k < width / 2; k++)
                {
                    Complex even = values[start + k];
                    Complex odd = factor * values[start + k + (width / 2)];
                    values[start + k] = even + odd;
                    values[start + k + (width / 2)] = even - odd;
                    factor *= step;
                }
            }
        }
    }
}

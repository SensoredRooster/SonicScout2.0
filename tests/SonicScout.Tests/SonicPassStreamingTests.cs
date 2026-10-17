using NAudio.Wave;
using Xunit;

namespace SonicScout.SonicPass.Tests;

/// <summary>
/// Regression for the beta.1 "blip then ~1 s silence" dropout: render reads must only pull
/// what the device asks for, so a continuous tone written in 10 ms packets plays without gaps.
/// </summary>
public class SonicPassStreamingTests
{
    private static readonly WaveFormat Cable = WaveFormat.CreateIeeeFloatWaveFormat(48000, 2);

    private static WaveFormatExtensible NativeFloat(int channels) => new(48000, 32, channels);

    [Theory]
    [InlineData(2)]
    [InlineData(8)]
    public void ContinuousToneHasNoSilentGapsThroughNativeConverter(int outChannels)
    {
        BufferedWaveProvider buffer = new(Cable) { BufferDuration = TimeSpan.FromMilliseconds(400), DiscardOnBufferOverflow = true, ReadFully = true };
        ISampleProvider samples = buffer.ToSampleProvider();
        if (outChannels != 2) samples = new StereoOutputSampleProvider(samples, outChannels);
        WaveFormatExtensible native = NativeFloat(outChannels);
        Assert.False(SonicPassEngine.HaveIdenticalFormatDescriptors(samples.ToWaveProvider().WaveFormat, native));
        IWaveProvider render = new NativeFormatWaveProvider(samples, native);
        Assert.Same(native, render.WaveFormat);

        int packetFrames = 480; // 10 ms
        byte[] packet = new byte[packetFrames * Cable.BlockAlign];
        byte[] outBuf = new byte[packetFrames * native.BlockAlign];
        long phase = 0;
        int silentRuns = 0, longestSilence = 0, current = 0;
        // Prime with two packets (start-up latency), then 3 s of lock-step 10 ms write/read.
        for (int i = 0; i < 302; i++)
        {
            for (int f = 0; f < packetFrames; f++, phase++)
            {
                float v = (float)(0.25 * Math.Sin(2 * Math.PI * 440 * phase / 48000.0));
                BitConverter.TryWriteBytes(packet.AsSpan(f * 8, 4), v);
                BitConverter.TryWriteBytes(packet.AsSpan(f * 8 + 4, 4), v);
            }
            buffer.AddSamples(packet, 0, packet.Length);
            if (i < 2) continue;
            int read = render.Read(outBuf, 0, outBuf.Length);
            Assert.Equal(outBuf.Length, read);
            for (int f = 0; f < packetFrames; f++)
            {
                float l = BitConverter.ToSingle(outBuf, f * native.BlockAlign);
                if (Math.Abs(l) < 1e-6) { current++; longestSilence = Math.Max(longestSilence, current); }
                else { if (current > 4) silentRuns++; current = 0; }
            }
        }
        // A 440 Hz sine crosses zero briefly; any run > 4 samples (~0.1 ms) is a dropout.
        Assert.Equal(0, silentRuns);
        Assert.True(longestSilence <= 4, $"longest silent run {longestSilence} samples");
    }

    [Fact]
    public void ConverterWritesPcm24WhenDeviceIsPcm()
    {
        BufferedWaveProvider buffer = new(Cable) { ReadFully = true };
        byte[] one = new byte[8];
        BitConverter.TryWriteBytes(one.AsSpan(0, 4), 0.5f);
        BitConverter.TryWriteBytes(one.AsSpan(4, 4), -0.5f);
        buffer.AddSamples(one, 0, 8);
        WaveFormat pcm24 = new(48000, 24, 2);
        NativeFormatWaveProvider render = new(buffer.ToSampleProvider(), pcm24);
        byte[] o = new byte[6];
        Assert.Equal(6, render.Read(o, 0, 6));
        int l = o[0] | (o[1] << 8) | ((sbyte)o[2] << 16);
        Assert.InRange(l, 4194300, 4194310);
    }

    [Fact]
    public void ConverterRejectsRateMismatch() =>
        Assert.Throws<ArgumentException>(() => new NativeFormatWaveProvider(new BufferedWaveProvider(Cable).ToSampleProvider(), NativeFloat(2).SampleRate == 48000 ? new WaveFormatExtensible(44100, 32, 2) : NativeFloat(2)));

    private sealed class CountingProvider : IWaveProvider
    {
        public CountingProvider(WaveFormat f) => WaveFormat = f;
        public WaveFormat WaveFormat { get; }
        public int LargestRequest { get; private set; }
        public int Read(byte[] buffer, int offset, int count) { LargestRequest = Math.Max(LargestRequest, count); Array.Clear(buffer, offset, count); return count; }
    }

    /// <summary>Documents the root cause: MF pulls ~1 s from the live buffer per read.</summary>
    [Fact]
    public void RootCause_MediaFoundationResamplerPullsAboutOneSecondPerRead()
    {
        CountingProvider src = new(Cable);
        using MediaFoundationResampler mf = new(src, new WaveFormatExtensible(48000, 24, 2));
        mf.Read(new byte[480 * 6], 0, 480 * 6); // device asks for 10 ms
        Assert.True(src.LargestRequest >= Cable.AverageBytesPerSecond / 2, $"largest source read {src.LargestRequest} bytes");

        CountingProvider src2 = new(Cable);
        NativeFormatWaveProvider ours = new(new NAudio.Wave.SampleProviders.WaveToSampleProvider(src2), new WaveFormatExtensible(48000, 24, 2));
        ours.Read(new byte[480 * 6], 0, 480 * 6);
        Assert.Equal(480 * 8, src2.LargestRequest); // exactly 10 ms
    }

    /// <summary>VB-CABLE style bursty delivery: 30 ms bursts with up to 40 ms of jitter, 10 ms render pulls.
    /// The adaptive buffer must converge so that after the first second there are no zero-filled reads.</summary>
    [Fact]
    public void JitterBufferAbsorbsBurstyCaptureWithoutGaps()
    {
        BufferedWaveProvider raw = new(Cable) { BufferDuration = TimeSpan.FromSeconds(1), DiscardOnBufferOverflow = true };
        JitterBuffer jb = new(raw, 20);
        var rng = new Random(7);
        byte[] burst = new byte[1440 * 8]; // 30 ms
        for (int i = 0; i < burst.Length; i += 4) BitConverter.TryWriteBytes(burst.AsSpan(i, 4), 0.25f);
        byte[] outBuf = new byte[480 * 8];
        int burstIndex = 0; double nextBurstMs = 0; int gapsAfterWarmup = 0; long trims = 0;
        for (int t = 0; t < 60000; t += 10) // 60 s, render tick every 10 ms
        {
            while (nextBurstMs <= t)
            {
                if (jb.TrimBeforeAdd(burst.Length)) trims++;
                raw.AddSamples(burst, 0, burst.Length);
                burstIndex++; nextBurstMs = (burstIndex * 30) + rng.Next(0, 41); // nominal 30 ms grid, 0-40 ms late (no accumulation)
            }
            long before = jb.Underruns;
            Assert.Equal(outBuf.Length, jb.Read(outBuf, 0, outBuf.Length));
            bool zeros = BitConverter.ToSingle(outBuf, 0) == 0f || BitConverter.ToSingle(outBuf, outBuf.Length - 4) == 0f;
            if (t > 5000 && (zeros || jb.Underruns != before)) gapsAfterWarmup++;
        }
        Assert.True(gapsAfterWarmup == 0, $"gaps after warm-up: {gapsAfterWarmup}, target {jb.TargetMilliseconds} ms, underruns {jb.Underruns}, trims {trims}");
        Assert.InRange(jb.TargetMilliseconds, 30, 200);
    }

    private static (long drops, long underruns, double ratio, double finalMs) RunDrift(double producerRateFactor, bool compensate, int seconds)
    {
        BufferedWaveProvider raw = new(Cable) { BufferDuration = TimeSpan.FromSeconds(1), DiscardOnBufferOverflow = true };
        JitterBuffer jb = new(raw, 20);
        ISampleProvider samples = jb.ToSampleProvider();
        DriftCompensatingSampleProvider? drift = compensate ? new(samples, () => jb.FillError) : null;
        ISampleProvider render = (ISampleProvider?)drift ?? samples;
        float[] outBuf = new float[480 * 2];
        double phase = 0, owed = 0;
        long drops = 0, underrunsAfterWarmup = 0;
        for (int step = 0; step < seconds * 100; step++)
        {
            owed += 480 * producerRateFactor;
            int frames = (int)owed; owed -= frames;
            float[] packet = new float[frames * 2];
            for (int i = 0; i < frames; i++) { float v = (float)(0.25 * Math.Sin(phase)); phase += 2 * Math.PI * 1000 / 48000; packet[2 * i] = v; packet[2 * i + 1] = v; }
            byte[] bytes = new byte[packet.Length * 4];
            Buffer.BlockCopy(packet, 0, bytes, 0, bytes.Length);
            if (jb.TrimBeforeAdd(bytes.Length)) drops++;
            raw.AddSamples(bytes, 0, bytes.Length);
            long before = jb.Underruns;
            render.Read(outBuf, 0, outBuf.Length);
            if (step > 200) underrunsAfterWarmup += jb.Underruns - before;
        }
        return (drops, underrunsAfterWarmup, drift?.Ratio ?? 1.0, raw.BufferedDuration.TotalMilliseconds);
    }

    [Theory]
    [InlineData(1.003)]
    [InlineData(0.997)]
    public void DriftCompensationAbsorbsNormalClockDrift(double factor)
    {
        var without = RunDrift(factor, compensate: false, seconds: 120);
        Assert.True(without.drops + without.underruns > 0, "uncompensated drift should eventually drop or underrun");
        var with = RunDrift(factor, compensate: true, seconds: 120);
        Assert.Equal(0, with.drops);
        Assert.Equal(0, with.underruns);
        Assert.InRange(with.ratio, 1 - DriftCompensatingSampleProvider.MaxCorrection, 1 + DriftCompensatingSampleProvider.MaxCorrection);
        Assert.InRange(with.finalMs, 5, 120);
    }

    [Fact]
    public void DriftCompensationIsTransparentWithMatchedClocks()
    {
        var r = RunDrift(1.0, compensate: true, seconds: 30);
        Assert.Equal(0, r.drops);
        Assert.Equal(0, r.underruns);
        Assert.InRange(r.ratio, 0.999, 1.001);
    }

    [Fact]
    public void DriftCompensatorInterpolatesSmoothly()
    {
        BufferedWaveProvider raw = new(Cable) { BufferDuration = TimeSpan.FromSeconds(2), ReadFully = true };
        float[] tone = new float[48000 * 2];
        for (int i = 0; i < 48000; i++) tone[2 * i] = tone[2 * i + 1] = (float)(0.5 * Math.Sin(2 * Math.PI * 440 * i / 48000));
        byte[] b = new byte[tone.Length * 4]; Buffer.BlockCopy(tone, 0, b, 0, b.Length); raw.AddSamples(b, 0, b.Length);
        var drift = new DriftCompensatingSampleProvider(raw.ToSampleProvider(), () => 1.0); // max speed-up
        float[] o = new float[480 * 2]; float maxStep = 0, prev = 0;
        for (int k = 0; k < 90; k++)
        {
            drift.Read(o, 0, o.Length);
            for (int i = 0; i < 480; i++) { if (k + i > 0) maxStep = Math.Max(maxStep, Math.Abs(o[2 * i] - prev)); prev = o[2 * i]; }
        }
        // 440 Hz at 0.5 amplitude changes at most ~0.029 per sample; a discontinuity would be far larger.
        Assert.True(maxStep < 0.035f, $"max step {maxStep}");
    }
}

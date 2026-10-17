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
}

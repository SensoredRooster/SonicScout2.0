using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace SonicScout.SonicPass;

internal static class Program
{
    private static int Main(string[] args)
    {
        try { return Run(args); }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"SonicPass startup failed (HRESULT 0x{exception.HResult:X8}): {exception.Message}");
            return 1;
        }
    }

    private static int Run(string[] args)
    {
        SonicPassOptions options;
        try
        {
            options = SonicPassOptions.Parse(args);
        }
        catch (ArgumentException exception)
        {
            Console.Error.WriteLine(exception.Message);
            SonicPassOptions.PrintUsage();
            return 2;
        }

        if (options.ShowHelp)
        {
            SonicPassOptions.PrintUsage();
            return 0;
        }

        string inputId;
        string outputId;
        using (MMDeviceEnumerator resolver = new())
        {
            using MMDevice resolvedInput = DeviceResolver.ResolveInput(resolver, options.InputId, options.InputName);
            using MMDevice resolvedOutput = DeviceResolver.ResolveOutput(resolver, options.OutputId, options.OutputName);
            inputId = resolvedInput.ID;
            outputId = resolvedOutput.ID;
        }

        bool cancelRequested = false;
        SonicPassEngine? current = null;
        Console.CancelKeyPress += (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            cancelRequested = true;
            current?.Stop();
        };

        // Supervisor: when Windows invalidates an endpoint (device change, driver
        // install, Windows Audio restart -> AUDCLNT_E_* 0x8889xxxx) the engine is torn
        // down and rebuilt from the same endpoint ids instead of exiting.
        int rebuilds = 0;
        bool announced = false;
        while (true)
        {
            Exception? failure;
            try
            {
                using MMDeviceEnumerator enumerator = new();
                MMDevice input = enumerator.GetDevice(inputId);
                MMDevice output = enumerator.GetDevice(outputId);
                using SonicPassEngine scoutPass = new(input, output, options.BufferMilliseconds, options.InputGainDb, options.OutputGainDb);
                current = scoutPass;
                scoutPass.Start();
                if (!announced)
                {
                    Console.WriteLine($"SonicPass running: {input.FriendlyName} -> {output.FriendlyName}");
                    Console.WriteLine($"Format: {scoutPass.Format.SampleRate} Hz, {scoutPass.Format.Channels} channel(s), {scoutPass.Format.BitsPerSample}-bit");
                    Console.WriteLine("Press Ctrl+C to stop.");
                    announced = true;
                }
                else
                {
                    Console.WriteLine($"SonicPass rebuilt after audio device invalidation (rebuild {rebuilds}).");
                }
                rebuilds = 0;

                while (scoutPass.IsRunning && !cancelRequested)
                {
                    Thread.Sleep(1000);
                    Console.WriteLine($"Packets: {scoutPass.PacketsReceived}, buffer drops: {scoutPass.BufferDrops}, buffered: {scoutPass.BufferedMilliseconds} ms, target: {scoutPass.TargetMilliseconds} ms, underruns: {scoutPass.Underruns}");
                }
                failure = scoutPass.LastError;
                current = null;
            }
            catch (Exception exception)
            {
                current = null;
                failure = exception;
            }

            if (cancelRequested) return 0;
            if (failure is null) return 0;
            if (!SonicPassRecovery.IsRecoverable(failure) || rebuilds >= SonicPassRecovery.MaxRebuilds)
            {
                Console.Error.WriteLine($"SonicPass stopped (HRESULT 0x{failure.HResult:X8}): {failure}");
                return 1;
            }
            rebuilds++;
            TimeSpan delay = SonicPassRecovery.Delay(rebuilds);
            Console.Error.WriteLine($"SonicPass: audio endpoint invalidated (HRESULT 0x{SonicPassRecovery.FindAudioHResult(failure):X8}); rebuilding in {delay.TotalMilliseconds:0} ms (attempt {rebuilds}/{SonicPassRecovery.MaxRebuilds}).");
            Thread.Sleep(delay);
        }
    }
}

internal static class SonicPassRecovery
{
    public const int MaxRebuilds = 40;

    public static TimeSpan Delay(int attempt) => TimeSpan.FromMilliseconds(Math.Min(5000, 250 * Math.Pow(2, Math.Min(attempt - 1, 10))));

    public static int FindAudioHResult(Exception exception)
    {
        for (Exception? e = exception; e is not null; e = e.InnerException)
        {
            if (((uint)e.HResult & 0xFFFF0000u) == 0x88890000u) return e.HResult;
            // AUDCLNT/MMDevice "not found" / RPC failure while Audiosrv restarts.
            if ((uint)e.HResult is 0x80070490u or 0x800706BAu or 0x800706BEu or 0x80070002u) return e.HResult;
        }
        return 0;
    }

    public static bool IsRecoverable(Exception exception) =>
        FindAudioHResult(exception) != 0 ||
        (exception is InvalidOperationException && exception.Message.Contains("did not deliver audio packets", StringComparison.Ordinal));
}

internal sealed class SonicPassOptions
{
    public string? InputId { get; private set; }
    public string? InputName { get; private set; }
    public string? OutputId { get; private set; }
    public string? OutputName { get; private set; }
    public int BufferMilliseconds { get; private set; } = 20;
    public double InputGainDb { get; private set; }
    public double OutputGainDb { get; private set; }
    public bool ShowHelp { get; private set; }

    public static SonicPassOptions Parse(string[] args)
    {
        SonicPassOptions options = new();
        for (int index = 0; index < args.Length; index++)
        {
            string argument = args[index];
            if (argument is "--help" or "-h")
            {
                options.ShowHelp = true;
                continue;
            }

            string value = ReadValue(args, ref index, argument);
            switch (argument.ToLowerInvariant())
            {
                case "--input-id":
                    options.InputId = value;
                    break;
                case "--input-name":
                    options.InputName = value;
                    break;
                case "--output-id":
                    options.OutputId = value;
                    break;
                case "--output-name":
                    options.OutputName = value;
                    break;
                case "--buffer-ms":
                    if (!int.TryParse(value, out int bufferMilliseconds) || bufferMilliseconds is < 20 or > 500)
                    {
                        throw new ArgumentException("--buffer-ms must be an integer from 20 to 500.");
                    }
                    options.BufferMilliseconds = bufferMilliseconds;
                    break;
                case "--input-gain-db":
                    options.InputGainDb = ParseGain(value, argument);
                    break;
                case "--output-gain-db":
                    options.OutputGainDb = ParseGain(value, argument);
                    break;
                default:
                    throw new ArgumentException($"Unknown SonicPass option: {argument}");
            }
        }

        return options;
    }

    public static void PrintUsage()
    {
        Console.WriteLine("Sonic Scout SonicPass");
        Console.WriteLine("  --input-id <id>       Processed cable recording endpoint ID (legacy cable render ID is paired automatically)");
        Console.WriteLine("  --input-name <name>   Processed cable recording endpoint name fragment");
        Console.WriteLine("  --output-id <id>      Physical render endpoint ID");
        Console.WriteLine("  --output-name <name>  Physical render endpoint name fragment");
        Console.WriteLine("  --buffer-ms <20..500> Shared-mode buffer target");
        Console.WriteLine("  --input-gain-db <-12..12> Input boost/cut");
        Console.WriteLine("  --output-gain-db <-12..12> Output boost/cut");
    }

    private static string ReadValue(string[] args, ref int index, string argument)
    {
        if (index + 1 >= args.Length || args[index + 1].StartsWith("--", StringComparison.Ordinal))
        {
            throw new ArgumentException($"Missing value for {argument}.");
        }

        return args[++index];
    }

    private static double ParseGain(string value, string argument)
    {
        if (!double.TryParse(value, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out double gain) || gain is < -12 or > 12)
        {
            throw new ArgumentException($"{argument} must be between -12 and 12 dB.");
        }

        return gain;
    }
}

internal static class DeviceResolver
{
    private static readonly string[] VirtualEndpointHints =
    [
        "Sonic Scout", "SonicScout", "VB-Audio", "VB-Cable", "Virtual Cable", "CABLE Input", "Hi-Fi Cable"
    ];

    public static MMDevice ResolveInput(MMDeviceEnumerator enumerator, string? id, string? name)
    {
        MMDevice[] captures = enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active)
            .Where(device => IsVirtualCable(device.FriendlyName)).ToArray();
        if (!string.IsNullOrWhiteSpace(id))
        {
            MMDevice selected = enumerator.GetDevice(id);
            if (selected.State != DeviceState.Active || !IsVirtualCable(selected.FriendlyName))
                throw new InvalidOperationException("SonicPass input must be an active virtual cable endpoint.");
            if (selected.DataFlow == DataFlow.Capture) return selected;
            string adapterId = ParentDeviceIdentity(selected.DeviceTopology.GetConnector(0).ConnectedToDeviceId);
            if (string.IsNullOrWhiteSpace(adapterId))
                throw new InvalidOperationException("The virtual cable's device identity is unavailable. Select its recording endpoint explicitly.");
            MMDevice[] matches = captures.Where(device => string.Equals(
                ParentDeviceIdentity(device.DeviceTopology.GetConnector(0).ConnectedToDeviceId), adapterId,
                StringComparison.OrdinalIgnoreCase)).ToArray();
            return RequireSingleCapture(matches);
        }
        if (!string.IsNullOrWhiteSpace(name))
            captures = captures.Where(device => device.FriendlyName.Contains(name, StringComparison.OrdinalIgnoreCase)).ToArray();
        return RequireSingleCapture(captures);
    }

    internal static bool IsVirtualCable(string name) => VirtualEndpointHints.Any(hint =>
        name.Contains(hint, StringComparison.OrdinalIgnoreCase));

    // Render and capture have different topology filter names on the same driver.
    // Keep the device-instance path preceding the interface class/filter suffix.
    internal static string ParentDeviceIdentity(string topologyDeviceId)
    {
        int start = topologyDeviceId.IndexOf(@"\\?\", StringComparison.Ordinal);
        int end = topologyDeviceId.IndexOf("#{", StringComparison.Ordinal);
        return start >= 0 && end > start ? topologyDeviceId[start..end] : string.Empty;
    }

    private static MMDevice RequireSingleCapture(MMDevice[] captures) => captures.Length == 1
        ? captures[0]
        : throw new InvalidOperationException(captures.Length == 0
            ? "No matching processed virtual cable recording endpoint is active. Enable the cable's recording output in Windows Sound settings."
            : "More than one cable recording endpoint matches. Select its recording endpoint explicitly with --input-id.");
    public static MMDevice ResolveOutput(MMDeviceEnumerator enumerator, string? id, string? name)
    {
        if (!string.IsNullOrWhiteSpace(id))
        {
            return enumerator.GetDevice(id);
        }

        MMDeviceCollection devices = enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active);
        MMDevice? match = devices.FirstOrDefault(device =>
            !string.IsNullOrWhiteSpace(name) && device.FriendlyName.Contains(name, StringComparison.OrdinalIgnoreCase));
        match ??= enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
        return match;
    }
}

internal sealed class SonicPassEngine : IDisposable
{
    private readonly MMDevice inputDevice;
    private readonly MMDevice outputDevice;
    private readonly int bufferMilliseconds;
    private readonly float gainMultiplier;
    private readonly object stateLock = new();
    private IWaveIn? capture;
    private WasapiOut? output;
    private BufferedWaveProvider? buffer;
    private long packetsReceived;
    private long bufferDrops;
    private JitterBuffer? jitter;
    private bool stopped;

    public SonicPassEngine(MMDevice inputDevice, MMDevice outputDevice, int bufferMilliseconds, double inputGainDb, double outputGainDb)
    {
        this.inputDevice = inputDevice;
        this.outputDevice = outputDevice;
        this.bufferMilliseconds = bufferMilliseconds;
        gainMultiplier = (float)Math.Pow(10, (inputGainDb + outputGainDb) / 20.0);
    }

    public WaveFormat Format => capture?.WaveFormat ?? throw new InvalidOperationException("SonicPass has not started.");
    public bool IsRunning { get; private set; }
    public Exception? LastError { get; private set; }
    public long PacketsReceived => Interlocked.Read(ref packetsReceived);
    public long BufferDrops => Interlocked.Read(ref bufferDrops);
    public int BufferedMilliseconds => buffer is null ? 0 : (int)buffer.BufferedDuration.TotalMilliseconds;
    public long Underruns => jitter?.Underruns ?? 0;
    public int TargetMilliseconds => jitter?.TargetMilliseconds ?? 0;

    public void Start()
    {
        lock (stateLock)
        {
            if (IsRunning)
            {
                return;
            }

            if (inputDevice.DataFlow != DataFlow.Capture || inputDevice.AudioClient.MixFormat.Channels != 2)
                throw new InvalidOperationException("SonicPass requires the processed stereo recording endpoint; render loopback and multichannel downmix are not supported.");
            if (outputDevice.DataFlow != DataFlow.Render || outputDevice.AudioClient.MixFormat.Channels < 2 || DeviceResolver.IsVirtualCable(outputDevice.FriendlyName))
                throw new InvalidOperationException("Select a physical output with at least two channels, rather than a virtual cable.");
            capture = new WasapiCapture(inputDevice);
            buffer = new BufferedWaveProvider(capture.WaveFormat)
            {
                BufferDuration = TimeSpan.FromSeconds(1),
                DiscardOnBufferOverflow = true,
                ReadFully = false
            };
            WaveFormat outputFormat = outputDevice.AudioClient.MixFormat;
            jitter = new JitterBuffer(buffer, bufferMilliseconds);
            IWaveProvider playbackProvider = jitter;
            ISampleProvider? convertedSamples = null;
            if (!AreCompatibleFormats(capture.WaveFormat, outputFormat))
            {
                ISampleProvider sampleProvider = jitter.ToSampleProvider();
                if (sampleProvider.WaveFormat.Channels != outputFormat.Channels)
                {
                    sampleProvider = new StereoOutputSampleProvider(sampleProvider, outputFormat.Channels);
                }
                if (sampleProvider.WaveFormat.SampleRate != outputFormat.SampleRate)
                {
                    sampleProvider = new WdlResamplingSampleProvider(sampleProvider, outputFormat.SampleRate);
                }
                convertedSamples = sampleProvider;
                playbackProvider = sampleProvider.ToWaveProvider();
            }
            // Never use MediaFoundationResampler here: NAudio's MF transform pulls a full
            // second (AverageBytesPerSecond) from the source per read. With a ReadFully
            // BufferedWaveProvider that is ~buffer-ms of real audio followed by ~1 s of zero
            // padding, which played as "a blip of sound, then silence" once per second.
            // Convert per render callback straight into the device's native mix format.
            if (!HaveIdenticalFormatDescriptors(playbackProvider.WaveFormat, outputFormat))
            {
                ISampleProvider samples = convertedSamples ?? jitter.ToSampleProvider();
                playbackProvider = new NativeFormatWaveProvider(samples, outputFormat);
            }
            Console.Error.WriteLine($"SonicPass playback initialization: capture={capture.WaveFormat}; native={outputFormat}; playback={playbackProvider.WaveFormat}; buffer={bufferMilliseconds}ms; shared/event mode.");
            output = new WasapiOut(outputDevice, AudioClientShareMode.Shared, true, bufferMilliseconds);
            output.Init(playbackProvider);
            capture.DataAvailable += CaptureOnDataAvailable;
            capture.RecordingStopped += CaptureOnRecordingStopped;
            output.PlaybackStopped += OutputOnPlaybackStopped;

            // Capture must deliver at least one packet before Play() starts the WASAPI render
            // thread; NAudio's WasapiOut treats an empty first read as end-of-stream and silently
            // exits without ever calling AudioClient.Start(), leaving PlaybackState stuck at Playing.
            stopped = false;
            IsRunning = true;
            capture.StartRecording();
            if (!SpinWait.SpinUntil(() => buffer.BufferedBytes > 0 || LastError is not null, TimeSpan.FromSeconds(3)) || LastError is not null)
                throw new InvalidOperationException("The cable recording endpoint did not deliver audio packets.", LastError);
            output.Play();
        }
    }

    public void Stop()
    {
        lock (stateLock)
        {
            if (stopped)
            {
                return;
            }

            stopped = true;
            IsRunning = false;
            try
            {
                capture?.StopRecording();
            }
            catch (Exception exception)
            {
                LastError ??= exception;
            }

            try
            {
                output?.Stop();
            }
            catch (Exception exception)
            {
                LastError ??= exception;
            }
        }
    }

    public void Dispose()
    {
        Stop();
        capture?.Dispose();
        output?.Dispose();
        inputDevice.Dispose();
        outputDevice.Dispose();
    }

    private void CaptureOnDataAvailable(object? sender, WaveInEventArgs eventArgs)
    {
        if (buffer is null || eventArgs.BytesRecorded == 0)
        {
            return;
        }

        ApplyGain(eventArgs.Buffer, eventArgs.BytesRecorded);
        // Latency control lives in JitterBuffer: trim only far above the adaptive target.
        if (jitter is not null && jitter.TrimBeforeAdd(eventArgs.BytesRecorded)) Interlocked.Increment(ref bufferDrops);
        int before = buffer.BufferedBytes;
        buffer.AddSamples(eventArgs.Buffer, 0, eventArgs.BytesRecorded);
        if (buffer.BufferedBytes == before && eventArgs.BytesRecorded > 0)
        {
            Interlocked.Increment(ref bufferDrops);
        }
        Interlocked.Increment(ref packetsReceived);
    }

    internal static bool HaveIdenticalFormatDescriptors(WaveFormat input, WaveFormat output)
    {
        static byte[] Descriptor(WaveFormat format)
        {
            using var stream = new MemoryStream();
            using var writer = new BinaryWriter(stream);
            format.Serialize(writer);
            return stream.ToArray();
        }
        return Descriptor(input).SequenceEqual(Descriptor(output));
    }

    private static bool AreCompatibleFormats(WaveFormat input, WaveFormat output)
    {
        return input.Encoding == output.Encoding &&
               input.SampleRate == output.SampleRate &&
               input.Channels == output.Channels &&
               input.BitsPerSample == output.BitsPerSample;
    }

    private void ApplyGain(byte[] samples, int bytesRecorded)
    {
        if (Math.Abs(gainMultiplier - 1f) < 0.0001f)
        {
            return;
        }

        if (Format.Encoding == WaveFormatEncoding.IeeeFloat && Format.BitsPerSample == 32)
        {
            for (int offset = 0; offset + 4 <= bytesRecorded; offset += 4)
            {
                float sample = BitConverter.ToSingle(samples, offset);
                float adjusted = Math.Clamp(sample * gainMultiplier, -1f, 1f);
                BitConverter.TryWriteBytes(samples.AsSpan(offset, 4), adjusted);
            }
        }
        else if (Format.Encoding == WaveFormatEncoding.Pcm && Format.BitsPerSample == 16)
        {
            for (int offset = 0; offset + 2 <= bytesRecorded; offset += 2)
            {
                short sample = BitConverter.ToInt16(samples, offset);
                short adjusted = (short)Math.Clamp(sample * gainMultiplier, short.MinValue, short.MaxValue);
                BitConverter.TryWriteBytes(samples.AsSpan(offset, 2), adjusted);
            }
        }
    }

    private void CaptureOnRecordingStopped(object? sender, StoppedEventArgs eventArgs)
    {
        if (eventArgs.Exception is not null)
        {
            LastError = eventArgs.Exception;
        }
        IsRunning = false;
    }

    private void OutputOnPlaybackStopped(object? sender, StoppedEventArgs eventArgs)
    {
        if (eventArgs.Exception is not null)
        {
            LastError = eventArgs.Exception;
        }
        IsRunning = false;
    }
}

/// <summary>Places processed stereo L/R in the front pair; other output channels are silent.</summary>
internal sealed class StereoOutputSampleProvider : ISampleProvider
{
    private readonly ISampleProvider source;
    private float[] sourceBuffer = [];
    public StereoOutputSampleProvider(ISampleProvider source, int outputChannels)
    {
        if (source.WaveFormat.Channels != 2 || outputChannels < 2)
            throw new ArgumentException("Only processed stereo input and outputs with at least two channels are supported.");
        this.source = source;
        WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(source.WaveFormat.SampleRate, outputChannels);
    }
    public WaveFormat WaveFormat { get; }
    public int Read(float[] buffer, int offset, int count)
    {
        int frames = count / WaveFormat.Channels;
        if (sourceBuffer.Length < frames * 2) sourceBuffer = new float[frames * 2];
        int framesRead = source.Read(sourceBuffer, 0, frames * 2) / 2;
        Array.Clear(buffer, offset, framesRead * WaveFormat.Channels);
        for (int frame = 0; frame < framesRead; frame++)
        {
            buffer[offset + frame * WaveFormat.Channels] = sourceBuffer[frame * 2];
            buffer[offset + frame * WaveFormat.Channels + 1] = sourceBuffer[frame * 2 + 1];
        }
        return framesRead * WaveFormat.Channels;
    }
}

/// <summary>
/// Float samples -> the render endpoint's exact native mix format (IEEE float or 16/24/32-bit PCM,
/// Extensible descriptors preserved). Reads only what each WASAPI callback asks for.
/// </summary>
internal sealed class NativeFormatWaveProvider : IWaveProvider
{
    private static readonly Guid FloatSubFormat = new("00000003-0000-0010-8000-00aa00389b71");
    private readonly ISampleProvider source;
    private readonly bool isFloat;
    private readonly int bytesPerSample;
    private float[] scratch = [];

    public NativeFormatWaveProvider(ISampleProvider source, WaveFormat nativeFormat)
    {
        if (source.WaveFormat.SampleRate != nativeFormat.SampleRate || source.WaveFormat.Channels != nativeFormat.Channels)
            throw new ArgumentException($"Converter expects {nativeFormat.SampleRate} Hz / {nativeFormat.Channels} ch samples, got {source.WaveFormat.SampleRate} Hz / {source.WaveFormat.Channels} ch.");
        this.source = source;
        WaveFormat = nativeFormat;
        isFloat = nativeFormat.Encoding == WaveFormatEncoding.IeeeFloat ||
                  (nativeFormat is WaveFormatExtensible ext && ext.SubFormat == FloatSubFormat);
        bytesPerSample = nativeFormat.BitsPerSample / 8;
        if (isFloat ? bytesPerSample != 4 : bytesPerSample is not (2 or 3 or 4))
            throw new NotSupportedException($"Unsupported output format: {nativeFormat}");
        if (nativeFormat.BlockAlign != bytesPerSample * nativeFormat.Channels)
            throw new NotSupportedException($"Unsupported container size in output format: {nativeFormat}");
    }

    public WaveFormat WaveFormat { get; }

    public int Read(byte[] buffer, int offset, int count)
    {
        int samplesWanted = count / bytesPerSample;
        samplesWanted -= samplesWanted % WaveFormat.Channels;
        if (scratch.Length < samplesWanted) scratch = new float[samplesWanted];
        int read = source.Read(scratch, 0, samplesWanted);
        int o = offset;
        for (int i = 0; i < read; i++)
        {
            float v = Math.Clamp(scratch[i], -1f, 1f);
            if (isFloat) { BitConverter.TryWriteBytes(buffer.AsSpan(o, 4), v); }
            else if (bytesPerSample == 2) { BitConverter.TryWriteBytes(buffer.AsSpan(o, 2), (short)Math.Round(v * 32767f)); }
            else if (bytesPerSample == 3)
            {
                int x = (int)Math.Round(v * 8388607f);
                buffer[o] = (byte)x; buffer[o + 1] = (byte)(x >> 8); buffer[o + 2] = (byte)(x >> 16);
            }
            else { BitConverter.TryWriteBytes(buffer.AsSpan(o, 4), (int)Math.Round(v * 2147483647.0)); }
            o += bytesPerSample;
        }
        return read * bytesPerSample;
    }
}

/// <summary>
/// Adaptive jitter buffer between the cable capture and the render callback. VB-CABLE delivers
/// packets in bursts, so a fixed 20 ms queue underran several times per second (each underrun
/// played zeros = audible gap). On underrun it re-primes to a slightly larger target (+10 ms,
/// up to 200 ms) instead of stuttering; it trims (dropping the oldest audio) only when the queue
/// grows well past the target, so clock drift cannot build up delay.
/// </summary>
internal sealed class JitterBuffer : IWaveProvider
{
    private readonly BufferedWaveProvider source;
    private readonly int maxTargetMs;
    private byte[] scratch = Array.Empty<byte>();
    private bool priming = true;
    private long underruns;
    private int targetMs;

    public JitterBuffer(BufferedWaveProvider source, int bufferMilliseconds, int maxTargetMilliseconds = 200)
    {
        this.source = source;
        source.ReadFully = false;
        targetMs = Math.Clamp(bufferMilliseconds * 2, 30, maxTargetMilliseconds);
        maxTargetMs = maxTargetMilliseconds;
    }

    public WaveFormat WaveFormat => source.WaveFormat;
    public long Underruns => Interlocked.Read(ref underruns);
    public int TargetMilliseconds => Volatile.Read(ref targetMs);
    private int TargetBytes => source.WaveFormat.ConvertLatencyToByteSize(TargetMilliseconds);

    public int Read(byte[] buffer, int offset, int count)
    {
        if (priming)
        {
            if (source.BufferedBytes < TargetBytes)
            {
                Array.Clear(buffer, offset, count);
                return count; // keep the render stream alive; never return 0 (end of stream)
            }
            priming = false;
        }
        int read = source.Read(buffer, offset, count);
        if (read < count)
        {
            Array.Clear(buffer, offset + read, count - read);
            Interlocked.Increment(ref underruns);
            Volatile.Write(ref targetMs, Math.Min(maxTargetMs, TargetMilliseconds + 10));
            priming = true;
        }
        return count;
    }

    /// <summary>Called by the capture thread before adding a packet. Returns true when audio was dropped.</summary>
    public bool TrimBeforeAdd(int incomingBytes)
    {
        int target = TargetBytes;
        int ceiling = target + Math.Max(target, source.WaveFormat.ConvertLatencyToByteSize(60));
        int queued = source.BufferedBytes + incomingBytes;
        if (queued <= ceiling) return false;
        int excess = queued - target;
        excess -= excess % source.WaveFormat.BlockAlign;
        excess = Math.Min(excess, source.BufferedBytes);
        if (excess <= 0) return false;
        if (scratch.Length < excess) scratch = new byte[excess];
        source.Read(scratch, 0, excess);
        return true;
    }
}

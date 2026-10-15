using System.Text.Json;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

// Acceptance probe: plays a tone into the game endpoint and measures loopback on the
// physical output, so "audio flows through the SonicScout chain" is measured, not assumed.
// Usage: E2EProbe --game <render name fragment> --output <render name fragment> [--seconds 6] [--freq 1000]
//        E2EProbe --list
string? Arg(string name) { int i = Array.IndexOf(args, name); return i >= 0 && i + 1 < args.Length ? args[i + 1] : null; }
using var enumerator = new MMDeviceEnumerator();
var renders = enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active).ToList();
if (args.Contains("--list"))
{
    foreach (var d in renders) Console.WriteLine($"{d.FriendlyName} | {d.ID} | ch={d.AudioClient.MixFormat.Channels}");
    return 0;
}
string gameName = Arg("--game") ?? "SonicScout2.0";
string outName = Arg("--output") ?? "Speakers";
int seconds = int.Parse(Arg("--seconds") ?? "6");
float freq = float.Parse(Arg("--freq") ?? "1000");
MMDevice? Find(string fragment) => renders.FirstOrDefault(d => d.FriendlyName.Equals(fragment, StringComparison.OrdinalIgnoreCase))
    ?? renders.FirstOrDefault(d => d.FriendlyName.StartsWith(fragment + " (", StringComparison.OrdinalIgnoreCase))
    ?? renders.FirstOrDefault(d => d.FriendlyName.Contains(fragment, StringComparison.OrdinalIgnoreCase));
var game = Find(gameName); var output = Find(outName);
if (game is null || output is null)
{
    Console.WriteLine(JsonSerializer.Serialize(new { ok = false, error = $"device not found game={game?.FriendlyName} output={output?.FriendlyName}", devices = renders.Select(d => d.FriendlyName) }));
    return 3;
}

double sumSq = 0; long n = 0; float peak = 0; long silentBefore = 0;
var loop = new WasapiLoopbackCapture(output);
var fmt = loop.WaveFormat;
bool tonePlaying = false;
loop.DataAvailable += (_, e) =>
{
    if (!tonePlaying) { silentBefore += e.BytesRecorded; return; }
    if (fmt.Encoding == WaveFormatEncoding.IeeeFloat || (fmt is WaveFormatExtensible && fmt.BitsPerSample == 32))
    {
        for (int i = 0; i + 4 <= e.BytesRecorded; i += 4)
        {
            float v = BitConverter.ToSingle(e.Buffer, i);
            sumSq += v * v; n++; peak = Math.Max(peak, Math.Abs(v));
        }
    }
    else if (fmt.BitsPerSample == 16)
    {
        for (int i = 0; i + 2 <= e.BytesRecorded; i += 2)
        {
            float v = BitConverter.ToInt16(e.Buffer, i) / 32768f;
            sumSq += v * v; n++; peak = Math.Max(peak, Math.Abs(v));
        }
    }
};
loop.StartRecording();
Thread.Sleep(500);
var tone = new SignalGenerator(48000, 2) { Frequency = freq, Gain = 0.25, Type = SignalGeneratorType.Sin };
using var player = new WasapiOut(game, AudioClientShareMode.Shared, true, 50);
player.Init(tone.ToWaveProvider());
tonePlaying = true;
player.Play();
Thread.Sleep(seconds * 1000);
player.Stop();
loop.StopRecording();
Thread.Sleep(300);
double rms = n > 0 ? Math.Sqrt(sumSq / n) : 0;
double dbfs = rms > 0 ? 20 * Math.Log10(rms) : -200;
bool ok = rms > 0.001;
Console.WriteLine(JsonSerializer.Serialize(new { ok, game = game.FriendlyName, output = output.FriendlyName, format = fmt.ToString(), samples = n, rms, dbfs, peak }));
return ok ? 0 : 1;

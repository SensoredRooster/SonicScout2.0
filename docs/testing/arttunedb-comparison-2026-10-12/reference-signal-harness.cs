using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using System.Text.Json;
using System.Runtime.InteropServices;

using var devices = new MMDeviceEnumerator();
using var input = devices.GetDevice("{0.0.0.00000000}.{70e761e7-0e9c-4877-87e9-5678367764d6}");
using var cable = devices.GetDevice("{0.0.1.00000000}.{04680202-ba5c-4e78-9d37-e151d68c6c4e}");
using var speakers = devices.GetDevice("{0.0.0.00000000}.{53aac8e0-0949-4729-b54f-b828fc8e946d}");
using var cableCapture = new WasapiCapture(cable);
using var speakerCapture = new WasapiLoopbackCapture(speakers);
double cablePeak = 0, speakerPeak = 0;
long cableBytes = 0, speakerBytes = 0;
double Peak(byte[] buffer, int length) { double peak = 0; for(int i=0;i+4<=length;i+=4) { var value = BitConverter.ToSingle(buffer,i); if(float.IsFinite(value)) peak = Math.Max(peak,Math.Abs(value)); } return peak; }
cableCapture.DataAvailable += (_,e) => { cablePeak = Math.Max(cablePeak,Peak(e.Buffer,e.BytesRecorded)); cableBytes += e.BytesRecorded; };
speakerCapture.DataAvailable += (_,e) => { speakerPeak = Math.Max(speakerPeak,Peak(e.Buffer,e.BytesRecorded)); speakerBytes += e.BytesRecorded; };
Console.WriteLine($"input={input.AudioClient.MixFormat}; cable={cableCapture.WaveFormat}; speakers={speakerCapture.WaveFormat}");
if(cableCapture.WaveFormat.Encoding != WaveFormatEncoding.IeeeFloat && !(cableCapture.WaveFormat is WaveFormatExtensible c && c.SubFormat == new Guid("00000003-0000-0010-8000-00aa00389b71"))) throw new Exception("Capture measurement requires float format");
using var converter = new MediaFoundationResampler(new QuietTone(), input.AudioClient.MixFormat) { ResamplerQuality = 60 };
using var playback = new WasapiOut(input,AudioClientShareMode.Shared,true,50);
playback.Init(converter);
cableCapture.StartRecording(); speakerCapture.StartRecording(); playback.Play();
Thread.Sleep(10000);
playback.Stop(); Thread.Sleep(1000); cableCapture.StopRecording(); speakerCapture.StopRecording();
var result = JsonSerializer.Serialize(new { cablePeak, speakerPeak, cableBytes, speakerBytes, signalDetected = cablePeak > 0.000001 && speakerPeak > 0.000001 });
Console.WriteLine(result);
File.WriteAllText("C:\\QA\\reference-signal-result.json",result);

class QuietTone : IWaveProvider {
 public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(48000,16);
 long frame;
 public int Read(byte[] buffer,int offset,int count) { int frames=count/64; Array.Clear(buffer,offset,count); for(int n=0;n<frames;n++,frame++) { float value=(float)(0.01*Math.Sin(2*Math.PI*440*frame/48000)); for(int channel=0;channel<2;channel++) BitConverter.GetBytes(value).CopyTo(buffer,offset+n*64+channel*4); } return frames*64; }
}


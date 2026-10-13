using NAudio.CoreAudioApi;
using NAudio.Wave;
using SonicScout.SonicPass;

class Regression
{
 static int Main(string[] args)
 {
  foreach(int channels in new[]{2,8,16}) foreach(int side in new[]{0,1})
  {
   var provider=new StereoOutputSampleProvider(new Impulse(side,2),channels);
   var samples=Enumerable.Repeat(9f,channels+4).ToArray();
   Check(provider.Read(samples,2,channels)==channels,"complete frame");
   for(int c=0;c<channels;c++) Check(samples[c+2]==(c==side?1f:0f),$"stereo side {side}, output {channels}, channel {c}");
   Check(samples[0]==9 && samples[^1]==9,"offset bounds");
  }
  try { _=new StereoOutputSampleProvider(new Impulse(1,8),2); throw new Exception("multichannel input accepted"); } catch(ArgumentException){}
  Check(SonicPassOptions.Parse([]).BufferMilliseconds==20,"default buffer");
  Check(DeviceResolver.ParentDeviceIdentity(@"{2}.\\?\root#media#0000#{class}\out_topo") == DeviceResolver.ParentDeviceIdentity(@"{2}.\\?\root#media#0000#{class}\in_topo"),"same driver instance, different topology filters");
  Check(DeviceResolver.ParentDeviceIdentity(@"{2}.\\?\root#media#0000#{class}\out_topo") != DeviceResolver.ParentDeviceIdentity(@"{2}.\\?\root#media#0001#{class}\in_topo"),"different cable instances remain distinct");
  Check(DeviceResolver.ParentDeviceIdentity("invalid")==string.Empty,"malformed identity rejected");
  Console.WriteLine("PASS: stereo isolation/unity gain, silent extra channels, offsets, multichannel rejection, 20 ms default.");
  if(args.Contains("--vm")) RunVm();
  return 0;
 }
 static void Check(bool value,string label) { if(!value)throw new Exception(label); }
 static void RunVm()
 {
  using var devices=new MMDeviceEnumerator();
  foreach(var device in devices.EnumerateAudioEndPoints(DataFlow.All,DeviceState.Active))
  {
   var key=new PropertyKey(new Guid("8c7ed206-3f8a-4827-b3ab-ae9e1faefc6c"),2);
   Console.WriteLine($"DEVICE: {device.ID} {device.FriendlyName}; adapter={device.DeviceTopology.GetConnector(0).ConnectedToDeviceId}; container={(device.Properties.Contains(key)?device.Properties[key].Value:"missing")}; instance={(device.Properties.Contains(PropertyKeys.PKEY_Device_InstanceId)?device.Properties[PropertyKeys.PKEY_Device_InstanceId].Value:"missing")}");
  }
  var input=DeviceResolver.ResolveInput(devices,"{0.0.0.00000000}.{70e761e7-0e9c-4877-87e9-5678367764d6}",null);
  Check(input.ID=="{0.0.1.00000000}.{04680202-ba5c-4e78-9d37-e151d68c6c4e}","pair render to correct cable capture");
  Console.WriteLine($"PASS: legacy render ID resolved to {input.FriendlyName} ({input.DataFlow}).");
  var speakers=devices.GetDevice("{0.0.0.00000000}.{53aac8e0-0949-4729-b54f-b828fc8e946d}");
  using var engine=new SonicPassEngine(input,speakers,20,0,0);
  using var loopback=new WasapiLoopbackCapture(speakers);
  double peak=0;long bytes=0;
  loopback.DataAvailable+=(_,e)=>{for(int i=0;i+4<=e.BytesRecorded;i+=4) peak=Math.Max(peak,Math.Abs(BitConverter.ToSingle(e.Buffer,i)));bytes+=e.BytesRecorded;};
  using var game=devices.GetDevice("{0.0.0.00000000}.{70e761e7-0e9c-4877-87e9-5678367764d6}");
  using var tone=new MediaFoundationResampler(new QuietTone(),game.AudioClient.MixFormat);
  using var playback=new WasapiOut(game,AudioClientShareMode.Shared,true,50);
  playback.Init(tone);
  loopback.StartRecording(); engine.Start(); playback.Play();Thread.Sleep(10000);
  playback.Stop();Thread.Sleep(500);loopback.StopRecording();engine.Stop();
  Console.WriteLine($"VM: speaker peak={peak}; bytes={bytes}; packets={engine.PacketsReceived}; trims/drops={engine.BufferDrops}; queued={engine.BufferedMilliseconds}ms; error={engine.LastError}");
  Check(peak>0.000001 && bytes>0 && engine.PacketsReceived>0 && engine.LastError is null,"SonicPass signal passage");
  Console.WriteLine("PASS: actual SonicPass engine transported the processed cable signal to speaker loopback. Quality/latency unverified.");
 }
 class Impulse(int side,int channels):ISampleProvider
 {
  public WaveFormat WaveFormat=>WaveFormat.CreateIeeeFloatWaveFormat(48000,channels);
  public int Read(float[] buffer,int offset,int count){Array.Clear(buffer,offset,count);if(count>=channels)buffer[offset+side]=1;return Math.Min(count,channels);}
 }
 class QuietTone:IWaveProvider
 {
  public WaveFormat WaveFormat {get;}=WaveFormat.CreateIeeeFloatWaveFormat(48000,16);long frame;
  public int Read(byte[] buffer,int offset,int count){int frames=count/64;Array.Clear(buffer,offset,count);for(int n=0;n<frames;n++,frame++)for(int c=0;c<2;c++)BitConverter.GetBytes((float)(0.01*Math.Sin(2*Math.PI*(c==0?440:880)*frame/48000))).CopyTo(buffer,offset+n*64+c*4);return frames*64;}
 }
}

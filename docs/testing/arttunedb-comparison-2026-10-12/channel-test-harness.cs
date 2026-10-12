using NAudio.Wave;
using SonicScout.SonicPass;
class ChannelReferenceTest {
 static int Main(){
  foreach(int channel in new[]{0,1}){var source=new Impulse(channel);var adapter=new ChannelAdaptingSampleProvider(source,2);var result=new float[2];adapter.Read(result,0,2);Console.WriteLine($"8-channel impulse on {(channel==0?"front-left":"front-right")}: stereo left={result[0]}, right={result[1]}");}
  Console.WriteLine("REPRODUCED: front-left and front-right both feed the left output and lose 12 dB amplitude in the existing grouped-average adapter. This is not a successful audio test.");return 0;
 }
 class Impulse(int channel):ISampleProvider{public WaveFormat WaveFormat=>WaveFormat.CreateIeeeFloatWaveFormat(48000,8);public int Read(float[] buffer,int offset,int count){Array.Clear(buffer,offset,count);if(count>=8)buffer[offset+channel]=1;return Math.Min(count,8);}}
}

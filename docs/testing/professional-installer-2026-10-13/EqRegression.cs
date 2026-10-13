using SonicScout;
string source="Preamp: -6.0 dB\nFilter 1: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70\nFilter 2: ON PK Fc 1000 Hz Gain -3.3 dB Q 0.57\nInclude: headphone-convolution.txt\n";
int[] frequencies=[60,150,400,1000,2500,6000,12000];
var gains=new Dictionary<string,double>{{"1000",2}};
string first=EqProfileEdits.Apply(source,gains,frequencies);
Check(first.StartsWith(source.TrimEnd()),"original correction, preamp and includes preserved");
Check(first.Contains("Filter 1004: ON PK Fc 1000 Hz Gain +2.0 dB Q 1.00"),"adjustment added separately");
gains["1000"]=-1;
string second=EqProfileEdits.Apply(first,gains,frequencies);
Check(second.StartsWith(source.TrimEnd()),"repeat edit preserves original correction");
Check(second.Split(EqProfileEdits.Begin).Length==2,"one adjustment block after repeat edit");
Check(!EqProfileEdits.Adjustments(second).Contains("Gain +2.0"),"previous adjustment replaced");
Check(EqProfileEdits.Adjustments(source)==string.Empty,"imported correction is not treated as slider offsets");
string[] endpoints=["SonicScout2.0 + (VB-Audio Virtual Cable)","SonicScout2.0 (VB-Audio Virtual Cable)"];
Check(endpoints.OrderBy(AudioRoutePreference.Rank).First()==endpoints[1],"normal cable preferred regardless of enumeration order");
Check(AudioRoutePreference.Rank("CABLE Input (VB-Audio Virtual Cable)") < AudioRoutePreference.Rank("CABLE In 16ch (VB-Audio Virtual Cable)"),"unrenamed normal cable preferred");
Console.WriteLine("PASS: headphone filters, preamp and includes preserved across repeated EQ edits; only user adjustment block replaced.");
static void Check(bool ok,string message){if(!ok)throw new Exception(message);}

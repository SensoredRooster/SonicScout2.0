using SonicScout;
using System.Text.Json;
string root = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../../"));
string target = File.ReadAllText(Path.Combine(root, "tools/SonicScoutCSharp/targets/BO7_Target_V0.txt"));
using var body = JsonDocument.Parse(GameTargetEq.BuildRequest("test", "crinacle", "711", target));
if (body.RootElement.GetProperty("target").GetProperty("frequency").GetArrayLength() < 100) throw new Exception("Target dropped");
foreach (string invalid in new[] { "GraphicEQ: 20 NaN; 100 Infinity", "GraphicEQ: 20 3; 100 4", "Include: C:\\wrong.txt", "GraphicEQ: 20 -2\nInclude: x" }) {
    try { GameTargetEq.ValidateCorrection(invalid); throw new Exception("Invalid correction accepted"); } catch (InvalidDataException) { }
}
try { GameTargetEq.BuildRequest("test", "source", "rig", "20 0\n20 NaN"); throw new Exception("Bad target accepted"); } catch (InvalidDataException) { }
using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(60) };
client.DefaultRequestHeaders.UserAgent.ParseAdd("SonicScout-qualification/2.9");
string url = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/crinacle/711%20in-ear/1Custom%20SA03/1Custom%20SA03%20ParametricEQ.txt";
string v0 = await GameTargetEq.GenerateAsync(client, "1Custom SA03", url, target);
string v3 = await GameTargetEq.GenerateAsync(client, "1Custom SA03", url, File.ReadAllText(Path.Combine(root,"tools/SonicScoutCSharp/targets/BO7_Target_V3.txt")));
if (v0 == v3 || !v0.Contains("GraphicEQ:")) throw new Exception("Distinct game targets did not change correction");
string evidence = Path.Combine(root,"docs/testing/tester-ready-2026-10-13");
File.WriteAllText(Path.Combine(evidence,"SA03-BO7-V0-generated.txt"),v0);
File.WriteAllText(Path.Combine(evidence,"SA03-BO7-V3-generated.txt"),v3);
Console.WriteLine("PASS: complete target request, malformed/boosting responses rejected, live measured-headphone solver produces distinct V0/V3 corrections with headroom.");

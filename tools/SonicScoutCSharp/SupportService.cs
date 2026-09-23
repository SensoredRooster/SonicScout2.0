using System.IO;
using System.Diagnostics;
using System.IO.Compression;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Reflection;
using System.Text;
using System.Text.Json;

namespace SonicScout;

internal static class SupportService
{
    private static readonly object Gate = new();
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(45) };
    private static readonly string Root = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "SonicScout",
        "logs");
    private static readonly string EventLog = Path.Combine(Root, "sonic-scout.jsonl");
    private static readonly string ErrorLog = Path.Combine(Root, "errors.jsonl");
    private static readonly string SessionIdValue = Guid.NewGuid().ToString("N")[..12];
    private static readonly DateTime StartedAtUtc = DateTime.UtcNow;
    private static System.Threading.Timer? heartbeatTimer;
    private static bool initialized;
    private const long MaxLogBytes = 8L * 1024 * 1024;
    private const int MaxBackups = 6;
    private const string RepositoryUrl = "https://github.com/SensoredRooster/SonicScout2.0";

    public static string SessionId => SessionIdValue;
    public static string? UploadUrl { get; set; } = Environment.GetEnvironmentVariable("SONICSCOUT_SUPPORT_UPLOAD_URL");

    public static void Initialize()
    {
        lock (Gate)
        {
            if (initialized) return;
            initialized = true;
        }
        Directory.CreateDirectory(Root);
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            try { Log("unhandled_exception", new { error = e.ExceptionObject?.ToString() ?? "unknown" }, true); } catch { }
        };
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            try { Log("unobserved_task_exception", new { error = e.Exception.ToString() }, true); } catch { }
            e.SetObserved();
        };
        AppDomain.CurrentDomain.ProcessExit += (_, _) =>
        {
            try { Log("app_stop"); } catch { }
        };
        Log("app_start", new { version = VersionString(), os = Environment.OSVersion.VersionString });
        heartbeatTimer ??= new System.Threading.Timer(_ =>
        {
            try { Log("heartbeat"); } catch { }
        }, null, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(1));
    }

    public static void Log(string eventName, object? data = null, bool error = false)
    {
        Directory.CreateDirectory(Root);
        var record = new
        {
            ts = DateTime.UtcNow.ToString("O"),
            session_id = SessionIdValue,
            level = error ? "ERROR" : "INFO",
            @event = eventName,
            data
        };
        string path = error ? ErrorLog : EventLog;
        string line = RedactText(JsonSerializer.Serialize(record));
        lock (Gate)
        {
            Rotate(path);
            File.AppendAllText(path, line + Environment.NewLine, Encoding.UTF8);
        }
    }

    public static Dictionary<string, object?> HealthSnapshot()
    {
        var root = new DriveInfo(Path.GetPathRoot(Root)!);
        return new Dictionary<string, object?>
        {
            ["app"] = "SonicScout2.0",
            ["session_id"] = SessionIdValue,
            ["started_at"] = StartedAtUtc.ToString("O"),
            ["version"] = VersionString(),
            ["os"] = Environment.OSVersion.VersionString,
            ["machine"] = Environment.MachineName,
            ["process_architecture"] = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(),
            ["dotnet"] = Environment.Version.ToString(),
            ["elevated"] = IsElevated(),
            ["free_disk_bytes"] = root.AvailableFreeSpace,
            ["base_directory"] = AppContext.BaseDirectory,
            ["support_log_directory"] = Root,
            ["upload_configured"] = !string.IsNullOrWhiteSpace(UploadUrl),
            ["naudio_present"] = File.Exists(Path.Combine(AppContext.BaseDirectory, "NAudio.dll")),
            ["setup_script_present"] = File.Exists(Path.Combine(AppContext.BaseDirectory, "setup_audio_stack.ps1")),
            ["routing_config_present"] = File.Exists(Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "SonicScout",
                "routing_configuration.json")),
            ["equalizer_apo_present"] = Directory.Exists(Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                "EqualizerAPO"))
        };
    }

    public static string CreateBundle()
    {
        Directory.CreateDirectory(Root);
        string destination = Path.Combine(Path.GetTempPath(), $"SonicScout2.0-Support-{SessionIdValue}.zip");
        if (File.Exists(destination))
        {
            File.Delete(destination);
        }

        using (ZipArchive archive = ZipFile.Open(destination, ZipArchiveMode.Create))
        {
            WriteString(archive, "diagnostics/manifest.json",
                JsonSerializer.Serialize(HealthSnapshot(), new JsonSerializerOptions { WriteIndented = true }));
            WriteString(archive, "README.txt",
                "SonicScout2.0 support bundle. Created locally after explicit user action. " +
                "No support bundle is uploaded automatically. Review the archive before sharing if desired.\r\n");

            foreach (string file in Directory.EnumerateFiles(Root))
            {
                string name = Path.GetFileName(file);
                if (!name.StartsWith("sonic-scout.jsonl", StringComparison.OrdinalIgnoreCase) &&
                    !name.StartsWith("errors.jsonl", StringComparison.OrdinalIgnoreCase) &&
                    !name.EndsWith(".log", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                try
                {
                    WriteString(archive, $"logs/{name}", RedactText(File.ReadAllText(file)));
                }
                catch { }
            }

            string routing = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "SonicScout",
                "routing_configuration.json");
            if (File.Exists(routing))
            {
                try
                {
                    string text = File.ReadAllText(routing);
                    WriteString(archive, "diagnostics/routing_configuration.json", RedactText(text));
                }
                catch { }
            }
        }

        Log("support_bundle_created", new { path = destination, size_bytes = new FileInfo(destination).Length });
        return destination;
    }

    public static async Task<(int Status, string Body)> UploadBundleAsync(CancellationToken cancellationToken = default)
    {
        string endpoint = (UploadUrl ?? string.Empty).Trim();
        if (string.IsNullOrWhiteSpace(endpoint))
        {
            throw new InvalidOperationException("SonicScout support upload endpoint is not configured.");
        }

        string bundle = CreateBundle();
        using var request = new HttpRequestMessage(HttpMethod.Post, endpoint);
        request.Headers.Add("X-SonicScout-Session", SessionIdValue);
        request.Headers.Add("X-SonicScout-Filename", Path.GetFileName(bundle));
        request.Content = new ByteArrayContent(await File.ReadAllBytesAsync(bundle, cancellationToken));
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/zip");

        using HttpResponseMessage response = await Http.SendAsync(request, cancellationToken);
        string body = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            Log("support_upload_failed", new { status = (int)response.StatusCode, body = RedactText(body) }, true);
            throw new HttpRequestException($"Support upload failed with HTTP {(int)response.StatusCode}.");
        }

        Log("support_bundle_uploaded", new { status = (int)response.StatusCode });
        return ((int)response.StatusCode, body);
    }

    public static void OpenLogsFolder()
    {
        Directory.CreateDirectory(Root);
        Process.Start(new ProcessStartInfo("explorer.exe", Root) { UseShellExecute = true });
    }

    public static void OpenRepository()
    {
        Process.Start(new ProcessStartInfo(RepositoryUrl) { UseShellExecute = true });
    }

    public static void ReportIssue()
    {
        string title = Uri.EscapeDataString("SonicScout2.0 support issue");
        string body = Uri.EscapeDataString($"Session ID: {SessionIdValue}\nStarted: {StartedAtUtc:O}\n\nDescribe the issue here.");
        Process.Start(new ProcessStartInfo($"{RepositoryUrl}/issues/new?title={title}&body={body}") { UseShellExecute = true });
    }

    private static void WriteString(ZipArchive archive, string path, string text)
    {
        ZipArchiveEntry entry = archive.CreateEntry(path, CompressionLevel.Optimal);
        using StreamWriter writer = new(entry.Open(), Encoding.UTF8);
        writer.Write(text);
    }

    private static string VersionString()
    {
        return Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "unknown";
    }

    private static bool IsElevated()
    {
        try
        {
            var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
            var principal = new System.Security.Principal.WindowsPrincipal(identity);
            return principal.IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
        }
        catch
        {
            return false;
        }
    }

    private static string RedactText(string input)
    {
        string result = input;
        foreach (string key in new[] { "token", "secret", "password", "passwd", "cookie", "authorization", "credential", "api_key", "api-key" })
        {
            result = System.Text.RegularExpressions.Regex.Replace(
                result,
                $"(?i)(\"?{System.Text.RegularExpressions.Regex.Escape(key)}\"?\\s*[:=]\\s*[\"']?)([^\"',}\\s]+)",
                "$1[REDACTED]");
        }

        result = System.Text.RegularExpressions.Regex.Replace(
            result,
            @"(?i)Bearer\s+[A-Za-z0-9._~+/-]+=*",
            "Bearer [REDACTED]");
        result = System.Text.RegularExpressions.Regex.Replace(
            result,
            @"(?i)([?&](?:code|token|access_token|refresh_token|client_secret|state|password)=)[^&#\s]+",
            "$1[REDACTED]");
        result = System.Text.RegularExpressions.Regex.Replace(
            result,
            @"(?<![A-Za-z0-9])[A-Za-z0-9_-]{56,}(?![A-Za-z0-9])",
            "[REDACTED]");
        return result;
    }

    private static void Rotate(string path)
    {
        if (!File.Exists(path) || new FileInfo(path).Length < MaxLogBytes)
        {
            return;
        }
        for (int i = MaxBackups - 1; i >= 1; i--)
        {
            string src = path + "." + i;
            string dst = path + "." + (i + 1);
            if (!File.Exists(src)) continue;
            if (i + 1 >= MaxBackups && File.Exists(dst)) File.Delete(dst);
            File.Move(src, dst, true);
        }
        File.Move(path, path + ".1", true);
    }
}

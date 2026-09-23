using System.Diagnostics;
using System.IO.Compression;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace SonicScout;

internal static class SupportDiagnostics
{
    public const string RepositoryUrl = "https://github.com/SensoredRooster/SonicScout2.0";
    public static readonly string SessionId = Guid.NewGuid().ToString("N")[..12];
    public static readonly DateTime StartedAtUtc = DateTime.UtcNow;
    private static readonly object Sync = new();
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };
    private static System.Threading.Timer? heartbeatTimer;

    public static string LogDirectory
    {
        get
        {
            string root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string path = Path.Combine(root, "SonicScout2.0", "logs");
            Directory.CreateDirectory(path);
            return path;
        }
    }

    public static void Initialize()
    {
        Log("app_support_initialized", new { Health = HealthSnapshot() });
        heartbeatTimer ??= new System.Threading.Timer(_ =>
        {
            try { Log("heartbeat"); } catch { }
        }, null, TimeSpan.Zero, TimeSpan.FromSeconds(1));

        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            Log("unhandled_exception", new { Error = e.ExceptionObject?.ToString() ?? "unknown" }, "ERROR");
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            Log("unobserved_task_exception", new { Error = e.Exception.ToString() }, "ERROR");
            e.SetObserved();
        };
    }

    public static Dictionary<string, object?> HealthSnapshot() => new()
    {
        ["app"] = "SonicScout2.0",
        ["session_id"] = SessionId,
        ["started_at"] = StartedAtUtc.ToString("O"),
        ["os"] = Environment.OSVersion.ToString(),
        ["framework"] = Environment.Version.ToString(),
        ["machine"] = Environment.MachineName,
        ["is_64_bit_os"] = Environment.Is64BitOperatingSystem,
        ["is_64_bit_process"] = Environment.Is64BitProcess,
        ["base_directory"] = AppContext.BaseDirectory,
        ["free_disk_bytes"] = GetFreeDiskBytes(),
        ["repository"] = RepositoryUrl
    };

    public static void Log(string eventName, object? data = null, string level = "INFO")
    {
        var record = new Dictionary<string, object?>
        {
            ["ts"] = DateTime.UtcNow.ToString("O"),
            ["session_id"] = SessionId,
            ["level"] = level,
            ["event"] = eventName,
            ["data"] = data
        };

        string line = Redact(JsonSerializer.Serialize(record));
        string file = Path.Combine(LogDirectory, level is "ERROR" or "CRITICAL" ? "errors.jsonl" : "sonicscout.jsonl");
        lock (Sync)
        {
            Rotate(file, level is "ERROR" or "CRITICAL" ? 5 * 1024 * 1024 : 10 * 1024 * 1024, 6);
            File.AppendAllText(file, line + Environment.NewLine, Encoding.UTF8);
        }
    }

    public static string CreateSupportBundle()
    {
        string path = Path.Combine(Path.GetTempPath(), $"SonicScout2.0-Support-{SessionId}.zip");
        if (File.Exists(path)) File.Delete(path);

        using ZipArchive archive = ZipFile.Open(path, ZipArchiveMode.Create);
        AddText(archive, "diagnostics/manifest.json", JsonSerializer.Serialize(HealthSnapshot(), new JsonSerializerOptions { WriteIndented = true }));
        AddText(archive, "README.txt",
            "SonicScout2.0 support bundle. Created only after user action. " +
            "Review before sharing if desired. Passwords, API tokens, cookies, and authorization values are redacted when detected.\r\n");

        foreach (string file in Directory.EnumerateFiles(LogDirectory, "*.*", SearchOption.TopDirectoryOnly))
        {
            if (!file.EndsWith(".jsonl", StringComparison.OrdinalIgnoreCase) &&
                !Regex.IsMatch(file, @"\.jsonl\.\d+$", RegexOptions.IgnoreCase) &&
                !file.EndsWith(".log", StringComparison.OrdinalIgnoreCase))
                continue;

            AddText(archive, $"logs/{Path.GetFileName(file)}", Redact(File.ReadAllText(file)));
        }

        Log("support_bundle_created", new { Path = path, SizeBytes = new FileInfo(path).Length });
        return path;
    }

    public static async Task SendSupportBundleAsync()
    {
        string endpoint = Environment.GetEnvironmentVariable("SONICSCOUT_SUPPORT_UPLOAD_URL") ?? "";
        if (string.IsNullOrWhiteSpace(endpoint))
            throw new InvalidOperationException("SonicScout support upload endpoint is not configured.");

        string bundle = CreateSupportBundle();
        using ByteArrayContent content = new(await File.ReadAllBytesAsync(bundle));
        content.Headers.ContentType = new("application/zip");
        using HttpRequestMessage request = new(HttpMethod.Post, endpoint);
        request.Content = content;
        request.Headers.Add("X-SonicScout-Session", SessionId);
        request.Headers.Add("X-SonicScout-Filename", Path.GetFileName(bundle));

        using HttpResponseMessage response = await Http.SendAsync(request);
        string body = await response.Content.ReadAsStringAsync();
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"Support upload failed ({(int)response.StatusCode}): {body}");
        Log("support_bundle_uploaded", new { Status = (int)response.StatusCode });
    }

    public static void OpenLogsFolder() => Process.Start(new ProcessStartInfo("explorer.exe", LogDirectory) { UseShellExecute = true });
    public static void OpenRepository() => Process.Start(new ProcessStartInfo(RepositoryUrl) { UseShellExecute = true });

    public static void ReportIssue()
    {
        string title = Uri.EscapeDataString("SonicScout2.0 support issue");
        string body = Uri.EscapeDataString($"Session ID: {SessionId}\nStarted: {StartedAtUtc:O}\n\nDescribe the issue here.");
        Process.Start(new ProcessStartInfo($"{RepositoryUrl}/issues/new?title={title}&body={body}") { UseShellExecute = true });
    }

    private static long GetFreeDiskBytes()
    {
        try
        {
            string? root = Path.GetPathRoot(LogDirectory);
            return root is null ? 0 : new DriveInfo(root).AvailableFreeSpace;
        }
        catch { return 0; }
    }

    private static void AddText(ZipArchive archive, string name, string text)
    {
        ZipArchiveEntry entry = archive.CreateEntry(name, CompressionLevel.Optimal);
        using StreamWriter writer = new(entry.Open(), Encoding.UTF8);
        writer.Write(text);
    }

    private static void Rotate(string path, long maxBytes, int backups)
    {
        if (!File.Exists(path) || new FileInfo(path).Length < maxBytes) return;
        for (int i = backups - 1; i >= 1; i--)
        {
            string src = path + "." + i;
            string dst = path + "." + (i + 1);
            if (File.Exists(dst)) File.Delete(dst);
            if (File.Exists(src)) File.Move(src, dst);
        }
        File.Move(path, path + ".1", true);
    }

    private static string Redact(string value)
    {
        string result = Regex.Replace(value,
            @"(?i)(token|secret|password|passwd|authorization|cookie|credential|api[_-]?key)\s*["":=]+\s*[""]?[^"",\s}]+",
            "$1:[REDACTED]");
        result = Regex.Replace(result, @"(?i)Bearer\s+[A-Za-z0-9._~+/-]+=*", "Bearer [REDACTED]");
        return result;
    }
}

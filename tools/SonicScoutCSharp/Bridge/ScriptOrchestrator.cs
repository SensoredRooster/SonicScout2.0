using System.Collections.Concurrent;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace SonicScout.Bridge;

public sealed class ScriptOrchestrator : IScriptEngineBridge
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    private readonly IScoutAudioController audioController;
    private readonly string stateRoot;
    private readonly ConcurrentDictionary<string, RunningExecution> runningExecutions = new(StringComparer.OrdinalIgnoreCase);

    public event EventHandler<ScriptStateChangedEventArgs>? StateChanged;
    public event EventHandler<ScriptLogEventArgs>? LogReceived;

    public ScriptOrchestrator(IScoutAudioController audioController, string stateRoot)
    {
        this.audioController = audioController ?? throw new ArgumentNullException(nameof(audioController));
        if (string.IsNullOrWhiteSpace(stateRoot) || !Path.IsPathRooted(stateRoot))
        {
            throw new ArgumentException("stateRoot must be an absolute path.", nameof(stateRoot));
        }

        this.stateRoot = stateRoot;
        Directory.CreateDirectory(this.stateRoot);
    }

    public Task<ScriptDiscoveryResult> DiscoverScriptsAsync(string workspaceRoot, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(workspaceRoot) || !Path.IsPathRooted(workspaceRoot))
        {
            throw new ArgumentException("workspaceRoot must be an absolute path.", nameof(workspaceRoot));
        }

        cancellationToken.ThrowIfCancellationRequested();
        if (!Directory.Exists(workspaceRoot))
        {
            throw new DirectoryNotFoundException($"Workspace not found: {workspaceRoot}");
        }

        List<ScriptDescriptor> scripts = new();
        foreach (string folderName in new[] { "powershell", "scripts", "installers" })
        {
            string candidateDir = Path.Combine(workspaceRoot, folderName);
            if (!Directory.Exists(candidateDir))
            {
                continue;
            }

            foreach (string path in Directory.EnumerateFiles(candidateDir, "*.ps1", SearchOption.AllDirectories))
            {
                cancellationToken.ThrowIfCancellationRequested();
                string key = Path.GetFileNameWithoutExtension(path);
                scripts.Add(new ScriptDescriptor(key, key, Path.GetFullPath(path)));
            }

            foreach (string path in Directory.EnumerateFiles(candidateDir, "*.bat", SearchOption.AllDirectories))
            {
                cancellationToken.ThrowIfCancellationRequested();
                string key = Path.GetFileNameWithoutExtension(path);
                scripts.Add(new ScriptDescriptor(key, key, Path.GetFullPath(path)));
            }
        }

        return Task.FromResult(new ScriptDiscoveryResult(Path.GetFullPath(workspaceRoot), scripts));
    }

    public Task<string> QueueExecutionAsync(ScriptExecutionRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        cancellationToken.ThrowIfCancellationRequested();

        string scriptPath = ValidateScriptPath(request.ScriptPath);
        string workingDirectory = ValidateWorkingDirectory(request.WorkingDirectory);

        string executionId = Guid.NewGuid().ToString("N");
        string payloadPath = WritePayloadFile(executionId, request.Payload);
        IReadOnlyList<string> additionalArguments = request.AdditionalArguments ?? Array.Empty<string>();
        TaskCompletionSource<ScriptExecutionResult> completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        RunningExecution execution = new(
            executionId,
            request.ScriptKey,
            scriptPath,
            workingDirectory,
            payloadPath,
            additionalArguments,
            completion,
            request.Timeout);

        if (!runningExecutions.TryAdd(executionId, execution))
        {
            throw new InvalidOperationException($"Execution already exists: {executionId}");
        }

        PublishState(executionId, request.ScriptKey, ScriptExecutionState.Queued, null, "Execution queued.");
        _ = Task.Run(() => RunExecutionAsync(execution), CancellationToken.None);
        return Task.FromResult(executionId);
    }

    public async Task<ScriptExecutionResult> WaitForCompletionAsync(string executionId, CancellationToken cancellationToken)
    {
        if (!runningExecutions.TryGetValue(executionId, out RunningExecution? execution))
        {
            throw new KeyNotFoundException($"Unknown execution id: {executionId}");
        }

        using CancellationTokenRegistration registration = cancellationToken.Register(() => execution.Completion.TrySetCanceled(cancellationToken));
        return await execution.Completion.Task.ConfigureAwait(false);
    }

    public bool TryCancel(string executionId)
    {
        if (!runningExecutions.TryGetValue(executionId, out RunningExecution? execution))
        {
            return false;
        }

        Process? process = execution.Process;
        if (process is null || process.HasExited)
        {
            return false;
        }

        try
        {
            process.Kill(entireProcessTree: true);
            PublishState(executionId, execution.ScriptKey, ScriptExecutionState.Cancelled, null, "Execution cancelled.");
            return true;
        }
        catch (InvalidOperationException)
        {
            return false;
        }
    }

    private async Task RunExecutionAsync(RunningExecution execution)
    {
        DateTimeOffset startedAt = DateTimeOffset.UtcNow;
        List<string> logs = new(capacity: 128);
        int? exitCode = null;
        ScriptExecutionState state = ScriptExecutionState.Failed;
        string? errorMessage = null;

        try
        {
            ProcessStartInfo startInfo = BuildStartInfo(execution.ScriptPath, execution.WorkingDirectory, execution.AdditionalArguments);
            startInfo.Environment["SONICSCOUT_EXECUTION_ID"] = execution.ExecutionId;
            startInfo.Environment["SONICSCOUT_PAYLOAD_PATH"] = execution.PayloadPath;

            Process process = new()
            {
                StartInfo = startInfo,
                EnableRaisingEvents = true
            };
            process.OutputDataReceived += (_, args) =>
            {
                if (string.IsNullOrWhiteSpace(args.Data))
                {
                    return;
                }

                AppendLog(logs, $"[OUT] {args.Data}");
                PublishLog(execution.ExecutionId, execution.ScriptKey, args.Data, isError: false);
            };
            process.ErrorDataReceived += (_, args) =>
            {
                if (string.IsNullOrWhiteSpace(args.Data))
                {
                    return;
                }

                AppendLog(logs, $"[ERR] {args.Data}");
                PublishLog(execution.ExecutionId, execution.ScriptKey, args.Data, isError: true);
            };

            if (!process.Start())
            {
                throw new InvalidOperationException($"Failed to start script process: {execution.ScriptPath}");
            }

            execution.Process = process;
            PublishState(execution.ExecutionId, execution.ScriptKey, ScriptExecutionState.Running, null, "Execution started.");
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();

            using CancellationTokenSource timeoutSource = execution.Timeout.HasValue
                ? new CancellationTokenSource(execution.Timeout.Value)
                : new CancellationTokenSource();
            try
            {
                await process.WaitForExitAsync(timeoutSource.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (execution.Timeout.HasValue && timeoutSource.IsCancellationRequested)
            {
                state = ScriptExecutionState.TimedOut;
                errorMessage = $"Execution exceeded timeout ({execution.Timeout.Value}).";
                TryCancel(execution.ExecutionId);
            }

            if (state != ScriptExecutionState.TimedOut)
            {
                exitCode = process.ExitCode;
                if (exitCode == 0)
                {
                    state = ScriptExecutionState.Succeeded;
                    await audioController.HotReloadPipelineAsync(
                        $"Script {execution.ScriptKey} completed successfully.",
                        CancellationToken.None).ConfigureAwait(false);
                }
                else
                {
                    state = ScriptExecutionState.Failed;
                    errorMessage = $"Script exited with code {exitCode}.";
                    await audioController.ActivateBypassModeAsync(
                        $"Script {execution.ScriptKey} failed (exit {exitCode}).",
                        CancellationToken.None).ConfigureAwait(false);
                }
            }
        }
        catch (FileNotFoundException ex)
        {
            state = ScriptExecutionState.Failed;
            errorMessage = ex.Message;
            await audioController.ActivateBypassModeAsync(
                $"Missing script dependency while running {execution.ScriptKey}.",
                CancellationToken.None).ConfigureAwait(false);
        }
        catch (DirectoryNotFoundException ex)
        {
            state = ScriptExecutionState.Failed;
            errorMessage = ex.Message;
            await audioController.ActivateBypassModeAsync(
                $"Missing directory while running {execution.ScriptKey}.",
                CancellationToken.None).ConfigureAwait(false);
        }
        catch (UnauthorizedAccessException ex)
        {
            state = ScriptExecutionState.Failed;
            errorMessage = ex.Message;
            await audioController.ActivateBypassModeAsync(
                $"Access denied while running {execution.ScriptKey}.",
                CancellationToken.None).ConfigureAwait(false);
        }
        catch (InvalidOperationException ex)
        {
            state = ScriptExecutionState.Failed;
            errorMessage = ex.Message;
            await audioController.ActivateBypassModeAsync(
                $"Script execution initialization failed for {execution.ScriptKey}.",
                CancellationToken.None).ConfigureAwait(false);
        }
        finally
        {
            DateTimeOffset finishedAt = DateTimeOffset.UtcNow;
            ScriptExecutionResult result = new(
                execution.ExecutionId,
                execution.ScriptKey,
                state,
                exitCode,
                startedAt,
                finishedAt,
                execution.PayloadPath,
                logs.ToArray(),
                errorMessage);

            string completionMessage = errorMessage ?? "Execution finished.";
            PublishState(execution.ExecutionId, execution.ScriptKey, state, exitCode, completionMessage);
            execution.Completion.TrySetResult(result);
            runningExecutions.TryRemove(execution.ExecutionId, out _);
            execution.Process?.Dispose();
        }
    }

    private static ProcessStartInfo BuildStartInfo(string scriptPath, string workingDirectory, IReadOnlyList<string> additionalArguments)
    {
        string extension = Path.GetExtension(scriptPath);
        if (extension.Equals(".ps1", StringComparison.OrdinalIgnoreCase))
        {
            ProcessStartInfo startInfo = new()
            {
                FileName = "powershell.exe",
                WorkingDirectory = workingDirectory,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                ArgumentList =
                {
                    "-NoProfile",
                    "-ExecutionPolicy", "Bypass",
                    "-File", scriptPath
                }
            };
            foreach (string argument in additionalArguments)
            {
                startInfo.ArgumentList.Add(argument);
            }
            return startInfo;
        }

        if (extension.Equals(".bat", StringComparison.OrdinalIgnoreCase))
        {
            ProcessStartInfo startInfo = new()
            {
                FileName = "cmd.exe",
                WorkingDirectory = workingDirectory,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                ArgumentList =
                {
                    "/c",
                    scriptPath
                }
            };
            foreach (string argument in additionalArguments)
            {
                startInfo.ArgumentList.Add(argument);
            }
            return startInfo;
        }

        throw new InvalidOperationException($"Unsupported script extension '{extension}' for {scriptPath}");
    }

    private string WritePayloadFile(string executionId, ScriptEnginePayload payload)
    {
        string requestDirectory = Path.Combine(stateRoot, "bridge", "requests");
        Directory.CreateDirectory(requestDirectory);

        string payloadPath = Path.Combine(requestDirectory, $"{executionId}.json");
        string json = JsonSerializer.Serialize(payload, JsonOptions);
        File.WriteAllText(payloadPath, json);
        return payloadPath;
    }

    private static string ValidateScriptPath(string scriptPath)
    {
        if (string.IsNullOrWhiteSpace(scriptPath) || !Path.IsPathRooted(scriptPath))
        {
            throw new ArgumentException("ScriptPath must be an absolute path.", nameof(scriptPath));
        }

        string fullPath = Path.GetFullPath(scriptPath);
        if (!File.Exists(fullPath))
        {
            throw new FileNotFoundException("Script file not found.", fullPath);
        }

        return fullPath;
    }

    private static string ValidateWorkingDirectory(string workingDirectory)
    {
        if (string.IsNullOrWhiteSpace(workingDirectory) || !Path.IsPathRooted(workingDirectory))
        {
            throw new ArgumentException("WorkingDirectory must be an absolute path.", nameof(workingDirectory));
        }

        string fullPath = Path.GetFullPath(workingDirectory);
        if (!Directory.Exists(fullPath))
        {
            throw new DirectoryNotFoundException($"Working directory not found: {fullPath}");
        }

        return fullPath;
    }

    private static void AppendLog(List<string> logs, string message)
    {
        if (logs.Count >= 500)
        {
            logs.RemoveAt(0);
        }

        logs.Add(message);
    }

    private void PublishState(string executionId, string scriptKey, ScriptExecutionState state, int? exitCode, string? message)
    {
        StateChanged?.Invoke(this, new ScriptStateChangedEventArgs
        {
            ExecutionId = executionId,
            ScriptKey = scriptKey,
            State = state,
            ExitCode = exitCode,
            Message = message
        });
    }

    private void PublishLog(string executionId, string scriptKey, string message, bool isError)
    {
        LogReceived?.Invoke(this, new ScriptLogEventArgs
        {
            ExecutionId = executionId,
            ScriptKey = scriptKey,
            Message = message,
            IsError = isError,
            OccurredAtUtc = DateTimeOffset.UtcNow
        });
    }

    private sealed record RunningExecution(
        string ExecutionId,
        string ScriptKey,
        string ScriptPath,
        string WorkingDirectory,
        string PayloadPath,
        IReadOnlyList<string> AdditionalArguments,
        TaskCompletionSource<ScriptExecutionResult> Completion,
        TimeSpan? Timeout)
    {
        public Process? Process { get; set; }
    }
}

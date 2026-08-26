using System;
using System.Threading;
using System.Threading.Tasks;

namespace SonicScout.Bridge;

public interface IScriptEngineBridge
{
    event EventHandler<ScriptStateChangedEventArgs>? StateChanged;
    event EventHandler<ScriptLogEventArgs>? LogReceived;

    Task<ScriptDiscoveryResult> DiscoverScriptsAsync(string workspaceRoot, CancellationToken cancellationToken);
    Task<string> QueueExecutionAsync(ScriptExecutionRequest request, CancellationToken cancellationToken);
    Task<ScriptExecutionResult> WaitForCompletionAsync(string executionId, CancellationToken cancellationToken);
    bool TryCancel(string executionId);
}

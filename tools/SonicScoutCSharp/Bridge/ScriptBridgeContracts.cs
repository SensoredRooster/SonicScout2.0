using System;
using System.Collections.Generic;

namespace SonicScout.Bridge;

public enum ScriptExecutionState
{
    Queued,
    Running,
    Succeeded,
    Failed,
    Cancelled,
    TimedOut
}

public sealed record UiAudioProfileSnapshot(
    string? HeadphoneProfile,
    string? ActiveCurve,
    IReadOnlyDictionary<string, double> SliderPositions,
    IReadOnlyDictionary<string, string>? Metadata = null);

public sealed record ScriptEnginePayload(
    string ProfileId,
    UiAudioProfileSnapshot Audio,
    string RequestedBy,
    DateTimeOffset RequestedAtUtc);

public sealed record ScriptExecutionRequest(
    string ScriptKey,
    string ScriptPath,
    string WorkingDirectory,
    ScriptEnginePayload Payload,
    IReadOnlyList<string>? AdditionalArguments = null,
    TimeSpan? Timeout = null);

public sealed record ScriptExecutionResult(
    string ExecutionId,
    string ScriptKey,
    ScriptExecutionState State,
    int? ExitCode,
    DateTimeOffset StartedAtUtc,
    DateTimeOffset FinishedAtUtc,
    string PayloadPath,
    string[] Logs,
    string? ErrorMessage);

public sealed record ScriptDescriptor(
    string ScriptKey,
    string DisplayName,
    string ScriptPath);

public sealed record ScriptDiscoveryResult(
    string WorkspaceRoot,
    IReadOnlyList<ScriptDescriptor> Scripts);

public sealed class ScriptStateChangedEventArgs : EventArgs
{
    public required string ExecutionId { get; init; }
    public required string ScriptKey { get; init; }
    public required ScriptExecutionState State { get; init; }
    public int? ExitCode { get; init; }
    public string? Message { get; init; }
}

public sealed class ScriptLogEventArgs : EventArgs
{
    public required string ExecutionId { get; init; }
    public required string ScriptKey { get; init; }
    public required bool IsError { get; init; }
    public required string Message { get; init; }
    public required DateTimeOffset OccurredAtUtc { get; init; }
}

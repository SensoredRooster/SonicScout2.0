using System;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;

namespace SonicScout.Bridge;

public sealed class QueuedScoutAudioController : IScoutAudioController, IAsyncDisposable
{
    private readonly Func<string, CancellationToken, Task> reloadAction;
    private readonly Func<string, CancellationToken, Task> bypassAction;
    private readonly Channel<AudioCommand> commandQueue;
    private readonly CancellationTokenSource shutdownSource = new();
    private readonly Task processorTask;
    private int hardwareMutationActive;

    public QueuedScoutAudioController(
        Func<string, CancellationToken, Task> reloadAction,
        Func<string, CancellationToken, Task> bypassAction)
    {
        this.reloadAction = reloadAction ?? throw new ArgumentNullException(nameof(reloadAction));
        this.bypassAction = bypassAction ?? throw new ArgumentNullException(nameof(bypassAction));
        commandQueue = Channel.CreateUnbounded<AudioCommand>(new UnboundedChannelOptions
        {
            SingleReader = true,
            SingleWriter = false
        });
        processorTask = Task.Run(ProcessQueueAsync);
    }

    public Task HotReloadPipelineAsync(string reason, CancellationToken cancellationToken) =>
        EnqueueAsync(new AudioCommand(AudioCommandType.HotReload, reason), cancellationToken);

    public Task ActivateBypassModeAsync(string reason, CancellationToken cancellationToken) =>
        EnqueueAsync(new AudioCommand(AudioCommandType.Bypass, reason), cancellationToken);

    private async Task EnqueueAsync(AudioCommand command, CancellationToken cancellationToken)
    {
        TaskCompletionSource completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!await commandQueue.Writer.WaitToWriteAsync(cancellationToken).ConfigureAwait(false))
        {
            throw new InvalidOperationException("Audio command queue is no longer accepting work.");
        }

        if (!commandQueue.Writer.TryWrite(command with { Completion = completion }))
        {
            throw new InvalidOperationException("Could not enqueue audio command.");
        }

        using CancellationTokenRegistration registration = cancellationToken.Register(() => completion.TrySetCanceled(cancellationToken));
        await completion.Task.ConfigureAwait(false);
    }

    private async Task ProcessQueueAsync()
    {
        try
        {
            await foreach (AudioCommand command in commandQueue.Reader.ReadAllAsync(shutdownSource.Token).ConfigureAwait(false))
            {
                if (Interlocked.CompareExchange(ref hardwareMutationActive, 1, 0) != 0)
                {
                    command.Completion?.TrySetException(new InvalidOperationException("Audio pipeline mutation is already active."));
                    continue;
                }

                try
                {
                    if (command.CommandType == AudioCommandType.HotReload)
                    {
                        await reloadAction(command.Reason, shutdownSource.Token).ConfigureAwait(false);
                    }
                    else
                    {
                        await bypassAction(command.Reason, shutdownSource.Token).ConfigureAwait(false);
                    }

                    command.Completion?.TrySetResult();
                }
                catch (Exception ex)
                {
                    command.Completion?.TrySetException(ex);
                }
                finally
                {
                    Interlocked.Exchange(ref hardwareMutationActive, 0);
                }
            }
        }
        catch (OperationCanceledException)
        {
            // Expected during shutdown.
        }
    }

    public async ValueTask DisposeAsync()
    {
        shutdownSource.Cancel();
        commandQueue.Writer.TryComplete();
        try
        {
            await processorTask.ConfigureAwait(false);
        }
        finally
        {
            shutdownSource.Dispose();
        }
    }

    private enum AudioCommandType
    {
        HotReload,
        Bypass
    }

    private sealed record AudioCommand(
        AudioCommandType CommandType,
        string Reason,
        TaskCompletionSource? Completion = null);
}

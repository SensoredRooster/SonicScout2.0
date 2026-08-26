using System.Threading;
using System.Threading.Tasks;

namespace SonicScout.Bridge;

public interface IScoutAudioController
{
    Task HotReloadPipelineAsync(string reason, CancellationToken cancellationToken);
    Task ActivateBypassModeAsync(string reason, CancellationToken cancellationToken);
}

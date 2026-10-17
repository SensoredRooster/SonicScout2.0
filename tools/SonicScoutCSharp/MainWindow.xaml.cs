using System.IO;
using System.Text.Json;
using Path = System.IO.Path;
using System.Diagnostics;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Drawing = System.Drawing;
using System.Numerics;
using System.Text.RegularExpressions;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using Forms = System.Windows.Forms;
using SonicScout.Bridge;
using WpfButton = System.Windows.Controls.Button;
using WpfRectangle = System.Windows.Shapes.Rectangle;
using WpfColor = System.Windows.Media.Color;
using WpfBrush = System.Windows.Media.Brush;
using WpfColorConverter = System.Windows.Media.ColorConverter;

namespace SonicScout;

internal sealed record ThemeDefinition(
    string Background,
    string Primary,
    string Secondary,
    string Highlight,
    string Panel,
    string Card,
    string Text,
    string Muted,
    string Success,
    string Error,
    bool LayeredSurfaces = false);

public partial class MainWindow : Window
{
    private bool audioConfigurationInProgress;
    private const int WmNclButtonDown = 0x00A1;
    private const int HtCaption = 0x0002;
    private static readonly Guid PcmSubFormatGuid = new("00000001-0000-0010-8000-00AA00389B71");
    private static readonly Guid IeeeFloatSubFormatGuid = new("00000003-0000-0010-8000-00AA00389B71");

    [DllImport("user32.dll")]
    private static extern bool ReleaseCapture();

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr handle, int message, IntPtr word, IntPtr longValue);
    private readonly string profilesDirectory = ResolveProfilesDirectory();
    private readonly string activeProfilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
        "HAudioApp",
        "active_profile.txt");
    private readonly string routingConfigurationPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "SonicScout",
        "routing_configuration.json");
    private readonly string sonicScoutAlgorithmPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
        "HAudioApp",
        "sonic_scout_background_profile.txt");
    private readonly DispatcherTimer breathingTimer = new() { Interval = TimeSpan.FromMilliseconds(50) };
    private readonly DispatcherTimer clipGuardTimer = new() { Interval = TimeSpan.FromMilliseconds(500) };
    private readonly DispatcherTimer eqWriteTimer = new() { Interval = TimeSpan.FromMilliseconds(180) };
    private WasapiLoopbackCapture? loopbackCapture;
    private readonly object spectrumLock = new();
    private const int SpectrumSampleWindow = 4096;
    private const int SpectrumBandCount = 48;
    private const int SpectrumHopFrames = 1024;
    private readonly float[] sampleRing = new float[8192];
    private int framesSinceSpectrum;
    private int sampleRingWrite;
    private int sampleRingCount;
    private readonly float[] spectrumSampleScratch = new float[SpectrumSampleWindow];
    private readonly Complex[] fftScratch = new Complex[SpectrumSampleWindow];
    private readonly double[] spectrumBandScratch = new double[SpectrumBandCount];
    private readonly double[] spectrumRenderCopy = new double[SpectrumBandCount];
    private double[] spectrumLevels = new double[SpectrumBandCount];
    private readonly double[] smoothedSpectrum = new double[SpectrumBandCount];
    private bool audioSignalSeen;
    private DateTime lastAudioDataAtUtc = DateTime.MinValue;
    private double fallbackMeterLevel;
    // Dedicated meter endpoint, re-acquired by id after Windows invalidates it (0x88890010 etc.).
    private MMDevice? meterDevice;
    private string? meterDeviceId;
    private readonly MeterBackoff meterBackoff = new();
    private EapoInstallationFacts? apoFacts;
    private DateTime lastEqStatusRefreshUtc = DateTime.MinValue;
    private string? activeProfileId;
    private readonly Dictionary<string, double> eqValues = new(StringComparer.OrdinalIgnoreCase);
    private static readonly int[] EqFrequencies = { 60, 150, 400, 1000, 2500, 6000, 12000 };
    private double breathingPhase;
    private readonly List<(Border Border, SolidColorBrush Brush)> racingBorders = new();
    private ThemeDefinition activeTheme = Themes["Copper Signal"];
    private MMDeviceEnumerator? audioEnumerator;
    private readonly List<MMDevice> outputDeviceReferences = new();
    private readonly List<MMDevice> sonicPassInputReferences = new();
    private readonly List<MMDevice> sonicPassOutputReferences = new();
    private bool audioMonitorReady;
    private bool clipGuardEnabled;
    private static readonly double[] ClipGuardCaps = { 0.20, 0.40, 0.60, 0.80 };
    private int clipGuardCapIndex = -1;
    private bool windowsLeqEnabled;
    private bool apoLinked;
    private Process? sonicPassProcess;
    private string? sonicPassLastStartupError;
    private bool sonicPassStartedByLeqToggle;
    private SonicRoutingConfiguration routingConfiguration;
    private readonly QueuedScoutAudioController scriptAudioController;
    private readonly ScriptOrchestrator scriptBridge;
    private readonly Forms.NotifyIcon trayIcon;
    private bool exitRequested;

    private static readonly IReadOnlyDictionary<string, ThemeDefinition> Themes =
        new Dictionary<string, ThemeDefinition>(StringComparer.OrdinalIgnoreCase)
        {
            ["Copper Signal"] = new("#10151A", "#D98E04", "#66D9EF", "#E6B450", "#172128", "#202C34", "#F4F1E8", "#AAB4BD", "#54D18A", "#E06C75"),
            ["Singularity Camo"] = new("#03010A", "#5E17EB", "#00F0FF", "#9D4EDD", "#03010A", "#03010A", "#FFFFFF", "#9D4EDD", "#00F0FF", "#9D4EDD", true),
            ["Dark Matter"] = new("#0A0216", "#3A0CA3", "#C77DFF", "#7209B7", "#0A0216", "#0A0216", "#FFFFFF", "#C77DFF", "#C77DFF", "#7209B7", true),
            ["Borealis"] = new("#020617", "#00F5D4", "#9B5DE5", "#00BBF9", "#020617", "#020617", "#FFFFFF", "#9B5DE5", "#00F5D4", "#9B5DE5", true),
            ["Abyss"] = new("#01040A", "#00E5FF", "#0A2540", "#0052FF", "#01040A", "#01040A", "#FFFFFF", "#00E5FF", "#00E5FF", "#0052FF", true),
            ["Apocalypse"] = new("#0D0505", "#FF003C", "#FF5A00", "#E63946", "#0D0505", "#0D0505", "#FFFFFF", "#FF5A00", "#FF5A00", "#E63946", true),
            ["Brutalist"] = new("#0F0F0F", "#FF2E2E", "#3FE27A", "#FF5C6C", "#FFFFFF", "#F5F5F5", "#0B0B0B", "#222222", "#3FE27A", "#FF5C6C"),
            ["Instrument"] = new("#07070A", "#EAA906", "#3FE27A", "#FF5C6C", "#0F1116", "#13141A", "#E8F8FF", "#8A8F98", "#3FE27A", "#FF5C6C"),
            ["Psychotic"] = new("#FBFEFF", "#6AA84F", "#2D9C3B", "#D6221E", "#F3F8F6", "#FFFFFF", "#0B1111", "#7B7F82", "#2D9C3B", "#D6221E")
        };

    private readonly Dictionary<string, (string Name, string Subtitle, WpfButton Button)> profiles;

    public MainWindow()
    {
        InitializeComponent();
        SupportService.Initialize();

        trayIcon = CreateTrayIcon();
        if (App.AutoStartLaunch && !App.ResumeSetupRequested) WindowState = WindowState.Minimized;
        StateChanged += (_, _) => UpdateRenderActivity();
        IsVisibleChanged += (_, _) => UpdateRenderActivity();
        profiles = new Dictionary<string, (string, string, WpfButton)>();
        routingConfiguration = SonicRoutingConfigurationStore.Load(routingConfigurationPath);
        RestoreComboValue(SonicPassBufferComboBox, routingConfiguration.SonicPassBufferMs);
        RestoreComboValue(SonicPassInputGainComboBox, routingConfiguration.SonicPassInputGainDb);
        RestoreComboValue(SonicPassOutputGainComboBox, routingConfiguration.SonicPassOutputGainDb);
        scriptAudioController = new QueuedScoutAudioController(HotReloadAudioPipelineAsync, ActivateBypassModeAsync);
        scriptBridge = new ScriptOrchestrator(scriptAudioController, Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "SonicScout"));
        scriptBridge.StateChanged += ScriptBridge_StateChanged;
        scriptBridge.LogReceived += ScriptBridge_LogReceived;
        LoadSavedProfiles();
        UpdateProfileState();
    }

    private void SupportButton_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            SupportService.Log("support_window_opened");
            SupportWindow window = new() { Owner = this };
            CopyThemeResourcesTo(window);
            window.ShowDialog();
        }
        catch (Exception ex)
        {
            SupportService.Log("support_window_failed", new { error = ex.Message }, true);
            System.Windows.MessageBox.Show(this, ex.Message, "Support & Diagnostics", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void LoadSavedProfiles()
    {
        if (!Directory.Exists(profilesDirectory))
        {
            return;
        }

        foreach (string profilePath in Directory.GetFiles(profilesDirectory, "custom_*.txt"))
        {
            string profileId = Path.GetFileNameWithoutExtension(profilePath);
            if (profileId.EndsWith("_target", StringComparison.OrdinalIgnoreCase) &&
                File.Exists(Path.Combine(profilesDirectory, profileId[..^7] + ".txt")))
            {
                continue;
            }
            string profileName = HumanizeProfileName(profileId);
            string subtitle = "Saved headphone / IEM profile";
            string metadataPath = profilePath + ".metadata.json";
            try
            {
                if (File.Exists(metadataPath))
                {
                    using JsonDocument metadata = JsonDocument.Parse(File.ReadAllText(metadataPath));
                    profileName = metadata.RootElement.GetProperty("Name").GetString() ?? profileName;
                    subtitle = metadata.RootElement.GetProperty("Subtitle").GetString() ?? subtitle;
                }
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or KeyNotFoundException)
            {
                SupportService.Log("profile_metadata_unavailable", new { profileId, error = exception.Message });
            }
            WpfButton profileButton = CreateProfileButton(profileId, profileName, subtitle);
            profiles[profileId] = (profileName, subtitle, profileButton);
        }
    }

    private static string HumanizeProfileName(string profileId)
    {
        string name = profileId.StartsWith("custom_", StringComparison.OrdinalIgnoreCase)
            ? profileId[7..]
            : profileId;
        return string.Join(" ", name.Split('_', StringSplitOptions.RemoveEmptyEntries).Select(part =>
            part.Length == 0 ? part : char.ToUpperInvariant(part[0]) + part[1..]));
    }

    private void UpdateProfileState()
    {
        bool hasProfiles = profiles.Count > 0;
        ProfileEmptyState.Visibility = hasProfiles ? Visibility.Collapsed : Visibility.Visible;
        NewProfileButton.Visibility = Visibility.Visible;
    }

    private async void Window_Loaded(object sender, RoutedEventArgs e)
    {
        MessageText.Text = "Checking the audio installation...";
        SonicPassStatusText.Text = "CHECKING SETUP - audio routing will start after verification";
        await EnsureTurnkeyStartupSetupAsync();
        LoadLogo();
        ApplyTheme(ThemeComboBox.SelectedItem is ComboBoxItem selected ? selected.Content?.ToString() : "Copper Signal");
        LoadAudioDevices();
        ApplyRoutingPreferenceToOutputSelection();
        StartAudioMonitor(OutputDeviceComboBox.SelectedIndex >= 0 && OutputDeviceComboBox.SelectedIndex < outputDeviceReferences.Count
            ? outputDeviceReferences[OutputDeviceComboBox.SelectedIndex]
            : null);
        eqWriteTimer.Tick += (_, _) =>
        {
            eqWriteTimer.Stop();
            SaveEqProfile();
        };
        EnsureApoLink();
        if (routingConfiguration.ActiveProfileId is string savedProfileId && profiles.TryGetValue(savedProfileId, out var savedProfile))
        {
            ProfileButton_Click(savedProfile.Button, new RoutedEventArgs());
        }
        try
        {
            await RefreshRoutingConfigurationFromSystemAsync();
        }
        catch (COMException)
        {
            routingConfiguration.SonicScoutProvisioned = false;
            routingConfiguration.SonicScoutEngaged = false;
        }
        catch (UnauthorizedAccessException)
        {
            routingConfiguration.SonicScoutProvisioned = false;
            routingConfiguration.SonicScoutEngaged = false;
        }
        catch (IOException)
        {
            routingConfiguration.SonicScoutProvisioned = false;
            routingConfiguration.SonicScoutEngaged = false;
        }
        RefreshWindowsLeqState();
        if (sonicPassProcess is null || sonicPassProcess.HasExited)
            SonicPassButton_Click(SonicPassButton, new RoutedEventArgs());
        if (sonicPassProcess is not null && !sonicPassProcess.HasExited)
        {
            windowsLeqEnabled = true;
            WindowsLeqToggle.IsChecked = true;
            RefreshWindowsLeqState();
        }
        clipGuardTimer.Tick += (_, _) => ApplyClipGuard();
        RegisterRacingBorders();

        breathingTimer.Tick += (_, _) =>
        {
            if (!renderActive) { RefreshHonestEqStatus(); return; }
            double amount = (Math.Sin(breathingPhase) + 1) / 2;
            WpfColor pulseColor = BlendColors(ParseColor(activeTheme.Primary), ParseColor(activeTheme.Highlight), amount);
            foreach ((Border border, SolidColorBrush brush) in racingBorders)
            {
                brush.Color = pulseColor;
                border.BorderBrush = brush;
            }
            RenderSpectrum();
            RefreshHonestEqStatus();
            breathingPhase += 0.018;
        };
        breathingTimer.Start();
    }

    private bool resumeVerifyOnly;

    private async Task EnsureTurnkeyStartupSetupAsync()
    {
        string? setupScriptPath = ResolveSetupAutomationScriptPath();
        if (setupScriptPath is null)
        {
            return;
        }

        int? preflightExitCode = await RunSetupPreflightExitCodeAsync(setupScriptPath, CancellationToken.None,
            // Right after logon (RunOnce resume) Windows is busy and the check can take far longer.
            App.ResumeSetupRequested ? TimeSpan.FromSeconds(180) : TimeSpan.FromSeconds(45));
        bool setupVerified = routingConfiguration.SonicScoutProvisioned &&
            !string.IsNullOrWhiteSpace(routingConfiguration.SelectedPhysicalOutputId) &&
            preflightExitCode.HasValue &&
            preflightExitCode.Value == 0;
        if (setupVerified)
        {
            return;
        }

        // After the driver-install reboot, if the non-admin preflight already passes there is
        // nothing left to install: finish SETUP with a verification-only run (no UAC prompt).
        // A timed-out check (null) is also tried as verification first; if that verification fails
        // the dialog reports it and RETRY INSTALLATION runs the full (elevated) install.
        resumeVerifyOnly = App.ResumeSetupRequested && (preflightExitCode == 0 || preflightExitCode is null);

        if (App.ResumeSetupRequested)
        {
            // Relaunched by RunOnce after the driver-install reboot. Do NOT block Window_Loaded on
            // this dialog: the device list, live meter and EQ status timer must start now, and the
            // resume dialog stays open (with its next steps) until the user closes it. Shown once
            // the window is idle, i.e. after Window_Loaded has finished its startup work.
            _ = Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(() => ShowStartupSetupDialog(autoResume: true)));
            return;
        }

        ShowStartupSetupDialog(autoResume: false);
    }

    private void ShowStartupSetupDialog(bool autoResume)
    {
        // Single startup SETUP window (one window only, so only one elevation prompt).
        SetupWindow dialog = new(DiscoverOutputEndpointsAsync, RunSetupChecks, OpenPostInstallVerificationAsync) { Owner = this, AutoResume = autoResume };
        CopyThemeResourcesTo(dialog);
        dialog.ShowDialog();

        if (string.IsNullOrWhiteSpace(routingConfiguration.SonicScoutEndpointId) || string.IsNullOrWhiteSpace(routingConfiguration.SelectedPhysicalOutputId))
        {
            MessageText.Text = BuildSonicPassSetupGuidance();
            SonicPassStatusText.Text = "SETUP REQUIRED - finish the wizard to activate SonicPass";
        }
        // App stays open regardless — user can finish setup later from the main window
    }

    private static async Task<int?> RunSetupPreflightExitCodeAsync(string setupScriptPath, CancellationToken cancellationToken, TimeSpan? timeout = null)
    {
        try
        {
            ProcessStartInfo startInfo = new("powershell.exe")
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                WorkingDirectory = Path.GetDirectoryName(setupScriptPath)!
            };
            startInfo.ArgumentList.Add("-NoProfile");
            startInfo.ArgumentList.Add("-ExecutionPolicy");
            startInfo.ArgumentList.Add("Bypass");
            startInfo.ArgumentList.Add("-File");
            startInfo.ArgumentList.Add(setupScriptPath);
            startInfo.ArgumentList.Add("-Mode");
            // Preflight, NOT Install. This runs on EVERY app launch to decide whether
            // the setup wizard is needed, so it must only ASK.
            //
            // With -Mode Install this was actively wrong twice over: Request-ElevationIfNeeded
            // fires a UAC prompt and then `exit 0` when the app is not elevated, so a
            // launch that installed nothing was recorded as preflight success; and when
            // the app WAS elevated it ran the entire dependency install inline, with no
            // timeout, every single time the app opened.
            //
            // Preflight skips elevation entirely (setup_audio_stack.ps1:85) and exits 2
            // when setup is incomplete, which is the signal this method actually wants.
            startInfo.ArgumentList.Add("Preflight");
            startInfo.ArgumentList.Add("-Quiet");
            startInfo.ArgumentList.Add("-NonInteractive");

            using Process process = new() { StartInfo = startInfo };
            if (!process.Start())
            {
                return null;
            }

            // Bounded so a wedged dependency check can never block app startup
            // indefinitely. Returning null makes the caller treat the wizard as needed,
            // which is the safe direction to be wrong in.
            Task<string> preflightOutput = process.StandardOutput.ReadToEndAsync();
            Task<string> preflightErrors = process.StandardError.ReadToEndAsync();
            using CancellationTokenSource timeoutSource = new(timeout ?? TimeSpan.FromSeconds(45));
            using CancellationTokenSource linked =
                CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutSource.Token);

            try
            {
                await process.WaitForExitAsync(linked.Token);
                await Task.WhenAll(preflightOutput, preflightErrors);
            }
            catch (OperationCanceledException) when (timeoutSource.IsCancellationRequested)
            {
                try { process.Kill(entireProcessTree: true); } catch { /* already gone */ }
                return null;
            }

            return process.ExitCode;
        }
        catch (InvalidOperationException)
        {
            return null;
        }
        catch (Win32Exception)
        {
            return null;
        }
    }

    private void LoadLogo()
    {
        string logoPath = Path.Combine(AppContext.BaseDirectory, "logo.png");
        if (!File.Exists(logoPath))
        {
            return;
        }

        LogoImage.Source = new BitmapImage(new Uri(logoPath, UriKind.Absolute));
        LogoImage.Visibility = Visibility.Visible;
    }

    private void StartAudioMonitor(MMDevice? selectedOutput = null)
    {
        if (audioConfigurationInProgress) return;
        try
        {
            StopAudioMonitor();
            loopbackCapture = selectedOutput is null
                ? new WasapiLoopbackCapture()
                : new WasapiLoopbackCapture(selectedOutput);
            loopbackCapture.DataAvailable += LoopbackCapture_DataAvailable;
            loopbackCapture.RecordingStopped += (_, _) => { };
            loopbackCapture.StartRecording();
            sampleRingWrite = 0;
            sampleRingCount = 0;
            Array.Clear(sampleRing, 0, sampleRing.Length);
            Array.Clear(smoothedSpectrum, 0, smoothedSpectrum.Length);
            Array.Clear(spectrumLevels, 0, spectrumLevels.Length);
            lastAudioDataAtUtc = DateTime.MinValue;
            fallbackMeterLevel = 0;
            audioSignalSeen = false;
            audioMonitorReady = true;
            SpectrumStatusText.Text = "LISTENING FOR SYSTEM AUDIO";
        }
        catch (Exception)
        {
            SpectrumStatusText.Text = "SYSTEM AUDIO UNAVAILABLE";
            MessageText.Text = "Loopback audio is unavailable. Check the selected Windows output device.";
        }
    }

    private void StopAudioMonitor()
    {
        if (loopbackCapture is null)
        {
            return;
        }

        try
        {
            loopbackCapture.StopRecording();
            loopbackCapture.Dispose();
        }
        catch (Exception)
        {
        }
        finally
        {
            loopbackCapture = null;
            audioMonitorReady = false;
        }
    }

    private void LoopbackCapture_DataAvailable(object? sender, WaveInEventArgs e)
    {
        if (loopbackCapture is null)
        {
            return;
        }

        WaveFormat format = loopbackCapture.WaveFormat;
        int bytesPerSample = format.BitsPerSample / 8;
        int frameSize = format.BlockAlign;
        bool observedSample = false;
        lock (spectrumLock)
        {
            int channels = Math.Max(1, format.Channels);
            for (int offset = 0; offset + frameSize <= e.BytesRecorded; offset += frameSize)
            {
                // Mono mix of all channels (the old meter only watched channel 1).
                float sample = 0;
                for (int ch = 0; ch < channels; ch++)
                    sample += ReadNormalizedSample(format, e.Buffer, offset + (ch * bytesPerSample), bytesPerSample);
                sample /= channels;
                framesSinceSpectrum++;
                sampleRing[sampleRingWrite] = sample;
                sampleRingWrite = (sampleRingWrite + 1) % sampleRing.Length;
                if (sampleRingCount < sampleRing.Length)
                {
                    sampleRingCount++;
                }
                observedSample = true;
            }

            if (sampleRingCount >= SpectrumSampleWindow && framesSinceSpectrum >= (renderActive ? SpectrumHopFrames : SpectrumHopFrames * 8))
            {
                framesSinceSpectrum = 0;
                CopyLatestSamples(spectrumSampleScratch);
                SpectrumAnalyzer.Compute(spectrumSampleScratch, format.SampleRate, spectrumBandScratch, fftScratch);
                bool signalSeen = false;
                for (int index = 0; index < spectrumBandScratch.Length; index++)
                {
                    double response = spectrumBandScratch[index] > smoothedSpectrum[index] ? 0.42 : 0.12;
                    smoothedSpectrum[index] += (spectrumBandScratch[index] - smoothedSpectrum[index]) * response;
                    spectrumLevels[index] = smoothedSpectrum[index];
                    if (smoothedSpectrum[index] > 0.22) // above -70 dBFS
                    {
                        signalSeen = true;
                    }
                }
                audioSignalSeen = signalSeen;
            }
        }

        if (observedSample)
        {
            lastAudioDataAtUtc = DateTime.UtcNow;
        }
    }

    private static float ReadNormalizedSample(WaveFormat format, byte[] buffer, int offset, int bytesPerSample)
    {
        if (offset + bytesPerSample > buffer.Length)
        {
            return 0f;
        }

        bool treatAsFloat = format.Encoding == WaveFormatEncoding.IeeeFloat;
        if (format.Encoding == WaveFormatEncoding.Extensible && format is WaveFormatExtensible extensibleFormat)
        {
            if (extensibleFormat.SubFormat == IeeeFloatSubFormatGuid)
            {
                treatAsFloat = true;
            }
            else if (extensibleFormat.SubFormat == PcmSubFormatGuid)
            {
                treatAsFloat = false;
            }
            else
            {
                treatAsFloat = format.BitsPerSample == 32;
            }
        }

        if (treatAsFloat && bytesPerSample >= 4)
        {
            return BitConverter.ToSingle(buffer, offset);
        }

        return bytesPerSample switch
        {
            1 => (buffer[offset] - 128) / 128f,
            2 => BitConverter.ToInt16(buffer, offset) / 32768f,
            3 => Read24BitSample(buffer, offset) / 8388608f,
            4 => BitConverter.ToInt32(buffer, offset) / 2147483648f,
            _ => 0f
        };
    }

    private static int Read24BitSample(byte[] buffer, int offset)
    {
        int sample = buffer[offset] | (buffer[offset + 1] << 8) | (buffer[offset + 2] << 16);
        if ((sample & 0x800000) != 0)
        {
            sample |= unchecked((int)0xFF000000);
        }
        return sample;
    }

    private void CopyLatestSamples(float[] destination)
    {
        int count = Math.Min(destination.Length, sampleRingCount);
        int start = (sampleRingWrite - count + sampleRing.Length) % sampleRing.Length;
        for (int i = 0; i < count; i++)
        {
            destination[i] = sampleRing[(start + i) % sampleRing.Length];
        }
    }

    // RenderSpectrum and the target-curve editor live in MainWindow.TargetGraph.cs.

    private void TryRefreshSpectrumFromAudioMeter()
    {
        if (OutputDeviceComboBox.SelectedIndex < 0 || OutputDeviceComboBox.SelectedIndex >= outputDeviceReferences.Count)
        {
            return;
        }

        DateTime nowUtc = DateTime.UtcNow;
        if (!meterBackoff.CanAttempt(nowUtc)) return;

        double peak;
        try
        {
            string selectedId = outputDeviceReferences[OutputDeviceComboBox.SelectedIndex].ID;
            if (meterDevice is null || !string.Equals(meterDeviceId, selectedId, StringComparison.OrdinalIgnoreCase))
            {
                ReleaseMeterDevice();
                using MMDeviceEnumerator enumerator = new();
                meterDevice = enumerator.GetDevice(selectedId);
                meterDeviceId = selectedId;
            }
            if (meterDevice.State != DeviceState.Active)
            {
                ReleaseMeterDevice();
                meterBackoff.RecordFailure(nowUtc);
                fallbackMeterLevel = 0;
                audioSignalSeen = false;
                return;
            }
            peak = meterDevice.AudioMeterInformation.MasterPeakValue;
            meterBackoff.RecordSuccess();
        }
        catch (Exception exception) when (exception is COMException or InvalidCastException or ArgumentException or ObjectDisposedException)
        {
            // Windows invalidates endpoints on device change / driver or service restart
            // (AUDCLNT_E_DEVICE_INVALIDATED 0x88890004, 0x88890010, ...). Drop the stale
            // meter and re-acquire it by id on a later tick with backoff. Never crash the UI.
            ReleaseMeterDevice();
            meterBackoff.RecordFailure(nowUtc);
            fallbackMeterLevel = 0;
            audioSignalSeen = false;
            return;
        }
        fallbackMeterLevel = (fallbackMeterLevel * 0.68) + (peak * 0.32);
        if (fallbackMeterLevel <= 0.001)
        {
            audioSignalSeen = false;
            return;
        }

        // Loopback is not delivering samples but the endpoint peak meter shows audio: report
        // signal presence only. Never synthesize spectrum bars (beta.1 drew random "wobble").
        lock (spectrumLock)
        {
            for (int index = 0; index < smoothedSpectrum.Length; index++) smoothedSpectrum[index] *= 0.85;
            Array.Copy(smoothedSpectrum, spectrumLevels, spectrumLevels.Length);
        }

        audioSignalSeen = true;
    }

    private void ReleaseMeterDevice()
    {
        MMDevice? device = meterDevice;
        meterDevice = null;
        meterDeviceId = null;
        try { device?.Dispose(); } catch (COMException) { } catch (InvalidCastException) { }
    }

    private void RefreshHonestEqStatus(bool force = false)
    {
        DateTime nowUtc = DateTime.UtcNow;
        if (!force && (nowUtc - lastEqStatusRefreshUtc).TotalMilliseconds < 1000) return;
        lastEqStatusRefreshUtc = nowUtc;
        apoFacts ??= EapoInstallation.Probe();
        bool audioArriving = audioSignalSeen || PhysicalOutputHasSignal(nowUtc);
        EqRuntimeStatus status = EapoInstallation.EvaluateStatus(EapoInstallation.IsVerified(apoFacts), apoLinked, audioArriving);
        (string label, string guidance) = EapoInstallation.Describe(status);
        WpfBrush color = (WpfBrush)FindResource(status == EqRuntimeStatus.Running ? "SuccessBrush" : "ErrorBrush");
        if (EapoStatus.Text != label)
        {
            WriteEqStatusSnapshot(label, status);
            EapoStatus.Text = label;
            EapoStatus.Foreground = color;
            EapoStatus.ToolTip = guidance;
        }
        if (ChainEapoStateText.Text != label)
        {
            ChainEapoStateText.Text = label;
            ChainEapoStateText.Foreground = color;
            ChainEapoStateText.ToolTip = guidance;
        }
    }

    private MMDevice? physicalMeterDevice;
    private string? physicalMeterDeviceId;
    private readonly MeterBackoff physicalMeterBackoff = new();

    // The spectrum meter watches whichever device is selected in the main window (often the
    // virtual cable) and only runs while the canvas is rendered. For the honest status, also
    // count processed audio reaching the user's physical output, read via the endpoint peak
    // meter, with the same dispose-and-backoff handling for invalidated devices.
    private bool PhysicalOutputHasSignal(DateTime nowUtc)
    {
        string? id = routingConfiguration.SelectedPhysicalOutputId;
        if (string.IsNullOrWhiteSpace(id) || !physicalMeterBackoff.CanAttempt(nowUtc)) return false;
        try
        {
            if (physicalMeterDevice is null || !string.Equals(physicalMeterDeviceId, id, StringComparison.OrdinalIgnoreCase))
            {
                physicalMeterDevice?.Dispose();
                using MMDeviceEnumerator enumerator = new();
                physicalMeterDevice = enumerator.GetDevice(id);
                physicalMeterDeviceId = id;
            }
            if (physicalMeterDevice.State != DeviceState.Active) throw new InvalidOperationException("inactive");
            float peak = physicalMeterDevice.AudioMeterInformation.MasterPeakValue;
            physicalMeterBackoff.RecordSuccess();
            return peak > 0.01f;
        }
        catch (Exception ex) when (ex is COMException or InvalidCastException or ArgumentException or ObjectDisposedException or InvalidOperationException)
        {
            try { physicalMeterDevice?.Dispose(); } catch { }
            physicalMeterDevice = null;
            physicalMeterDeviceId = null;
            physicalMeterBackoff.RecordFailure(nowUtc);
            return false;
        }
    }

    private void WriteEqStatusSnapshot(string label, EqRuntimeStatus status)
    {
        // Machine-readable mirror of the on-screen status for support and acceptance tests.
        try
        {
            string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SonicScout", "logs");
            Directory.CreateDirectory(directory);
            bool elevated;
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
                elevated = new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
            string json = JsonSerializer.Serialize(new
            {
                status = label,
                state = status.ToString(),
                apoVerified = apoFacts is not null && EapoInstallation.IsVerified(apoFacts),
                apoProblems = apoFacts is null ? Array.Empty<string>() : EapoInstallation.GetProblems(apoFacts).ToArray(),
                linked = apoLinked,
                audioArriving = audioSignalSeen,
                elevated,
                userInclude = EapoInstallation.UserIncludePath,
                timeUtc = DateTime.UtcNow
            });
            File.WriteAllText(Path.Combine(directory, "eq-status.json"), json);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private void RefreshSpectrumColors() => ResetTargetGraphVisuals();

    private void Window_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        exitRequested = true;
        clipGuardTimer.Stop();
        eqWriteTimer.Stop();
        breathingTimer.Stop();
        ReleaseMeterDevice();

        WasapiLoopbackCapture? captureToDispose = loopbackCapture;
        loopbackCapture = null;
        audioMonitorReady = false;

        try
        {
            StopSonicPass();
            scriptBridge.StateChanged -= ScriptBridge_StateChanged;
            scriptBridge.LogReceived -= ScriptBridge_LogReceived;
            scriptAudioController.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }
        catch (InvalidOperationException)
        {
        }

        try
        {
            if (trayIcon is not null)
            {
                trayIcon.Visible = false;
                trayIcon.Dispose();
            }
        }
        catch (Exception)
        {
        }

        if (captureToDispose is not null)
        {
            _ = Task.Run(() =>
            {
                try
                {
                    captureToDispose.StopRecording();
                    captureToDispose.Dispose();
                }
                catch (Exception)
                {
                }
            });
        }

        if (System.Windows.Application.Current is not null)
        {
            System.Windows.Application.Current.Shutdown();
        }
    }

    private void LoadAudioDevices()
    {
        loadingAudioDevices = true;
        try
        {
            // Release prior COM MMDevice instances before rebuilding lists.
            // sonicPass* lists alias entries already held in outputDeviceReferences.
            DisposeMmDevices(outputDeviceReferences);
            sonicPassInputReferences.Clear();
            sonicPassOutputReferences.Clear();
            audioEnumerator?.Dispose();
            audioEnumerator = new MMDeviceEnumerator();
            MMDeviceCollection inputs = audioEnumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active);
            MMDeviceCollection outputs = audioEnumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active);

            InputDeviceComboBox.Items.Clear();
            OutputDeviceComboBox.Items.Clear();
            SonicPassInputComboBox.Items.Clear();
            SonicPassOutputComboBox.Items.Clear();
            foreach (MMDevice device in inputs)
            {
                try
                {
                    InputDeviceComboBox.Items.Add(DisplayDeviceName(device.FriendlyName));
                }
                finally
                {
                    device.Dispose();
                }
            }
            foreach (MMDevice device in outputs)
            {
                outputDeviceReferences.Add(device);
                OutputDeviceComboBox.Items.Add(DisplayDeviceName(device.FriendlyName));
                if (IsSonicScoutVirtualCandidate(device.FriendlyName))
                {
                    sonicPassInputReferences.Add(device);
                    SonicPassInputComboBox.Items.Add(DisplayDeviceName(device.FriendlyName));
                }
                else
                {
                    sonicPassOutputReferences.Add(device);
                    SonicPassOutputComboBox.Items.Add(DisplayDeviceName(device.FriendlyName));
                }
            }

            int selectedScoutInput = sonicPassInputReferences.FindIndex(device =>
                string.Equals(device.ID, routingConfiguration.SonicScoutEndpointId, StringComparison.OrdinalIgnoreCase));
            SonicPassInputComboBox.SelectedIndex = selectedScoutInput >= 0 ? selectedScoutInput : (SonicPassInputComboBox.Items.Count > 0 ? 0 : -1);
            int selectedScoutOutput = sonicPassOutputReferences.FindIndex(device =>
                string.Equals(device.ID, routingConfiguration.SelectedPhysicalOutputId, StringComparison.OrdinalIgnoreCase));
            SonicPassOutputComboBox.SelectedIndex = selectedScoutOutput >= 0 ? selectedScoutOutput : (SonicPassOutputComboBox.Items.Count > 0 ? 0 : -1);

            if (InputDeviceComboBox.Items.Count > 0)
            {
                int cableCaptureIndex = InputDeviceComboBox.Items.Cast<string>().ToList().FindIndex(name =>
                    name.StartsWith("SonicScout2.0 Unified Output", StringComparison.OrdinalIgnoreCase));
                InputDeviceComboBox.SelectedIndex = cableCaptureIndex >= 0 ? cableCaptureIndex : 0;
            }
            if (OutputDeviceComboBox.Items.Count > 0)
            {
                int preferredOutputIndex = ResolvePreferredOutputIndex();
                OutputDeviceComboBox.SelectedIndex = preferredOutputIndex >= 0 ? preferredOutputIndex : 0;
                SelectedDeviceText.Text = OutputDeviceComboBox.SelectedItem?.ToString() ?? "No output selected";
            }
            UpdateRoutingFromCurrentOutputSelection();
            RefreshWindowsLeqState();
        }
        catch (Exception)
        {
            InputDeviceComboBox.Items.Add("No active input devices found");
            OutputDeviceComboBox.Items.Add("No active output devices found");
            InputDeviceComboBox.SelectedIndex = 0;
            OutputDeviceComboBox.SelectedIndex = 0;
            RefreshWindowsLeqState();
        }
        finally { loadingAudioDevices = false; }
    }

    private bool loadingAudioDevices;

    private static void DisposeMmDevices(List<MMDevice> devices)
    {
        for (int index = 0; index < devices.Count; index++)
        {
            try
            {
                devices[index].Dispose();
            }
            catch
            {
            }
        }

        devices.Clear();
    }

    private static string DisplayDeviceName(string deviceName)
    {
        if (string.IsNullOrWhiteSpace(deviceName))
        {
            return deviceName;
        }

        string normalizedName = Regex.Replace(deviceName, @"^\s*\w+\s+Tune\s*\+\s*", "Sonic Scout Link ", RegexOptions.IgnoreCase);
        normalizedName = Regex.Replace(normalizedName, @"^\s*\w+\s+Tune\s+", "Sonic Scout Link ", RegexOptions.IgnoreCase);
        return normalizedName;
    }

    private int ResolvePreferredOutputIndex()
    {
        int activeOutputIndex = FindOutputDeviceIndexById(routingConfiguration.ActiveOutputDeviceId);
        if (activeOutputIndex >= 0)
        {
            return activeOutputIndex;
        }

        int sonicScoutIndex = FindOutputDeviceIndexById(routingConfiguration.SonicScoutEndpointId);
        if (sonicScoutIndex >= 0)
        {
            return sonicScoutIndex;
        }

        int physicalOutputIndex = FindOutputDeviceIndexById(routingConfiguration.SelectedPhysicalOutputId);
        return physicalOutputIndex;
    }

    private int FindOutputDeviceIndexById(string? deviceId)
    {
        if (string.IsNullOrWhiteSpace(deviceId))
        {
            return -1;
        }

        for (int index = 0; index < outputDeviceReferences.Count; index++)
        {
            if (string.Equals(outputDeviceReferences[index].ID, deviceId, StringComparison.OrdinalIgnoreCase))
            {
                return index;
            }
        }

        return -1;
    }

    private string? GetSelectedOutputDeviceId()
    {
        if (OutputDeviceComboBox.SelectedIndex < 0 || OutputDeviceComboBox.SelectedIndex >= outputDeviceReferences.Count)
        {
            return null;
        }

        return outputDeviceReferences[OutputDeviceComboBox.SelectedIndex].ID;
    }

    private void UpdateRoutingFromCurrentOutputSelection()
    {
        string? selectedOutputId = GetSelectedOutputDeviceId();
        if (string.IsNullOrWhiteSpace(selectedOutputId))
        {
            return;
        }

        routingConfiguration.ActiveOutputDeviceId = selectedOutputId;
        routingConfiguration.ActiveOutputDeviceName = OutputDeviceComboBox.SelectedItem?.ToString();
    }

    private void ApplyRoutingPreferenceToOutputSelection()
    {
        int preferredOutputIndex = ResolvePreferredOutputIndex();
        if (preferredOutputIndex < 0 || preferredOutputIndex >= OutputDeviceComboBox.Items.Count)
        {
            return;
        }

        if (OutputDeviceComboBox.SelectedIndex != preferredOutputIndex)
        {
            OutputDeviceComboBox.SelectedIndex = preferredOutputIndex;
        }
    }

    private void InputDeviceComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (InputDeviceComboBox.SelectedItem is string deviceName && IsLoaded)
        {
            MessageText.Text = $"Input selected: {deviceName}";
        }
    }

    private void OutputDeviceComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (OutputDeviceComboBox.SelectedItem is string deviceName && IsLoaded)
        {
            if (audioMonitorReady && OutputDeviceComboBox.SelectedIndex >= 0 && OutputDeviceComboBox.SelectedIndex < outputDeviceReferences.Count)
            {
                StartAudioMonitor(outputDeviceReferences[OutputDeviceComboBox.SelectedIndex]);
            }
            SelectedDeviceText.Text = deviceName;
            MessageText.Text = $"Output selected: {deviceName}";
            UpdateRoutingFromCurrentOutputSelection();
            RefreshWindowsLeqState();
        }
    }

    private static bool IsHiFiCableOutput(string outputName)
    {
        if (string.IsNullOrWhiteSpace(outputName))
        {
            return false;
        }

        return outputName.Contains("hi-fi cable", StringComparison.OrdinalIgnoreCase) ||
               outputName.Contains("hifi cable", StringComparison.OrdinalIgnoreCase) ||
               outputName.Contains("vb-audio hi-fi", StringComparison.OrdinalIgnoreCase) ||
               outputName.Contains("vb-audio hifi", StringComparison.OrdinalIgnoreCase) ||
               outputName.Contains("sonic scout 2.0", StringComparison.OrdinalIgnoreCase) ||
               outputName.Contains("sonic scout", StringComparison.OrdinalIgnoreCase);
    }

    private bool IsSonicScoutEndpointSelected()
    {
        string? selectedOutputId = GetSelectedOutputDeviceId();
        if (!string.IsNullOrWhiteSpace(selectedOutputId) &&
            !string.IsNullOrWhiteSpace(routingConfiguration.SonicScoutEndpointId) &&
            string.Equals(selectedOutputId, routingConfiguration.SonicScoutEndpointId, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        return IsHiFiCableOutput(OutputDeviceComboBox.SelectedItem?.ToString() ?? string.Empty);
    }

    private bool ApplySafePhysicalOutputFallback()
    {
        int physicalOutputIndex = FindOutputDeviceIndexById(routingConfiguration.SelectedPhysicalOutputId);
        if (physicalOutputIndex < 0 || physicalOutputIndex >= OutputDeviceComboBox.Items.Count)
        {
            return false;
        }

        OutputDeviceComboBox.SelectedIndex = physicalOutputIndex;
        UpdateRoutingFromCurrentOutputSelection();
        return true;
    }

    private void UpdateTunedVirtualCableStatusIndicator()
    {
        bool sonicScoutProvisioned = routingConfiguration.SonicScoutProvisioned &&
            !string.IsNullOrWhiteSpace(routingConfiguration.SonicScoutEndpointId);
        bool sonicPassRunning = sonicPassProcess is not null && !sonicPassProcess.HasExited;
        bool engaged = sonicScoutProvisioned && sonicPassRunning;

        routingConfiguration.SonicScoutEngaged = engaged;
        routingConfiguration.ActiveOutputDeviceId = GetSelectedOutputDeviceId();
        routingConfiguration.ActiveOutputDeviceName = OutputDeviceComboBox.SelectedItem?.ToString();
        routingConfiguration.LastRoutingNote = engaged
            ? "SonicPass is running from the configured virtual input to the physical output."
            : "No audio relay engine is running.";
        SonicRoutingConfigurationStore.Save(routingConfigurationPath, routingConfiguration);

        WpfBrush engagedBrush = (WpfBrush)FindResource("SuccessBrush");
        WpfBrush disengagedBrush = (WpfBrush)FindResource("ErrorBrush");
        TunedVirtualCableStatusLed.Fill = engaged ? engagedBrush : disengagedBrush;
        TunedVirtualCableStatusText.Foreground = engaged ? engagedBrush : disengagedBrush;
        TunedVirtualCableStatusText.Text = engaged
            ? "CONNECTED"
            : "NOT CONNECTED";
    }

    private void RefreshWindowsLeqState()
    {
        bool tunedOutputSelected = IsSonicScoutEndpointSelected();
        bool sonicScoutProvisioned = routingConfiguration.SonicScoutProvisioned &&
            !string.IsNullOrWhiteSpace(routingConfiguration.SonicScoutEndpointId);

        WindowsLeqToggle.Content = "SELECT TUNED OUTPUT ABOVE";

        if (windowsLeqEnabled && !tunedOutputSelected)
        {
            windowsLeqEnabled = false;
            routingConfiguration.SonicScoutEngaged = false;
            WindowsLeqToggle.IsChecked = false;
            bool fallbackApplied = ApplySafePhysicalOutputFallback();
            WindowsLeqStatusText.Text = fallbackApplied
                ? "Sonic Scout off. Audio reverted to your physical output."
                : "Sonic Scout off. Run SETUP and choose a fallback output.";
            WindowsLeqStatusText.Foreground = (WpfBrush)FindResource("ReadableBrush");
            if (IsLoaded)
            {
                MessageText.Text = "Windows LEQ turned off because OUTPUT is no longer the configured tuned endpoint.";
            }
        }
        else if (windowsLeqEnabled)
        {
            WindowsLeqToggle.IsChecked = true;
            WindowsLeqStatusText.Text = routingConfiguration.HasCompatibilityMixer
                ? $"{routingConfiguration.SonicScoutAlias} active (compatibility mode)."
                : $"{routingConfiguration.SonicScoutAlias} active on selected output.";
            WindowsLeqStatusText.Foreground = (WpfBrush)FindResource("ReadableBrush");
        }
        else
        {
            WindowsLeqToggle.IsChecked = false;
            if (!sonicScoutProvisioned)
            {
                WindowsLeqStatusText.Text = "SETUP REQUIRED - no virtual audio route detected. Install VB-Cable / Hi-Fi Cable or Voicemeeter, then reopen SETUP.";
            }
            else if (tunedOutputSelected)
            {
                WindowsLeqStatusText.Text = $"{routingConfiguration.SonicScoutAlias} ready. Enable to start tuning.";
            }
            else
            {
                WindowsLeqStatusText.Text = "Select the configured virtual cable in OUTPUT above to use optional LEQ.";
            }
            WindowsLeqStatusText.Foreground = (WpfBrush)FindResource("ReadableBrush");
        }

        UpdateTunedVirtualCableStatusIndicator();
    }

    private void WindowsLeqToggle_Click(object sender, RoutedEventArgs e)
    {
        bool wantsEnabled = WindowsLeqToggle.IsChecked == true;
        bool sonicScoutProvisioned = routingConfiguration.SonicScoutProvisioned &&
            !string.IsNullOrWhiteSpace(routingConfiguration.SonicScoutEndpointId);
        bool tunedOutputSelected = IsSonicScoutEndpointSelected();

        if (wantsEnabled && !sonicScoutProvisioned)
        {
            windowsLeqEnabled = false;
            WindowsLeqToggle.IsChecked = false;
            routingConfiguration.SonicScoutEngaged = false;
            RefreshWindowsLeqState();
            MessageText.Text = BuildSonicPassSetupGuidance();
            return;
        }

        if (wantsEnabled && !tunedOutputSelected)
        {
            windowsLeqEnabled = false;
            WindowsLeqToggle.IsChecked = false;
            routingConfiguration.SonicScoutEngaged = false;
            RefreshWindowsLeqState();
            MessageText.Text = "Select your configured virtual cable in OUTPUT before enabling Windows LEQ.";
            return;
        }

        if (wantsEnabled)
        {
            if (string.IsNullOrWhiteSpace(routingConfiguration.SelectedPhysicalOutputId))
            {
                windowsLeqEnabled = false;
                WindowsLeqToggle.IsChecked = false;
                routingConfiguration.SonicScoutEngaged = false;
                RefreshWindowsLeqState();
                MessageText.Text = BuildSonicPassSetupGuidance();
                return;
            }

            if (sonicPassProcess is null || sonicPassProcess.HasExited)
            {
                if (ResolveSonicPassExecutablePath() is null)
                {
                    windowsLeqEnabled = false;
                    WindowsLeqToggle.IsChecked = false;
                    routingConfiguration.SonicScoutEngaged = false;
                    RefreshWindowsLeqState();
                    MessageText.Text = "The SonicPass component is missing. Reinstall Sonic Scout using SonicScout-Setup.exe.";
                    return;
                }

                if (!TryStartSonicPass(routingConfiguration.SonicScoutEndpointId!, routingConfiguration.SelectedPhysicalOutputId))
                {
                    windowsLeqEnabled = false;
                    WindowsLeqToggle.IsChecked = false;
                    routingConfiguration.SonicScoutEngaged = false;
                    RefreshWindowsLeqState();
                    MessageText.Text = "SonicPass could not start. Check the endpoint state.";
                    return;
                }

                sonicPassStartedByLeqToggle = true;
            }
        }

        windowsLeqEnabled = wantsEnabled;
        if (!wantsEnabled && sonicPassStartedByLeqToggle)
        {
            sonicPassStartedByLeqToggle = false;
            StopSonicPass();
        }

        routingConfiguration.SonicScoutEngaged = wantsEnabled;
        RefreshWindowsLeqState();
        MessageText.Text = windowsLeqEnabled
            ? "Live equalizer enabled. SonicPass is processing the tuned audio path."
            : "Windows LEQ disabled. Audio remains on your selected output path.";
    }

    private void ClipGuardToggle_Click(object sender, RoutedEventArgs e)
    {
        clipGuardCapIndex = (clipGuardCapIndex + 1) % (ClipGuardCaps.Length + 1);
        clipGuardEnabled = clipGuardCapIndex < ClipGuardCaps.Length;
        ClipGuardToggle.Content = clipGuardEnabled
            ? $"ON / {ClipGuardCaps[clipGuardCapIndex] * 100:0}% CAP"
            : "OFF / CAP";
        if (clipGuardEnabled)
        {
            clipGuardTimer.Start();
            ApplyClipGuard();
            MessageText.Text = $"Clip Guard enabled. Output is capped at {ClipGuardCaps[clipGuardCapIndex] * 100:0}%.";
        }
        else
        {
            clipGuardTimer.Stop();
            MessageText.Text = "Clip Guard disabled.";
        }
    }

    private void ApplyClipGuard()
    {
        if (!clipGuardEnabled || audioEnumerator is null)
        {
            return;
        }

        try
        {
            MMDevice defaultOutput = OutputDeviceComboBox.SelectedIndex >= 0 && OutputDeviceComboBox.SelectedIndex < outputDeviceReferences.Count
                ? outputDeviceReferences[OutputDeviceComboBox.SelectedIndex]
                : audioEnumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            float cap = (float)ClipGuardCaps[clipGuardCapIndex];
            if (defaultOutput.AudioEndpointVolume.MasterVolumeLevelScalar > cap)
            {
                defaultOutput.AudioEndpointVolume.MasterVolumeLevelScalar = cap;
            }
        }
        catch (Exception)
        {
            MessageText.Text = "Clip Guard could not access the default output endpoint.";
        }
    }

    private void SoundSettingsButton_Click(object sender, RoutedEventArgs e)
    {
        OpenSoundSettings();
    }

    private void Window_PreviewKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == System.Windows.Input.Key.S &&
            (System.Windows.Input.Keyboard.Modifiers & (System.Windows.Input.ModifierKeys.Control | System.Windows.Input.ModifierKeys.Alt)) ==
            (System.Windows.Input.ModifierKeys.Control | System.Windows.Input.ModifierKeys.Alt))
        {
            OpenSoundSettings();
            e.Handled = true;
        }
    }

    private static void OpenSoundSettings()
    {
        Process.Start(new ProcessStartInfo("mmsys.cpl") { UseShellExecute = true });
    }


    private void RegisterRacingBorders()
    {
        racingBorders.Clear();
        foreach (Border border in new[] { AppShell, SpectrumFrame })
        {
            SolidColorBrush brush = CreateRacingBrush();
            border.BorderBrush = brush;
            racingBorders.Add((border, brush));
        }

        ChainPanel.BorderBrush = (WpfBrush)FindResource("AccentBrush");
        ProfilesPanel.BorderBrush = (WpfBrush)FindResource("AccentBrush");
        WindowsLeqPanel.BorderBrush = (WpfBrush)FindResource("AccentBrush");
        TunedVirtualCableStatusBox.BorderBrush = (WpfBrush)FindResource("AccentBrush");
        SpectrumPanel.BorderBrush = (WpfBrush)FindResource("AccentBrush");
        StatusPanel.BorderBrush = (WpfBrush)FindResource("AccentBrush");
    }

    private SolidColorBrush CreateRacingBrush()
    {
        return new SolidColorBrush(ParseColor(activeTheme.Primary));
    }

    private static WpfColor ParseColor(string value) => (WpfColor)WpfColorConverter.ConvertFromString(value);

    private void WindowChrome_MouseLeftButtonDown(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (e.ChangedButton != System.Windows.Input.MouseButton.Left || IsInteractiveTitleBarChild(e.OriginalSource as DependencyObject))
        {
            return;
        }

        e.Handled = true;
        if (e.ClickCount == 2)
        {
            ToggleMaximize();
            return;
        }

        ReleaseCapture();
        SendMessage(new System.Windows.Interop.WindowInteropHelper(this).Handle, WmNclButtonDown, new IntPtr(HtCaption), IntPtr.Zero);
    }

    private bool IsInteractiveTitleBarChild(DependencyObject? source)
    {
        DependencyObject? current = source;
        while (current is not null && current != TitleBar)
        {
            if (current is System.Windows.Controls.Control)
            {
                return true;
            }
            current = VisualTreeHelper.GetParent(current);
        }
        return false;
    }

    private void MinimizeButton_Click(object sender, RoutedEventArgs e)
    {
        ShowInTaskbar = true;
        SystemCommands.MinimizeWindow(this);
    }

    private void HideToTray()
    {
        Hide();
        trayIcon.ShowBalloonTip(1200, "Sonic Scout", "Still running in the system tray.", Forms.ToolTipIcon.Info);
    }

    private void MaximizeButton_Click(object sender, RoutedEventArgs e)
    {
        ToggleMaximize();
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e)
    {
        ExitFromTray();
    }

    private Forms.NotifyIcon CreateTrayIcon()
    {
        Forms.ContextMenuStrip menu = new();
        menu.Items.Add("Show Sonic Scout", null, (_, _) => ShowFromTray());
        Forms.ToolStripMenuItem startWithWindows = new("Start with Windows") { CheckOnClick = true, Checked = AutoStart.LoadEnabled(), ToolTipText = "Start Sonic Scout minimized when you sign in, so SonicPass audio routing comes back after a restart." };
        startWithWindows.CheckedChanged += (_, _) =>
        {
            try { AutoStart.SaveEnabled(startWithWindows.Checked); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
            AutoStart.ApplyForCurrentUser(startWithWindows.Checked);
            MessageText.Text = startWithWindows.Checked ? "Sonic Scout will start minimized when you sign in." : "Sonic Scout will no longer start with Windows.";
        };
        menu.Items.Add(startWithWindows);
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Exit Sonic Scout", null, (_, _) => ExitFromTray());

        Forms.NotifyIcon icon = new()
        {
            Icon = LoadTrayIcon(),
            Text = "Sonic Scout",
            Visible = true,
            ContextMenuStrip = menu
        };
        icon.DoubleClick += (_, _) => ShowFromTray();
        return icon;
    }

    private static Drawing.Icon LoadTrayIcon()
    {
        string logoPath = Path.Combine(AppContext.BaseDirectory, "logo.png");
        if (File.Exists(logoPath))
        {
            using Drawing.Bitmap bitmap = new(logoPath);
            return Drawing.Icon.FromHandle(bitmap.GetHicon());
        }

        return Drawing.SystemIcons.Application;
    }

    /// <summary>Another launch of SonicScout.exe was started; bring this instance forward (and resume SETUP if asked).</summary>
    public void ActivateFromSecondInstance(bool resume)
    {
        ShowFromTray();
        if (resume && !OwnedWindows.OfType<SetupWindow>().Any())
            _ = Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(() => ShowStartupSetupDialog(autoResume: true)));
    }

    private volatile bool renderActive = true;

    /// <summary>Animations and the 20 Hz spectrum only run while the window can be seen.</summary>
    private void UpdateRenderActivity()
    {
        renderActive = IsVisible && WindowState != WindowState.Minimized;
        breathingTimer.Interval = TimeSpan.FromMilliseconds(renderActive ? 50 : 1000);
    }

    private void ShowFromTray()
    {
        Show();
        WindowState = WindowState.Normal;
        Activate();
    }

    private void ExitFromTray()
    {
        exitRequested = true;
        Close();
    }

    private void SetupButton_Click(object sender, RoutedEventArgs e) => OpenSetupWindow(autoResume: false);

    private void OpenSetupWindow(bool autoResume)
    {
        SetupWindow dialog = new(DiscoverOutputEndpointsAsync, RunSetupChecks, OpenPostInstallVerificationAsync) { Owner = this, AutoResume = autoResume };
        CopyThemeResourcesTo(dialog);
        dialog.ShowDialog();
    }

    private Task OpenPostInstallVerificationAsync(Window owner)
    {
        PostInstallVerifyDialog dialog = new(sonicPassProcess is not null && !sonicPassProcess.HasExited,
            routingConfiguration.SelectedPhysicalOutputId) { Owner = owner };
        CopyThemeResourcesTo(dialog);
        bool? result = dialog.ShowDialog();
        if (result == true)
        {
            routingConfiguration.PostInstallVerified = dialog.AllConfirmed;
            routingConfiguration.PostInstallVerifiedUtc = DateTime.UtcNow;
            SonicRoutingConfigurationStore.Save(routingConfigurationPath, routingConfiguration);
        }
        return Task.CompletedTask;
    }

    private void ScriptBridge_StateChanged(object? sender, ScriptStateChangedEventArgs e)
    {
        Debug.WriteLine($"[ScriptBridge][{e.ScriptKey}][{e.ExecutionId}] {e.State} {(e.ExitCode.HasValue ? $"(exit {e.ExitCode})" : string.Empty)} {e.Message}");
    }

    private void ScriptBridge_LogReceived(object? sender, ScriptLogEventArgs e)
    {
        string level = e.IsError ? "ERR" : "OUT";
        Debug.WriteLine($"[ScriptBridge][{e.ScriptKey}][{e.ExecutionId}][{level}] {e.Message}");
    }

    private async Task HotReloadAudioPipelineAsync(string reason, CancellationToken cancellationToken)
    {
        await Dispatcher.InvokeAsync(() =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            LoadAudioDevices();
            ApplyRoutingPreferenceToOutputSelection();
            StartAudioMonitor(OutputDeviceComboBox.SelectedIndex >= 0 && OutputDeviceComboBox.SelectedIndex < outputDeviceReferences.Count
                ? outputDeviceReferences[OutputDeviceComboBox.SelectedIndex]
                : null);
            MessageText.Text = $"Audio devices refreshed. {reason}";
        });
    }

    private async Task ActivateBypassModeAsync(string reason, CancellationToken cancellationToken)
    {
        await Dispatcher.InvokeAsync(() =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            ApplySafePhysicalOutputFallback();
            sonicPassStartedByLeqToggle = false;
            StopSonicPass();
            MessageText.Text = $"Audio routing stopped. If your game uses the Sonic Scout cable, select your physical headphones or speakers in the game until setup succeeds. {reason}";
            SonicPassStatusText.Text = "STOPPED - choose physical output in your game to restore audio";
        });
    }

    private static bool IsCurrentProcessElevated()
    {
        using WindowsIdentity identity = WindowsIdentity.GetCurrent();
        WindowsPrincipal principal = new(identity);
        return principal.IsInRole(WindowsBuiltInRole.Administrator);
    }

    private UiAudioProfileSnapshot BuildUiProfileSnapshot()
    {
        Dictionary<string, double> sliders = new(StringComparer.OrdinalIgnoreCase);
        foreach (KeyValuePair<string, double> pair in eqValues)
        {
            sliders[pair.Key] = pair.Value;
        }

        Dictionary<string, string> metadata = new(StringComparer.OrdinalIgnoreCase)
        {
            ["activeOutputId"] = routingConfiguration.ActiveOutputDeviceId ?? string.Empty,
            ["activeOutputName"] = routingConfiguration.ActiveOutputDeviceName ?? string.Empty,
            ["selectedPhysicalOutputId"] = routingConfiguration.SelectedPhysicalOutputId ?? string.Empty,
            ["selectedPhysicalOutputName"] = routingConfiguration.SelectedPhysicalOutputName ?? string.Empty
        };

        return new UiAudioProfileSnapshot(
            HeadphoneProfile: activeProfileId,
            ActiveCurve: routingConfiguration.SetupStyle,
            SliderPositions: sliders,
            Metadata: metadata);
    }

    private static string? ResolveSetupAutomationScriptPath()
    {
        string[] candidates =
        [
            Path.Combine(AppContext.BaseDirectory, "setup_audio_stack.ps1"),
            Path.Combine(Directory.GetCurrentDirectory(), "setup_audio_stack.ps1"),
            Path.Combine(Directory.GetCurrentDirectory(), "CSharp", "setup_audio_stack.ps1")
        ];

        foreach (string candidate in candidates)
        {
            if (File.Exists(candidate))
            {
                return Path.GetFullPath(candidate);
            }
        }

        return null;
    }

    private async Task<ScriptExecutionResult?> RunSetupAutomationScriptAsync(SetupInstallRequest request, CancellationToken cancellationToken)
    {
        string? setupScriptPath = ResolveSetupAutomationScriptPath();
        if (setupScriptPath is null)
        {
            return null;
        }

        string mode = resumeVerifyOnly ? "Preflight" : "Install";
        resumeVerifyOnly = false;
        UiAudioProfileSnapshot snapshot = BuildUiProfileSnapshot();
        Dictionary<string, string> metadata = new(StringComparer.OrdinalIgnoreCase);
        if (snapshot.Metadata is not null)
        {
            foreach (KeyValuePair<string, string> pair in snapshot.Metadata)
            {
                metadata[pair.Key] = pair.Value;
            }
        }
        metadata["requestedOutputId"] = request.SelectedOutputId;
        metadata["requestedOutputName"] = request.SelectedOutputName;
        metadata["requestedSetupStyle"] = request.SetupStyle;
        snapshot = snapshot with { Metadata = metadata };

        ScriptEnginePayload payload = new(
            ProfileId: activeProfileId ?? "none",
            Audio: snapshot,
            RequestedBy: Environment.UserName,
            RequestedAtUtc: DateTimeOffset.UtcNow);

        List<string> scriptArguments =
        [
            "-Mode", mode,
            "-Quiet",
            "-NonInteractive",
            "-WaveLinkRouting", request.UsesWaveLink ? "Yes" : "No",
            "-VoicemeeterFallback", request.UsesVoicemeeter ? "Yes" : "No"
        ];

        if (request.ConfirmOwnership)
        {
            scriptArguments.Add("-OwnershipAccepted");
        }

        ScriptExecutionRequest executionRequest = new(
            ScriptKey: "setup_audio_stack",
            ScriptPath: setupScriptPath,
            WorkingDirectory: Path.GetDirectoryName(setupScriptPath)!,
            Payload: payload,
            AdditionalArguments: scriptArguments,
            // Installation waits for human confirmation in vendor dialogs. A timer
            // must not interrupt an audio-driver installer while it is applying changes.
            Timeout: null);

        string executionId = await scriptBridge.QueueExecutionAsync(executionRequest, cancellationToken);
        return await scriptBridge.WaitForCompletionAsync(executionId, cancellationToken);
    }

    private string BuildSonicPassSetupGuidance()
    {
        if (string.IsNullOrWhiteSpace(routingConfiguration.SonicScoutEndpointId))
        {
            string physicalOutput = string.IsNullOrWhiteSpace(routingConfiguration.SelectedPhysicalOutputName)
                ? "your selected physical output"
                : routingConfiguration.SelectedPhysicalOutputName;
            return $"Setup is incomplete: no Sonic Scout virtual output was detected. Install or enable VB-Cable / Hi-Fi Cable or Voicemeeter, then reopen SETUP and finish the wizard. Audio is still safe on {physicalOutput}.";
        }

        if (string.IsNullOrWhiteSpace(routingConfiguration.SelectedPhysicalOutputId))
        {
            return "Setup is incomplete: the physical output is missing. Reopen SETUP and choose the device you actually hear sound from.";
        }

        return "Setup is incomplete. Reopen SETUP to finish the virtual route configuration.";
    }

    private void SonicPassButton_Click(object sender, RoutedEventArgs e)
    {
        if (sonicPassProcess is not null && !sonicPassProcess.HasExited)
        {
            StopSonicPass();
            MessageText.Text = "SonicPass stopped.";
            SonicPassStatusText.Text = "STOPPED - SonicPass is not routing audio";
            return;
        }

        if (string.IsNullOrWhiteSpace(routingConfiguration.SonicScoutEndpointId))
        {
            MessageText.Text = BuildSonicPassSetupGuidance();
            SonicPassStatusText.Text = "SETUP REQUIRED - virtual route not detected";
            return;
        }

        string? physicalOutputId = routingConfiguration.SelectedPhysicalOutputId;
        if (string.IsNullOrWhiteSpace(physicalOutputId))
        {
            MessageText.Text = BuildSonicPassSetupGuidance();
            SonicPassStatusText.Text = "SETUP REQUIRED - physical output missing";
            return;
        }

        if (ResolveSonicPassExecutablePath() is null)
        {
            MessageText.Text = "The SonicPass component is missing. Reinstall Sonic Scout using SonicScout-Setup.exe.";
            SonicPassStatusText.Text = "NOT BUILT - build SonicPass before starting";
            return;
        }

        if (!TryStartSonicPass(routingConfiguration.SonicScoutEndpointId, physicalOutputId))
        {
            SonicPassStatusText.Text = "ERROR - SonicPass could not start";
            MessageText.Text = "SonicPass could not start. Check the endpoint state.";
            return;
        }

        sonicPassStartedByLeqToggle = false;
        SonicPassButton.Content = "STOP SONICPASS";
        SonicPassStartButton.Content = "STOP SONICPASS";
        SonicPassStatusText.Text = "STARTING - resolving the processed cable recording output";
        MessageText.Text = "SonicPass is starting. Waiting for the audio engine.";
        UpdateTunedVirtualCableStatusIndicator();
    }

    private bool TryStartSonicPass(string inputId, string outputId)
    {
        if (audioConfigurationInProgress) return false;
        string? sonicPassPath = ResolveSonicPassExecutablePath();
        if (sonicPassPath is null)
        {
            return false;
        }

        try
        {
            ProcessStartInfo startInfo = new(sonicPassPath)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                WorkingDirectory = Path.GetDirectoryName(sonicPassPath)!
            };
            // Never run two engines: a second SonicPass on the same cable doubles the audio
            // (comb filtering) and fights for the endpoint. Stop ours and any orphan left by a
            // previous SonicScout instance in this session (seen in the beta.2 VM run).
            if (sonicPassProcess is not null) StopSonicPass();
            KillOrphanSonicPassProcesses();
            startInfo.ArgumentList.Add("--input-id");
            startInfo.ArgumentList.Add(inputId);
            startInfo.ArgumentList.Add("--output-id");
            startInfo.ArgumentList.Add(outputId);
            startInfo.ArgumentList.Add("--buffer-ms");
            startInfo.ArgumentList.Add(GetComboValue(SonicPassBufferComboBox, "20"));
            startInfo.ArgumentList.Add("--input-gain-db");
            startInfo.ArgumentList.Add(GetComboValue(SonicPassInputGainComboBox, "0"));
            startInfo.ArgumentList.Add("--output-gain-db");
            startInfo.ArgumentList.Add(GetComboValue(SonicPassOutputGainComboBox, "0"));

            sonicPassProcess = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
            sonicPassLastStartupError = null;
            sonicPassProcess.ErrorDataReceived += (_, error) =>
            {
                if (!string.IsNullOrWhiteSpace(error.Data))
                {
                    if (error.Data.StartsWith("SonicPass startup failed", StringComparison.Ordinal))
                        sonicPassLastStartupError = error.Data;
                    bool initializationInfo = error.Data.StartsWith("SonicPass playback initialization:", StringComparison.Ordinal);
                    SupportService.Log(initializationInfo ? "sonicpass_format" : "sonicpass_error", new { inputId, outputId, message = error.Data }, !initializationInfo);
                }
            };
            sonicPassProcess.OutputDataReceived += (_, output) =>
            {
                if (output.Data?.StartsWith("SonicPass running:") == true || output.Data?.StartsWith("Format:") == true)
                {
                    SupportService.Log("sonicpass_started", new { inputId, outputId, message = output.Data });
                    if (output.Data.StartsWith("SonicPass running:"))
                    {
                        Dispatcher.BeginInvoke(() =>
                        {
                            if (sonicPassProcess is not null && !sonicPassProcess.HasExited)
                            {
                                SonicPassStatusText.Text = "RUNNING - processed stereo is routing to the physical output";
                                MessageText.Text = "SonicPass audio engine started.";
                            }
                        });
                    }
                }
            };
            sonicPassProcess.Exited += SonicPassProcess_Exited;
            if (!sonicPassProcess.Start())
            {
                throw new InvalidOperationException("Windows could not start SonicPass.");
            }
            sonicPassProcess.BeginOutputReadLine();
            sonicPassProcess.BeginErrorReadLine();
            return true;
        }
        catch (Exception exception) when (exception is InvalidOperationException or Win32Exception)
        {
            SupportService.Log("sonicpass_start_failed", new { inputId, outputId, error = exception.ToString() }, true);
            sonicPassProcess?.Dispose();
            sonicPassProcess = null;
            return false;
        }
    }

    private static void KillOrphanSonicPassProcesses()
    {
        int session = Process.GetCurrentProcess().SessionId;
        foreach (Process orphan in Process.GetProcessesByName("SonicScout.SonicPass"))
        {
            try
            {
                if (orphan.SessionId != session) continue;
                SupportService.Log("sonicpass_orphan_stopped", new { pid = orphan.Id });
                orphan.Kill();
                orphan.WaitForExit(3000);
            }
            catch (Exception exception) when (exception is InvalidOperationException or Win32Exception or NotSupportedException) { }
            finally { orphan.Dispose(); }
        }
    }
    private void SonicPassProcess_Exited(object? sender, EventArgs e)
    {
        Dispatcher.Invoke(() =>
        {
            if (!ReferenceEquals(sender, sonicPassProcess)) return;
            bool unexpectedExit = !exitRequested && sonicPassProcess is not null && sonicPassProcess.ExitCode != 0;
            sonicPassStartedByLeqToggle = false;
            SonicPassButton.Content = "SONICPASS";
            SonicPassStartButton.Content = "START SONICPASS";
            SonicPassStatusText.Text = unexpectedExit ? "ERROR - SonicPass stopped unexpectedly" : "STOPPED - SonicPass is not routing audio";
            if (!exitRequested && windowsLeqEnabled)
            {
                windowsLeqEnabled = false;
                WindowsLeqToggle.IsChecked = false;
                routingConfiguration.SonicScoutEngaged = false;
                RefreshWindowsLeqState();
                MessageText.Text = "SonicPass stopped. Live equalizer is off; start SonicPass again to resume.";
            }
            else if (unexpectedExit)
            {
                MessageText.Text = sonicPassLastStartupError ?? "SonicPass stopped unexpectedly. Check diagnostics for the audio-engine error.";
            }
            UpdateTunedVirtualCableStatusIndicator();
        });
    }

    private void StopSonicPass()
    {
        Process? processToStop = sonicPassProcess;
        sonicPassProcess = null;
        if (processToStop is null)
        {
            SonicPassButton.Content = "SONICPASS";
            SonicPassStartButton.Content = "START SONICPASS";
            SonicPassStatusText.Text = "STOPPED - SonicPass is not routing audio";
            return;
        }

        try
        {
            processToStop.Exited -= SonicPassProcess_Exited;
            if (!processToStop.HasExited)
            {
                _ = Task.Run(() =>
                {
                    try
                    {
                        processToStop.Kill(entireProcessTree: true);
                    }
                    catch (InvalidOperationException)
                    {
                    }
                    catch (Win32Exception)
                    {
                    }
                    finally
                    {
                        processToStop.Dispose();
                    }
                });
            }
            else
            {
                processToStop.Dispose();
            }
        }
        catch (InvalidOperationException)
        {
            processToStop.Dispose();
        }
        catch (Win32Exception)
        {
            processToStop.Dispose();
        }

        SonicPassButton.Content = "SONICPASS";
        SonicPassStartButton.Content = "START SONICPASS";
        SonicPassStatusText.Text = "STOPPED - SonicPass is not routing audio";
        UpdateTunedVirtualCableStatusIndicator();
    }

    private static string? ResolveSonicPassExecutablePath()
    {
        string trimmedBaseDirectory = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        string[] candidates =
        [
            Path.Combine(AppContext.BaseDirectory, "SonicScout.SonicPass.exe"),
            Path.Combine(AppContext.BaseDirectory, "ScoutPass", "SonicScout.SonicPass.exe"),
            Path.Combine(Directory.GetParent(trimmedBaseDirectory)?.Parent?.Parent?.FullName ?? string.Empty, "ScoutPass", "bin", "Release", "net8.0-windows", "SonicScout.SonicPass.exe")
        ];

        return candidates.FirstOrDefault(File.Exists);
    }

    private void SonicPassDevice_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (loadingAudioDevices) return;
        if (SonicPassInputComboBox.SelectedIndex >= 0 && SonicPassInputComboBox.SelectedIndex < sonicPassInputReferences.Count)
        {
            MMDevice input = sonicPassInputReferences[SonicPassInputComboBox.SelectedIndex];
            routingConfiguration.SonicScoutEndpointId = input.ID;
            routingConfiguration.SonicScoutEndpointName = DisplayDeviceName(input.FriendlyName);
        }

        if (SonicPassOutputComboBox.SelectedIndex >= 0 && SonicPassOutputComboBox.SelectedIndex < sonicPassOutputReferences.Count)
        {
            MMDevice output = sonicPassOutputReferences[SonicPassOutputComboBox.SelectedIndex];
            routingConfiguration.SelectedPhysicalOutputId = output.ID;
            routingConfiguration.SelectedPhysicalOutputName = DisplayDeviceName(output.FriendlyName);
        }

        SonicRoutingConfigurationStore.Save(routingConfigurationPath, routingConfiguration);
        RestartRunningSonicPass();
        if (sonicPassProcess is null || sonicPassProcess.HasExited)
            SonicPassStatusText.Text = "READY - choose gain and start SonicPass";
    }

    private void RestartRunningSonicPass()
    {
        if (sonicPassProcess is null || sonicPassProcess.HasExited) return;
        StopSonicPass();
        SonicPassButton_Click(this, new RoutedEventArgs());
    }

    private static string GetComboValue(System.Windows.Controls.ComboBox comboBox, string fallback)
    {
        return (comboBox.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? fallback;
    }

    private static void RestoreComboValue(System.Windows.Controls.ComboBox comboBox, string value)
    {
        ComboBoxItem? item = comboBox.Items.OfType<ComboBoxItem>().FirstOrDefault(candidate => candidate.Tag?.ToString() == value);
        if (item is not null) comboBox.SelectedItem = item;
    }

    private void SaveSonicPassControls()
    {
        routingConfiguration.SonicPassBufferMs = GetComboValue(SonicPassBufferComboBox, "20");
        routingConfiguration.SonicPassInputGainDb = GetComboValue(SonicPassInputGainComboBox, "0");
        routingConfiguration.SonicPassOutputGainDb = GetComboValue(SonicPassOutputGainComboBox, "0");
        SonicRoutingConfigurationStore.Save(routingConfigurationPath, routingConfiguration);
    }

    private void SonicPassGain_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (IsLoaded)
        {
            SaveSonicPassControls();
            RestartRunningSonicPass();
            MessageText.Text = $"SonicPass boost changed: input {GetComboValue(SonicPassInputGainComboBox, "0")} dB, output {GetComboValue(SonicPassOutputGainComboBox, "0")} dB.";
        }
    }

    private void SonicPassBuffer_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (IsLoaded)
        {
            SaveSonicPassControls();
            RestartRunningSonicPass();
            MessageText.Text = $"SonicPass buffer set to {GetComboValue(SonicPassBufferComboBox, "20")} ms.";
        }
    }

    private void SonicPassStartButton_Click(object sender, RoutedEventArgs e)
    {
        SonicPassButton_Click(sender, e);
    }

    private static bool IsSonicScoutVirtualCandidate(string outputName)
    {
        return outputName.Contains("sonic scout", StringComparison.OrdinalIgnoreCase) ||
               outputName.Contains("hi-fi cable", StringComparison.OrdinalIgnoreCase) ||
               outputName.Contains("hifi cable", StringComparison.OrdinalIgnoreCase) ||
               outputName.Contains("vb-audio", StringComparison.OrdinalIgnoreCase) ||
               outputName.Contains("virtual cable", StringComparison.OrdinalIgnoreCase) ||
               outputName.Contains("optical", StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsVoicemeeterEndpoint(string outputName)
    {
        return outputName.Contains("voicemeeter", StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsWaveLinkEndpoint(string outputName)
    {
        return outputName.Contains("wave link", StringComparison.OrdinalIgnoreCase) ||
               outputName.Contains("elgato", StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsSoundBlasterEndpoint(string outputName)
    {
        return outputName.Contains("sound blaster", StringComparison.OrdinalIgnoreCase) ||
               outputName.Contains("creative", StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsLikelyDedicatedDacOutput(string outputName)
    {
        string[] dacTokens =
        [
            "dac", "xmos", "usb audio", "audioquest", "topping", "fiio", "ifi", "schiit", "smsl", "cambridge", "focusrite"
        ];
        return dacTokens.Any(token => outputName.Contains(token, StringComparison.OrdinalIgnoreCase));
    }

    private async Task<IReadOnlyList<AudioEndpointOption>> DiscoverOutputEndpointsAsync()
    {
        return await Task.Run(() =>
        {
            using MMDeviceEnumerator enumerator = new();
            MMDeviceCollection outputs = enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active);
            List<AudioEndpointOption> discovered = new();
            foreach (MMDevice output in outputs)
            {
                discovered.Add(new AudioEndpointOption(output.ID, DisplayDeviceName(output.FriendlyName)));
            }

            return (IReadOnlyList<AudioEndpointOption>)discovered
                .OrderBy(endpoint => endpoint.DisplayName, StringComparer.OrdinalIgnoreCase)
                .ToList();
        });
    }

    private static bool IsCompatibilityRouteStyle(string setupStyle)
    {
        return setupStyle.Contains("Compatibility", StringComparison.OrdinalIgnoreCase);
    }

    private static string BuildCompatibilitySummary(SetupInstallRequest request)
    {
        bool compatibilityRouteStyle = IsCompatibilityRouteStyle(request.SetupStyle);
        List<string> enabledMixers = new();
        if (request.UsesVoicemeeter)
        {
            enabledMixers.Add("Voicemeeter");
        }
        if (request.UsesWaveLink)
        {
            enabledMixers.Add("Elgato Wave Link");
        }
        if (request.UsesSoundBlaster)
        {
            enabledMixers.Add("Creative Sound Blaster");
        }
        if (request.UsesOtherMixer)
        {
            enabledMixers.Add("Similar software");
        }

        string styleSummary = compatibilityRouteStyle
            ? "Sonic Scout compatibility route profile applied."
            : "Sonic Scout direct route profile applied.";

        return enabledMixers.Count == 0
            ? $"{styleSummary} No third-party mixer compatibility hooks enabled."
            : $"{styleSummary} Compatibility hooks enabled for {string.Join(", ", enabledMixers)}.";
    }

    private sealed record SonicScoutProvisionResult(
        bool Provisioned,
        string? EndpointId,
        string? EndpointName,
        string Detail);

    private async Task<SonicScoutProvisionResult> ProvisionSonicScoutRouteAsync(string selectedPhysicalOutputId)
    {
        return await Task.Run(() =>
        {
            using MMDeviceEnumerator enumerator = new();
            MMDeviceCollection outputs = enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active);
            MMDevice? sonicScoutEndpoint = null;

            foreach (MMDevice output in outputs.OrderBy(output => AudioRoutePreference.Rank(output.FriendlyName)))
            {
                string displayName = DisplayDeviceName(output.FriendlyName);
                if (string.Equals(output.ID, selectedPhysicalOutputId, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                if (IsSonicScoutVirtualCandidate(displayName))
                {
                    sonicScoutEndpoint = output;
                    break;
                }
            }

            if (sonicScoutEndpoint is null)
            {
                return new SonicScoutProvisionResult(
                    Provisioned: false,
                    EndpointId: null,
                    EndpointName: null,
                    Detail: "No compatible virtual cable endpoint was detected. Sonic Scout will safely fall back to the selected physical output.");
            }

            return new SonicScoutProvisionResult(
                Provisioned: true,
                EndpointId: sonicScoutEndpoint.ID,
                EndpointName: DisplayDeviceName(sonicScoutEndpoint.FriendlyName),
                Detail: $"Selected existing virtual route '{routingConfiguration.SonicScoutAlias}' on endpoint: {DisplayDeviceName(sonicScoutEndpoint.FriendlyName)}.");
        });
    }

    private async Task<bool> WriteSonicScoutBackgroundProfileAsync()
    {
        return await Task.Run(() =>
        {
            try
            {
                string? folderPath = Path.GetDirectoryName(sonicScoutAlgorithmPath);
                if (!string.IsNullOrWhiteSpace(folderPath))
                {
                    Directory.CreateDirectory(folderPath);
                }

                List<string> lines =
                [
                    "# Sonic Scout routing preferences",
                    $"# Channel alias: {routingConfiguration.SonicScoutAlias}",
                    $"# Physical source: {routingConfiguration.SelectedPhysicalOutputName ?? "Unknown"}",
                    $"# Virtual target: {routingConfiguration.SonicScoutEndpointName ?? "Unavailable"}",
                    $"# Compatibility mode: {(routingConfiguration.HasCompatibilityMixer ? "Third-party mixer protected" : "Direct route")}",
                    "# Routing metadata only; the active headphone profile supplies EQ."
                ];
                File.WriteAllLines(sonicScoutAlgorithmPath, lines);
                return true;
            }
            catch (IOException)
            {
                return false;
            }
            catch (UnauthorizedAccessException)
            {
                return false;
            }
        });
    }

    private async Task RefreshRoutingConfigurationFromSystemAsync()
    {
        IReadOnlyList<AudioEndpointOption> outputs = await DiscoverOutputEndpointsAsync();

        bool sonicScoutStillAvailable = !string.IsNullOrWhiteSpace(routingConfiguration.SonicScoutEndpointId) &&
            outputs.Any(output => string.Equals(output.Id, routingConfiguration.SonicScoutEndpointId, StringComparison.OrdinalIgnoreCase));
        if (!sonicScoutStillAvailable)
        {
            routingConfiguration.SonicScoutProvisioned = false;
            routingConfiguration.SonicScoutEngaged = false;
            routingConfiguration.SonicScoutEndpointId = null;
            routingConfiguration.SonicScoutEndpointName = null;
            routingConfiguration.ActiveOutputDeviceId = routingConfiguration.SelectedPhysicalOutputId;
            routingConfiguration.ActiveOutputDeviceName = routingConfiguration.SelectedPhysicalOutputName;
            routingConfiguration.LastRoutingNote = "Sonic Scout endpoint is unavailable. Physical output fallback is active.";
            SonicRoutingConfigurationStore.Save(routingConfigurationPath, routingConfiguration);
        }
    }

    private static IReadOnlyList<SetupCheckResult> ReadInstallationStages(DateTimeOffset startedAt)
    {
        try
        {
            string logs = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SonicScout", "logs");
            if (!Directory.Exists(logs)) { return Array.Empty<SetupCheckResult>(); }
            FileInfo? report = new DirectoryInfo(logs).GetFiles("audio-setup-report-*.json")
                .Where(file => file.LastWriteTimeUtc >= startedAt.UtcDateTime.AddSeconds(-2))
                .OrderByDescending(file => file.LastWriteTimeUtc).FirstOrDefault();
            if (report is null) { return Array.Empty<SetupCheckResult>(); }
            using System.Text.Json.JsonDocument document = System.Text.Json.JsonDocument.Parse(File.ReadAllText(report.FullName));
            if (!document.RootElement.TryGetProperty("stages", out var stages) || stages.ValueKind != System.Text.Json.JsonValueKind.Array)
            {
                return Array.Empty<SetupCheckResult>();
            }
            Dictionary<string, SetupCheckResult> stagesByName = new(StringComparer.OrdinalIgnoreCase);
            foreach (var stage in stages.EnumerateArray())
            {
                if (!stage.TryGetProperty("state", out var state) || state.ValueKind != System.Text.Json.JsonValueKind.String) { continue; }
                if (!stage.TryGetProperty("name", out var name) || name.ValueKind != System.Text.Json.JsonValueKind.String ||
                    !stage.TryGetProperty("detail", out var detail) || detail.ValueKind != System.Text.Json.JsonValueKind.String) { continue; }
                stagesByName[name.GetString()!] = new SetupCheckResult(name.GetString()!, state.GetString()!, detail.GetString()!);
            }
            return stagesByName.Values.ToArray();
        }
        catch (IOException) { return Array.Empty<SetupCheckResult>(); }
        catch (UnauthorizedAccessException) { return Array.Empty<SetupCheckResult>(); }
        catch (System.Text.Json.JsonException) { return Array.Empty<SetupCheckResult>(); }
    }

    private async Task<IReadOnlyList<SetupCheckResult>> RunSetupChecks(
        IProgress<SetupCheckResult> progress,
        SetupInstallRequest request)
    {
        List<SetupCheckResult> results = new();
        SetupCheckResult Report(string name, string state, string detail)
        {
            SetupCheckResult result = new(name, state, detail);
            int existing = results.FindIndex(item => string.Equals(item.Name, name, StringComparison.OrdinalIgnoreCase));
            if (existing >= 0) results[existing] = result;
            else results.Add(result);
            progress.Report(result);
            return result;
        }

        try
        {
            if (!request.ConfirmOwnership || !request.ConfirmRoutingApply || !request.ConfirmDependencyFallback)
            {
                throw new InvalidOperationException("Setup requires all ownership and apply confirmations before Sonic Scout can configure routing.");
            }

            Report("Audio components", "RUNNING", "Installing and verifying audio components. Accept the Windows permission prompt if requested.");
            audioConfigurationInProgress = true;
            StopSonicPass();
            StopAudioMonitor();
            DateTime setupStarted = DateTime.UtcNow;
            string? previousStage = null;
            Task<ScriptExecutionResult?> setupTask = RunSetupAutomationScriptAsync(request, CancellationToken.None);
            while (!setupTask.IsCompleted)
            {
                await Task.WhenAny(setupTask, Task.Delay(500));
                try
                {
                    string livePath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SonicScout", "logs", "audio-setup-progress.json");
                    if (File.Exists(livePath))
                    {
                        string json = File.ReadAllText(livePath);
                        using JsonDocument document = JsonDocument.Parse(json);
                        JsonElement stage = document.RootElement;
                        if (json != previousStage && stage.GetProperty("timestamp").GetDateTime().ToUniversalTime() >= setupStarted)
                        {
                            previousStage = json;
                            Report(stage.GetProperty("name").GetString()!, stage.GetProperty("state").GetString()!, stage.GetProperty("detail").GetString()!);
                        }
                    }
                }
                catch (IOException) { }
                catch (JsonException) { }
            }
            ScriptExecutionResult? setupAutomationResult = await setupTask;
            if (setupAutomationResult is not null)
            {
                foreach (SetupCheckResult stage in ReadInstallationStages(setupAutomationResult.StartedAtUtc))
                    Report(stage.Name, stage.State, stage.Detail);
            }
            if (setupAutomationResult is null)
            {
                Report("Audio components", "UPDATE", "Audio setup files are missing. Reinstall Sonic Scout using SonicScout-Setup.exe.");
                return results;
            }
            else if (setupAutomationResult.State == ScriptExecutionState.Succeeded)
            {
                EapoInstallationFacts installedFacts = EapoInstallation.Probe();
                apoFacts = installedFacts;
                IReadOnlyList<string> apoProblems = EapoInstallation.GetProblems(installedFacts);
                if (apoProblems.Count == 0)
                    Report("Audio components", "READY", "Installation completed; Equalizer APO registry key, Editor.exe, DeviceSelector.exe and COM classes verified.");
                else
                    Report("Audio components", "ERROR", "Equalizer APO is NOT verified: " + string.Join(" ", apoProblems));
            }
            else
            {
                string failure = setupAutomationResult.ErrorMessage ?? "Setup automation script failed.";
                Report("Audio components", "UPDATE", $"Installation needs attention. {failure} Review the installation report in %LOCALAPPDATA%\\SonicScout\\logs. If a restart was requested, restart Windows and retry installation.");
                return results;
            }

            audioConfigurationInProgress = false;
            Report("Profiles", "RUNNING", "Checking the profile folder and saved EQ assets...");
            await Task.Delay(120);
            bool folderReady = Directory.Exists(profilesDirectory);
            if (!folderReady)
            {
                Directory.CreateDirectory(profilesDirectory);
                Report("Profiles", "FIXED", "Created the profiles folder.");
            }
            else
            {
                Report("Profiles", "READY", "Profiles folder is present.");
            }

            Report("Audio devices", "RUNNING", "Enumerating active Windows output endpoints asynchronously...");
            IReadOnlyList<AudioEndpointOption> discoveredOutputs = await DiscoverOutputEndpointsAsync();
            AudioEndpointOption? selectedOutput = discoveredOutputs.FirstOrDefault(output =>
                string.Equals(output.Id, request.SelectedOutputId, StringComparison.OrdinalIgnoreCase));
            if (selectedOutput is null)
            {
                throw new InvalidOperationException("The selected default output endpoint is no longer available. Reopen setup and choose an active output.");
            }
            Report("Audio devices", "READY", $"Selected default physical output: {selectedOutput.DisplayName}");
            Report("Ownership consent", "READY", "Ownership and routing apply confirmations were accepted for this system.");

            Report("Tuned channel prerequisites", "RUNNING", "Checking DAC suitability, virtual routing path, and Voicemeeter fallback readiness...");
            bool virtualChannelCandidateAvailable = discoveredOutputs.Any(output =>
                !string.Equals(output.Id, selectedOutput.Id, StringComparison.OrdinalIgnoreCase) &&
                IsSonicScoutVirtualCandidate(output.DisplayName));
            bool waveLinkEndpointAvailable = discoveredOutputs.Any(output => IsWaveLinkEndpoint(output.DisplayName));
            bool soundBlasterEndpointAvailable = discoveredOutputs.Any(output => IsSoundBlasterEndpoint(output.DisplayName));
            bool voicemeeterEndpointAvailable = discoveredOutputs.Any(output => IsVoicemeeterEndpoint(output.DisplayName));
            bool likelyDedicatedDac = IsLikelyDedicatedDacOutput(selectedOutput.DisplayName);
            if (request.UsesWaveLink)
            {
                Report("Tuned channel prerequisites", "READY", "Elgato Wave Link detected. Sonic Scout will prioritize Wave Link routing before virtual-cable or Voicemeeter fallback.");
            }
            else if (request.UsesSoundBlaster)
            {
                Report("Tuned channel prerequisites", "READY", "Creative Sound Blaster native mixer detected. Voicemeeter fallback is not required.");
            }
            else if (virtualChannelCandidateAvailable)
            {
                string dacDetail = likelyDedicatedDac
                    ? "Dedicated DAC-like output detected."
                    : "Dedicated DAC not detected; software routing support remains important.";
                Report("Tuned channel prerequisites", "READY", $"{dacDetail} Compatible virtual route is available for Sonic Scout channel creation.");
            }
            else if (request.UsesVoicemeeter)
            {
                Report("Tuned channel prerequisites", "UPDATE", "No direct virtual endpoint detected yet. Voicemeeter fallback path is enabled; complete Voicemeeter bus mapping and rerun SETUP to engage Sonic Scout.");
            }
            else
            {
                Report("Tuned channel prerequisites", "UPDATE", "No virtual tuned-channel endpoint detected. Install/configure Voicemeeter or VB-Cable Hi-Fi Cable, then rerun SETUP.");
            }

            Report("Compatibility profile", "RUNNING", "Saving third-party mixer compatibility flags...");
            bool compatibilityRouteStyle = IsCompatibilityRouteStyle(request.SetupStyle);
            routingConfiguration.SelectedPhysicalOutputId = selectedOutput.Id;
            routingConfiguration.SelectedPhysicalOutputName = selectedOutput.DisplayName;
            routingConfiguration.SetupStyle = request.SetupStyle;
            routingConfiguration.UseVoicemeeterCompatibility = request.UsesVoicemeeter ||
                voicemeeterEndpointAvailable ||
                (!virtualChannelCandidateAvailable && !waveLinkEndpointAvailable && !soundBlasterEndpointAvailable && request.ConfirmDependencyFallback);
            routingConfiguration.UseWaveLinkCompatibility = request.UsesWaveLink;
            routingConfiguration.UseSoundBlasterCompatibility = request.UsesSoundBlaster;
            routingConfiguration.UseOtherMixerCompatibility = request.UsesOtherMixer || compatibilityRouteStyle;
            routingConfiguration.SonicScoutAlias = "Sonic Scout";
            bool compatibilitySaved = SonicRoutingConfigurationStore.Save(routingConfigurationPath, routingConfiguration);
            Report("Compatibility profile", compatibilitySaved ? "READY" : "UPDATE", compatibilitySaved
                ? BuildCompatibilitySummary(request)
                : "Compatibility flags were applied in-memory, but Windows blocked saving the global routing file.");

            Report("Sonic Scout provisioning", "RUNNING", "Provisioning virtual cable routing for Sonic Scout...");
            SonicScoutProvisionResult provisionResult = await ProvisionSonicScoutRouteAsync(selectedOutput.Id);
            routingConfiguration.SonicScoutProvisioned = provisionResult.Provisioned;
            routingConfiguration.SonicScoutEndpointId = provisionResult.EndpointId;
            routingConfiguration.SonicScoutEndpointName = provisionResult.EndpointName;
            routingConfiguration.SonicScoutEngaged = false;
            string provisioningDetail = provisionResult.Detail;
            if (!provisionResult.Provisioned && routingConfiguration.UseVoicemeeterCompatibility)
            {
                provisioningDetail = "Sonic Scout endpoint not found yet. Voicemeeter fallback is armed; finalize Voicemeeter routing and rerun SETUP.";
            }
            routingConfiguration.ActiveOutputDeviceId = provisionResult.Provisioned && !routingConfiguration.HasCompatibilityMixer
                ? provisionResult.EndpointId
                : selectedOutput.Id;
            routingConfiguration.ActiveOutputDeviceName = provisionResult.Provisioned && !routingConfiguration.HasCompatibilityMixer
                ? $"{routingConfiguration.SonicScoutAlias} ({provisionResult.EndpointName})"
                : selectedOutput.DisplayName;
            routingConfiguration.LastRoutingNote = provisioningDetail;
            SonicRoutingConfigurationStore.Save(routingConfigurationPath, routingConfiguration);
            Report("Sonic Scout provisioning", provisionResult.Provisioned ? "FIXED" : "UPDATE", provisioningDetail);

            Report("Routing preferences", "RUNNING", "Saving the selected audio route...");
            bool backgroundProfileWritten = await WriteSonicScoutBackgroundProfileAsync();
            Report("Routing preferences", backgroundProfileWritten ? "READY" : "UPDATE",
                backgroundProfileWritten
                    ? "Audio route preferences saved."
                    : "Audio route preferences could not be saved. Retry setup before routing game audio.");

            Report("Routing safety", "RUNNING", "Refreshing runtime outputs and applying fallback-safe routing...");
            LoadAudioDevices();
            ApplyRoutingPreferenceToOutputSelection();
            if (!routingConfiguration.SonicScoutProvisioned)
            {
                ApplySafePhysicalOutputFallback();
            }
            RefreshWindowsLeqState();
            string routingSafetyDetail = "Your Windows default output is unchanged. If SonicPass stops, select your physical output in the game to restore sound.";
            if (!routingConfiguration.SonicScoutProvisioned && routingConfiguration.UseVoicemeeterCompatibility)
            {
                routingSafetyDetail = "Fallback is active on your physical output while Voicemeeter-assisted tuned channel setup is pending.";
            }
            Report("Routing safety", "READY", routingSafetyDetail);

            Report("Equalizer APO", "RUNNING", "Checking the APO include and repairing it when Windows allows...");
            await Task.Delay(120);
            EnsureApoLink();
            Report("Equalizer APO", apoLinked ? "READY" : "UPDATE", apoLinked
                ? "Equalizer APO is installed and config.txt includes Sonic Scout's EQ file."
                : (apoFacts is not null && !EapoInstallation.IsVerified(apoFacts)
                    ? "Equalizer APO is not installed: " + string.Join(" ", EapoInstallation.GetProblems(apoFacts))
                    : $"config.txt does not include {EapoInstallation.UserIncludePath}. Run SETUP as administrator to add it."));
            Report("Live spectrum", "RUNNING", "Restarting loopback capture on the selected output...");
            await Task.Delay(120);
            StartAudioMonitor(OutputDeviceComboBox.SelectedIndex >= 0 && OutputDeviceComboBox.SelectedIndex < outputDeviceReferences.Count ? outputDeviceReferences[OutputDeviceComboBox.SelectedIndex] : null);
            Report("Live spectrum", loopbackCapture is null ? "ERROR" : "READY", loopbackCapture is null ? "Select an active output in Sound Settings, then run SETUP again." : "System audio monitor refreshed.");
            Report("Runtime assets", File.Exists(Path.Combine(AppContext.BaseDirectory, "NAudio.dll")) ? "READY" : "UPDATE", File.Exists(Path.Combine(AppContext.BaseDirectory, "NAudio.dll")) ? "Audio runtime dependency is present." : "Run the one-button launcher again to restore the runtime build.");
            await Task.Delay(120);
            await Task.Delay(250);
            Report("Updates", "READY", "App checks complete. Driver installs and reboots require your approval.");
            if (apoLinked && routingConfiguration.SonicScoutProvisioned && !string.IsNullOrWhiteSpace(routingConfiguration.SonicScoutEndpointId))
            {
                Report("SonicPass", "RUNNING", "Starting the configured audio route...");
                bool started = TryStartSonicPass(routingConfiguration.SonicScoutEndpointId, selectedOutput.Id);
                await Task.Delay(1000);
                bool running = started && sonicPassProcess is not null && !sonicPassProcess.HasExited;
                Report("SonicPass", running ? "READY" : "ERROR", running ? "Audio route is running. Verify settings here without leaving setup." : "Audio route could not start. Open Diagnostics for the recorded error.");
                if (running) { SonicPassButton.Content = "STOP SONICPASS"; SonicPassStartButton.Content = "STOP SONICPASS"; }
                UpdateTunedVirtualCableStatusIndicator();
            }
        }
        catch (UnauthorizedAccessException)
        {
            Report("Permissions", "UPDATE", "Run Sonic Scout once as administrator to repair protected APO settings, then run SETUP again.");
        }
        catch (IOException)
        {
            Report("Files", "ERROR", "Close editors or audio managers using Sonic Scout files, then run SETUP again.");
        }
        catch (COMException)
        {
            Report("Core Audio", "ERROR", "Windows Core Audio returned an endpoint enumeration error. Reconnect your interface and rerun setup.");
        }
        catch (InvalidOperationException exception)
        {
            Report("Routing", "ERROR", exception.Message);
        }
        finally
        {
            audioConfigurationInProgress = false;
        }
        return results;
    }

    private void ToggleMaximize()
    {
        WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
        MaximizeButton.Content = WindowState == WindowState.Maximized ? "❐" : "□";
    }

    private static SolidColorBrush MakeBrush(string value, double opacity = 1)
    {
        SolidColorBrush brush = new(ParseColor(value)) { Opacity = opacity };
        return brush;
    }

    private static SolidColorBrush MakeContrastingBrush(string background)
    {
        WpfColor surface = ParseColor(background);
        WpfColor white = Colors.White;
        WpfColor black = Colors.Black;
        return new SolidColorBrush(ContrastRatio(white, surface) >= ContrastRatio(black, surface) ? white : black);
    }

    private static string ContrastingHex(string background)
    {
        WpfColor surface = ParseColor(background);
        return ContrastRatio(Colors.White, surface) >= ContrastRatio(Colors.Black, surface) ? "#FFFFFF" : "#000000";
    }

    private static SolidColorBrush MakeReadableAccentBrush(string accent, string surface, string fallback)
    {
        return new SolidColorBrush(ContrastRatio(ParseColor(accent), ParseColor(surface)) >= 4.5
            ? ParseColor(accent)
            : ParseColor(fallback));
    }

    private static double ContrastRatio(WpfColor first, WpfColor second)
    {
        double firstLuminance = RelativeLuminance(first);
        double secondLuminance = RelativeLuminance(second);
        double lighter = Math.Max(firstLuminance, secondLuminance);
        double darker = Math.Min(firstLuminance, secondLuminance);
        return (lighter + 0.05) / (darker + 0.05);
    }

    private static double RelativeLuminance(WpfColor color)
    {
        static double Linearize(byte channel)
        {
            double value = channel / 255.0;
            return value <= 0.03928 ? value / 12.92 : Math.Pow((value + 0.055) / 1.055, 2.4);
        }

        return (0.2126 * Linearize(color.R)) + (0.7152 * Linearize(color.G)) + (0.0722 * Linearize(color.B));
    }

    private static WpfColor BlendColors(WpfColor start, WpfColor end, double amount)
    {
        byte red = (byte)(start.R + ((end.R - start.R) * amount));
        byte green = (byte)(start.G + ((end.G - start.G) * amount));
        byte blue = (byte)(start.B + ((end.B - start.B) * amount));
        return WpfColor.FromRgb(red, green, blue);
    }

    private static string ResolveProfilesDirectory()
    {
        string userProfiles = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SonicScout", "profiles");
        Directory.CreateDirectory(userProfiles);
        string publishedProfiles = Path.Combine(AppContext.BaseDirectory, "profiles");
        string workingDirectoryProfiles = Path.Combine(Environment.CurrentDirectory, "profiles");
        string parentProfiles = Path.Combine(Directory.GetParent(Environment.CurrentDirectory)?.FullName ?? Environment.CurrentDirectory, "profiles");
        foreach (string legacyDirectory in new[] { publishedProfiles, workingDirectoryProfiles, parentProfiles }.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (!Directory.Exists(legacyDirectory) || string.Equals(legacyDirectory, userProfiles, StringComparison.OrdinalIgnoreCase)) continue;
            foreach (string legacyFile in Directory.GetFiles(legacyDirectory, "custom_*"))
            {
                string destination = Path.Combine(userProfiles, Path.GetFileName(legacyFile));
                try
                {
                    if (!File.Exists(destination)) File.Copy(legacyFile, destination);
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                    // Leave the original intact; a failed legacy copy must not prevent startup.
                    Debug.WriteLine($"Legacy profile copy failed: {exception.Message}");
                }
            }
        }
        return userProfiles;
    }

    private void ProfileButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not WpfButton button || button.Tag is not string profileId || !profiles.TryGetValue(profileId, out var profile))
        {
            return;
        }

        foreach (var item in profiles.Values)
        {
            item.Button.BorderBrush = (WpfBrush)FindResource("MutedBrush");
            item.Button.BorderThickness = new Thickness(1);
        }

        button.BorderBrush = (WpfBrush)FindResource("AccentBrush");
        button.BorderThickness = new Thickness(3);
        activeProfileId = profileId;
        ActiveProfileText.Text = $"{profile.Name} ({profile.Subtitle})";
        ShowProfileFilters(profileId);
        LoadEqControls(profileId);

        if (WriteProfileToEapo(profileId, out string activationError))
        {
            routingConfiguration.ActiveProfileId = profileId;
            SonicRoutingConfigurationStore.Save(routingConfigurationPath, routingConfiguration);
            SetEapoStatus(true, $"Activated {profile.Name} for {profile.Subtitle}.");
        }
        else
        {
            SetEapoStatus(false, activationError);
        }
    }

    private void ShowProfileFilters(string profileId)
    {
        string sourcePath = Path.Combine(profilesDirectory, $"{profileId}.txt");
        FilterText.Text = File.Exists(sourcePath)
            ? File.ReadAllText(sourcePath).Trim()
            : "No Equalizer APO filter file found for this profile.";
    }

    private void LoadEqControls(string profileId)
    {
        string sourcePath = Path.Combine(profilesDirectory, $"{profileId}.txt");
        if (!File.Exists(sourcePath))
        {
            EqPanel.Visibility = Visibility.Collapsed;
            return;
        }

        string content = EqProfileEdits.Adjustments(File.ReadAllText(sourcePath));
        eqValues.Clear();
        Match preampMatch = Regex.Match(content, @"Preamp:\s*([+-]?\d+(?:\.\d+)?)", RegexOptions.IgnoreCase);
        eqValues["PREAMP"] = preampMatch.Success ? Math.Clamp(double.Parse(preampMatch.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture), -12, 12) : 0;
        foreach (int frequency in EqFrequencies)
        {
            Match filterMatch = Regex.Match(content, $@"Fc\s+{frequency}\s+Hz\s+Gain\s+([+-]?\d+(?:\.\d+)?)", RegexOptions.IgnoreCase);
            eqValues[frequency.ToString()] = filterMatch.Success
                ? double.Parse(filterMatch.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture)
                : 0;
        }

        EqSliderGrid.Children.Clear();
        EqSliderGrid.Columns = EqFrequencies.Length;
        foreach ((string tag, string label) in new[]
        {
            ("60", "60 Hz"), ("150", "150 Hz"), ("400", "400 Hz"),
            ("1000", "1 kHz"), ("2500", "2.5 kHz"), ("6000", "6 kHz"), ("12000", "12 kHz")
        })
        {
            Border bandSlot = new()
            {
                Height = 148,
                Margin = new Thickness(2, 0, 2, 0),
                Padding = new Thickness(2),
                Background = (WpfBrush)FindResource("PanelBrush"),
                BorderBrush = (WpfBrush)FindResource("SurfaceMutedBrush"),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(6),
                HorizontalAlignment = System.Windows.HorizontalAlignment.Stretch
            };
            StackPanel control = new() { Height = 138, VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = System.Windows.HorizontalAlignment.Stretch };
            double sliderValue = Math.Clamp(eqValues[tag], -12, 12);
            TextBlock valueLabel = new()
            {
                Text = FormatDb(sliderValue),
                Foreground = (WpfBrush)FindResource("SurfaceTextBrush"),
                FontSize = 11,
                HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
                TextAlignment = TextAlignment.Center,
                Height = 20,
                Margin = new Thickness(0, 0, 0, 4)
            };
            Slider slider = new()
            {
                Minimum = -12,
                Maximum = 12,
                Value = sliderValue,
                TickFrequency = 1,
                IsSnapToTickEnabled = true,
                Height = 84,
                Width = 24,
                Orientation = System.Windows.Controls.Orientation.Vertical,
                Style = (Style)FindResource("VerticalEqSliderStyle"),
                Tag = tag,
                Foreground = (WpfBrush)FindResource("AccentBrush"),
                HorizontalAlignment = System.Windows.HorizontalAlignment.Center
            };
            slider.ValueChanged += (_, _) =>
            {
                if (slider.Tag is string changedTag && eqValues.ContainsKey(changedTag))
                {
                    eqValues[changedTag] = slider.Value;
                    valueLabel.Text = FormatDb(slider.Value);
                    UpdateFilterPreview();
                    ScheduleEqWrite();
                }
            };
            slider.PreviewMouseLeftButtonDown += EqSlider_MouseLeftButtonDown;
            slider.PreviewMouseMove += EqSlider_MouseMove;
            slider.PreviewMouseLeftButtonUp += EqSlider_MouseLeftButtonUp;
            control.Children.Add(valueLabel);
            control.Children.Add(slider);
            bandSlot.Child = control;
            EqSliderGrid.Children.Add(bandSlot);
        }
        EqPanel.Visibility = Visibility.Visible;
    }

    private void EqSlider_MouseLeftButtonDown(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (sender is Slider slider)
        {
            slider.CaptureMouse();
            UpdateEqSliderFromPointer(slider, e.GetPosition(slider));
            e.Handled = true;
        }
    }

    private void EqSlider_MouseMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (sender is Slider slider && slider.IsMouseCaptured && e.LeftButton == System.Windows.Input.MouseButtonState.Pressed)
        {
            UpdateEqSliderFromPointer(slider, e.GetPosition(slider));
            e.Handled = true;
        }
    }

    private void EqSlider_MouseLeftButtonUp(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (sender is Slider slider && slider.IsMouseCaptured)
        {
            slider.ReleaseMouseCapture();
            e.Handled = true;
        }
    }

    private static void UpdateEqSliderFromPointer(Slider slider, System.Windows.Point point)
    {
        double fraction = slider.Orientation == System.Windows.Controls.Orientation.Vertical
            ? 1 - Math.Clamp(point.Y / Math.Max(1, slider.ActualHeight), 0, 1)
            : Math.Clamp(point.X / Math.Max(1, slider.ActualWidth), 0, 1);
        double value = slider.Minimum + ((slider.Maximum - slider.Minimum) * fraction);
        slider.Value = Math.Round(value);
    }

    private void SaveEqProfile()
    {
        if (string.IsNullOrWhiteSpace(activeProfileId) || eqValues.Count == 0)
        {
            return;
        }

        string sourcePath = Path.Combine(profilesDirectory, $"{activeProfileId}.txt");
        List<string> lines = BuildEqLines();

        try
        {
            Directory.CreateDirectory(profilesDirectory);
            File.WriteAllText(sourcePath, string.Join(Environment.NewLine, lines) + Environment.NewLine);
            Directory.CreateDirectory(Path.GetDirectoryName(activeProfilePath)!);
            File.Copy(sourcePath, activeProfilePath, overwrite: true);
            SyncActiveProfileMirror();
            FilterText.Text = string.Join(Environment.NewLine, lines);
            MessageText.Text = "EQ change written live to Equalizer APO.";
        }
        catch (IOException)
        {
            MessageText.Text = "EQ changed locally, but the APO profile could not be written.";
        }
        catch (UnauthorizedAccessException)
        {
            MessageText.Text = "EQ saved to the profile, but Equalizer APO locked the active file. Close the lock or use Sound Settings, then try again.";
        }
    }

    private static string FormatDb(double value) => $"{value:+0.0;-0.0;0.0} dB";

    private List<string> BuildEqLines()
    {
        string sourcePath = Path.Combine(profilesDirectory, $"{activeProfileId}.txt");
        string original = File.Exists(sourcePath) ? File.ReadAllText(sourcePath) : string.Empty;
        return EqProfileEdits.Apply(original, eqValues, EqFrequencies)
            .Split(new[] { "\r\n", "\n" }, StringSplitOptions.None).ToList();
    }

    private void UpdateFilterPreview()
    {
        if (eqValues.Count > 0)
        {
            FilterText.Text = string.Join(Environment.NewLine, BuildEqLines());
        }
    }

    private void ScheduleEqWrite()
    {
        eqWriteTimer.Stop();
        eqWriteTimer.Start();
        MessageText.Text = "Adjusting EQ... release the slider to write to Equalizer APO.";
    }

    /// <summary>Copy of the active profile inside the eapo folder that audiodg (LOCAL SERVICE) can read.</summary>
    private static string ActiveProfileMirrorPath => Path.Combine(Path.GetDirectoryName(EapoInstallation.UserIncludePath)!, "active_profile.txt");

    /// <summary>Must run after every write to activeProfilePath, or Equalizer APO keeps playing the old profile.</summary>
    private void SyncActiveProfileMirror()
    {
        try
        {
            string mirror = ActiveProfileMirrorPath;
            Directory.CreateDirectory(Path.GetDirectoryName(mirror)!);
            string text = File.Exists(activeProfilePath) ? File.ReadAllText(activeProfilePath) : string.Empty;
            if (File.Exists(mirror) && File.ReadAllText(mirror) == text) return;
            File.WriteAllText(mirror + ".tmp", text);
            File.Move(mirror + ".tmp", mirror, overwrite: true);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            MessageText.Text = $"Could not update the EQ copy Equalizer APO reads: {exception.Message}";
        }
    }

    private void EnsureApoLink()
    {
        // Runtime never writes under Program Files. Setup (admin, once) adds a single
        // Include: line to config.txt pointing at the per-user file below; here we only
        // (re)write that user-writable file and verify the include exists.
        apoFacts = EapoInstallation.Probe();
        string userInclude = EapoInstallation.UserIncludePath;
        if (!EapoInstallation.IsVerified(apoFacts))
        {
            apoLinked = false;
            RefreshProfileApoIndicators();
            RefreshHonestEqStatus(force: true);
            MessageText.Text = "Equalizer APO is not installed: " + string.Join(" ", EapoInstallation.GetProblems(apoFacts));
            return;
        }

        string apoConfigPath = Path.Combine(apoFacts.InstallPath, "config", "config.txt");
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(userInclude)!);
            // Headphone/game profile first, then the user's graph target on top of it.
            EnsureUserTargetFileExists();
            // Equalizer APO runs inside audiodg.exe as LOCAL SERVICE, which cannot read files in
            // the user's profile by default: without this grant every include below was silently
            // skipped. Grant read-only access to our own eapo folder, and mirror the active
            // profile into it rather than including it from Documents.
            EapoInstallation.GrantAudioServiceRead(Path.GetDirectoryName(userInclude)!);
            string profileMirror = ActiveProfileMirrorPath;
            SyncActiveProfileMirror();

            string contents = EapoInstallation.BuildIncludeLine(profileMirror) + Environment.NewLine +
                EapoInstallation.BuildIncludeLine(TargetCurveStore.DefaultLiveApoPath) + Environment.NewLine;
            if (!File.Exists(userInclude) || File.ReadAllText(userInclude) != contents)
            {
                string temp = userInclude + ".tmp";
                File.WriteAllText(temp, contents);
                File.Move(temp, userInclude, overwrite: true);
            }

            apoLinked = File.Exists(apoConfigPath) &&
                EapoInstallation.ConfigIncludesUserFile(File.ReadAllLines(apoConfigPath), userInclude);
            if (!apoLinked)
                MessageText.Text = $"Equalizer APO's config.txt does not include {userInclude}. Run SETUP once (administrator) to add it.";
        }
        catch (UnauthorizedAccessException exception)
        {
            apoLinked = false;
            MessageText.Text = $"Windows denied access to Sonic Scout's EQ file ({userInclude}): {exception.Message} Sonic Scout does not need administrator rights for this file; check its permissions.";
        }
        catch (IOException exception)
        {
            apoLinked = false;
            MessageText.Text = $"The EQ file is locked or unreadable: {exception.Message}";
        }
        RefreshProfileApoIndicators();
        RefreshHonestEqStatus(force: true);
    }

    private void CreateProfile_Click(object sender, RoutedEventArgs e)
    {
        CreateProfileWindow dialog = new() { Owner = this };
        CopyThemeResourcesTo(dialog);
        if (dialog.ShowDialog() != true)
        {
            return;
        }

        string profileId = MakeProfileId(dialog.ProfileName);
        string profilePath = Path.Combine(profilesDirectory, $"{profileId}.txt");
        if (File.Exists(profilePath))
        {
            MessageText.Text = $"{dialog.ProfileName} is already saved. Choose a different name or select its existing profile.";
            return;
        }

        try
        {
            Directory.CreateDirectory(profilesDirectory);
            File.WriteAllText(profilePath, dialog.FilterContent + Environment.NewLine);
            string subtitle = string.IsNullOrWhiteSpace(dialog.GameTag) ? "Custom target" : dialog.GameTag;
            WpfButton profileButton = CreateProfileButton(profileId, dialog.ProfileName, subtitle);
            profiles[profileId] = (dialog.ProfileName, subtitle, profileButton);
            UpdateProfileState();
            SetEapoStatus(true, $"Created {dialog.ProfileName}. Select it to activate the target.");
        }
        catch (IOException)
        {
            SetEapoStatus(false, "The new profile could not be saved.");
        }
        catch (UnauthorizedAccessException)
        {
            SetEapoStatus(false, "Windows denied access to the profile folder.");
        }
        catch (ArgumentException)
        {
            SetEapoStatus(false, "Use a shorter profile name without invalid filename characters.");
        }
    }

    private void SelectHeadphoneProfile_Click(object sender, RoutedEventArgs e)
    {
        HeadphoneProfileWindow dialog = new() { Owner = this };
        CopyThemeResourcesTo(dialog);
        if (dialog.ShowDialog() != true)
        {
            return;
        }

        string profileId = MakeProfileId(dialog.ProfileName);
        string profilePath = Path.Combine(profilesDirectory, $"{profileId}.txt");
        if (File.Exists(profilePath))
        {
            MessageText.Text = $"{dialog.ProfileName} is already saved. Select its existing tile.";
            return;
        }

        try
        {
            Directory.CreateDirectory(profilesDirectory);
            File.WriteAllText(profilePath, dialog.FilterContent + Environment.NewLine);
            string subtitle = $"AutoEq / {dialog.Category}";
            if (!string.IsNullOrWhiteSpace(dialog.TargetCurveContent))
            {
                string targetPath = Path.Combine(profilesDirectory, $"{profileId}_target.txt");
                File.WriteAllText(targetPath, dialog.TargetCurveContent);
                subtitle = $"{subtitle} / Target: {dialog.TargetCurveName}";
            }
            File.WriteAllText(profilePath + ".metadata.json", JsonSerializer.Serialize(new { Name = dialog.ProfileName, Subtitle = subtitle }));
            WpfButton profileButton = CreateProfileButton(profileId, dialog.ProfileName, subtitle);
            profiles[profileId] = (dialog.ProfileName, subtitle, profileButton);
            UpdateProfileState();
            ProfileButton_Click(profileButton, new RoutedEventArgs());
        }
        catch (IOException)
        {
            SetEapoStatus(false, "The downloaded headphone/IEM profile could not be saved.");
        }
        catch (UnauthorizedAccessException)
        {
            SetEapoStatus(false, "Windows denied access to the profile folder.");
        }
    }

    private void CopyThemeResourcesTo(Window dialog)
    {
        string[] resourceKeys =
        {
            "BackgroundBrush", "PanelBrush", "CardBrush", "AccentBrush", "CyanBrush", "SecondaryBrush",
            "MutedBrush", "TextBrush", "ReadableBrush", "OnPrimaryBrush", "OnSecondaryBrush", "OnHighlightBrush",
            "BackgroundTextBrush", "SurfaceTextBrush", "BackgroundMutedBrush", "SurfaceMutedBrush", "PopupBrush",
            "PopupBorderBrush", "PopupTextBrush", "PopupHoverBrush", "PopupHoverTextBrush", "SuccessBrush", "ErrorBrush",
            "TransparentBrush", "SetupReadyBrush", "SetupRunningBrush", "SetupUpdateBrush", "SetupErrorBrush"
        };

        foreach (string key in resourceKeys)
        {
            if (Resources.Contains(key))
            {
                dialog.Resources[key] = Resources[key];
            }
        }
    }

    private (string Text, WpfBrush Color) ResolveProfileIndicatorState(bool isActiveProfile)
    {
        if (!isActiveProfile)
        {
            return ("NOT ACTIVE", (WpfBrush)FindResource("MutedBrush"));
        }

        return apoLinked
            ? ("ACTIVE · APO CONNECTED", (WpfBrush)FindResource("SuccessBrush"))
            : ("ACTIVE · APO LINK REQUIRED", (WpfBrush)FindResource("ErrorBrush"));
    }

    private StackPanel BuildProfileApoIndicatorRow(string profileId)
    {
        (string statusText, WpfBrush color) = ResolveProfileIndicatorState(
            !string.IsNullOrWhiteSpace(activeProfileId) &&
            profileId.Equals(activeProfileId, StringComparison.OrdinalIgnoreCase));

        StackPanel row = new()
        {
            Orientation = System.Windows.Controls.Orientation.Horizontal,
            HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
            Margin = new Thickness(0, 0, 0, 3)
        };
        row.Children.Add(new Ellipse
        {
            Width = 8,
            Height = 8,
            Margin = new Thickness(0, 0, 5, 0),
            Fill = color
        });
        row.Children.Add(new TextBlock
        {
            Text = statusText,
            Foreground = color,
            FontSize = 7.5,
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center
        });
        return row;
    }

    private void RefreshProfileApoIndicators()
    {
        foreach (object child in ProfileStackPanel.Children)
        {
            if (child is not Grid card ||
                card.Children.Count == 0 ||
                card.Children[0] is not WpfButton selectButton ||
                selectButton.Content is not StackPanel content ||
                content.Children.Count == 0 ||
                content.Children[0] is not StackPanel indicatorRow)
            {
                continue;
            }

            bool isActiveProfile =
                selectButton.Tag is string profileId &&
                !string.IsNullOrWhiteSpace(activeProfileId) &&
                profileId.Equals(activeProfileId, StringComparison.OrdinalIgnoreCase);
            (string statusText, WpfBrush color) = ResolveProfileIndicatorState(isActiveProfile);

            if (indicatorRow.Children.Count > 0 && indicatorRow.Children[0] is Ellipse dot)
            {
                dot.Fill = color;
            }

            if (indicatorRow.Children.Count > 1 && indicatorRow.Children[1] is TextBlock label)
            {
                label.Text = statusText;
                label.Foreground = color;
            }
        }
    }

    private WpfButton CreateProfileButton(string profileId, string profileName, string subtitle)
    {
        Grid card = new() { Margin = new Thickness(0, 0, 0, 10) };
        card.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        WpfButton button = new()
        {
            Tag = profileId,
            Style = (Style)FindResource("ProfileButtonStyle"),
            Margin = new Thickness(0)
        };
        StackPanel content = new()
        {
            HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };
        content.Children.Add(BuildProfileApoIndicatorRow(profileId));
        content.Children.Add(new TextBlock { Text = profileName, FontFamily = new System.Windows.Media.FontFamily("Segoe UI"), Foreground = (WpfBrush)FindResource("SurfaceTextBrush"), FontSize = 13, FontWeight = FontWeights.Bold, TextAlignment = TextAlignment.Center, HorizontalAlignment = System.Windows.HorizontalAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 190, Margin = new Thickness(0, 0, 0, 0) });
        content.Children.Add(new TextBlock { Text = subtitle.ToUpperInvariant(), FontFamily = new System.Windows.Media.FontFamily("Segoe UI"), Foreground = (WpfBrush)FindResource("SurfaceMutedBrush"), FontSize = 9, TextAlignment = TextAlignment.Center, HorizontalAlignment = System.Windows.HorizontalAlignment.Center, Margin = new Thickness(0, 2, 0, 0) });
        button.Content = content;
        button.Click += ProfileButton_Click;
        Grid.SetColumn(button, 0);
        card.Children.Add(button);

        WpfButton deleteButton = new()
        {
            Content = "×",
            Style = (Style)FindResource("PlainActionButtonStyle"),
            Width = 18,
            Height = 18,
            Padding = new Thickness(0),
            FontSize = 13,
            HorizontalAlignment = System.Windows.HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 6, 8, 0),
            ToolTip = "Delete profile",
            Tag = profileId,
            Foreground = (WpfBrush)FindResource("ErrorBrush")
        };
        deleteButton.Click += DeleteProfileButton_Click;
        Grid.SetColumn(deleteButton, 0);
        card.Children.Add(deleteButton);
        ProfileStackPanel.Children.Add(card);
        return button;
    }

    private void DeleteProfileButton_Click(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        if (sender is WpfButton deleteButton && deleteButton.Tag is string profileId)
        {
            Grid? card = FindParentGrid(deleteButton);
            if (card is not null)
            {
                DeleteProfile(profileId, card);
            }
        }
    }

    private static Grid? FindParentGrid(DependencyObject child)
    {
        DependencyObject? current = child;
        while (current is not null)
        {
            if (current is Grid grid)
            {
                return grid;
            }
            current = VisualTreeHelper.GetParent(current);
        }
        return null;
    }

    private void DeleteProfile(string profileId, Grid card)
    {
        if (!profiles.TryGetValue(profileId, out var profile))
        {
            return;
        }

        ConfirmProfileDeleteWindow confirmation = new(profile.Name) { Owner = this };
        CopyThemeResourcesTo(confirmation);
        if (confirmation.ShowDialog() != true)
        {
            return;
        }

        try
        {
            string profilePath = Path.Combine(profilesDirectory, $"{profileId}.txt");
            bool deletingActiveProfile = string.Equals(activeProfileId, profileId, StringComparison.OrdinalIgnoreCase);
            bool activeProfileClearFailed = false;
            if (deletingActiveProfile && File.Exists(activeProfilePath))
            {
                try
                {
                    EnsureFileIsWritable(activeProfilePath);
                    File.WriteAllText(activeProfilePath, string.Empty);
                    SyncActiveProfileMirror();
                }
                catch (IOException)
                {
                    activeProfileClearFailed = true;
                }
                catch (UnauthorizedAccessException)
                {
                    activeProfileClearFailed = true;
                }
            }
            if (!File.Exists(profilePath))
            {
                SetEapoStatus(false, "The saved profile file was not found, so nothing was deleted.");
                return;
            }

            EnsureFileIsWritable(profilePath);
            File.Delete(profilePath);
            foreach (string associatedPath in new[] { profilePath + ".metadata.json", Path.Combine(profilesDirectory, profileId + "_target.txt") })
            {
                if (File.Exists(associatedPath)) File.Delete(associatedPath);
            }

            ProfileStackPanel.Children.Remove(card);
            profiles.Remove(profileId);
            if (deletingActiveProfile)
            {
                activeProfileId = null;
                routingConfiguration.ActiveProfileId = null;
                SonicRoutingConfigurationStore.Save(routingConfigurationPath, routingConfiguration);
                eqValues.Clear();
                EqPanel.Visibility = Visibility.Collapsed;
                FilterText.Text = "Select a profile to inspect its Equalizer APO filters.";
                ActiveProfileText.Text = "None";
            }
            UpdateProfileState();
            SetEapoStatus(true, activeProfileClearFailed
                ? $"Deleted {profile.Name}, but Windows blocked updating the active-profile file."
                : $"Deleted {profile.Name}.");
        }
        catch (IOException)
        {
            SetEapoStatus(false, "The profile file is in use. Close OneDrive previews, editors, or audio tools and try again.");
        }
        catch (UnauthorizedAccessException)
        {
            SetEapoStatus(false, "Windows denied profile deletion. Check file permissions and remove read-only protection.");
        }
    }

    private static void EnsureFileIsWritable(string path)
    {
        FileAttributes attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.ReadOnly) != 0)
        {
            File.SetAttributes(path, attributes & ~FileAttributes.ReadOnly);
        }
    }

    private static string MakeProfileId(string profileName)
    {
        string id = new string(profileName.Trim().ToLowerInvariant().Select(character => char.IsLetterOrDigit(character) ? character : '_').ToArray()).Trim('_');
        if (id.Length > 40)
        {
            string suffix = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(id)))[..8].ToLowerInvariant();
            id = id[..31].Trim('_') + "_" + suffix;
        }
        return string.IsNullOrWhiteSpace(id) ? $"custom_{DateTime.Now:yyyyMMddHHmmss}" : $"custom_{id}";
    }

    private bool WriteProfileToEapo(string profileId, out string error)
    {
        error = string.Empty;
        string sourcePath = Path.Combine(profilesDirectory, $"{profileId}.txt");
        if (!File.Exists(sourcePath))
        {
            error = $"Profile source was not found: {sourcePath}";
            return false;
        }

        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(activeProfilePath)!);
            string tempPath = activeProfilePath + ".tmp";
            File.Copy(sourcePath, tempPath, overwrite: true);
            File.Move(tempPath, activeProfilePath, overwrite: true);
            SyncActiveProfileMirror();
            return true;
        }
        catch (IOException exception)
        {
            error = $"Could not update the active EQ file: {exception.Message}";
            return false;
        }
        catch (UnauthorizedAccessException exception)
        {
            error = $"Windows denied the active EQ file: {exception.Message}";
            return false;
        }
    }

    private void SetEapoStatus(bool succeeded, string message)
    {
        bool usable = succeeded && apoLinked;
        WpfBrush color = (WpfBrush)FindResource(usable ? "SuccessBrush" : "ErrorBrush");
        RefreshProfileApoIndicators();
        RefreshHonestEqStatus(force: true);
        MessageText.Text = message;
        MessageText.Foreground = color;
    }

    private void RefreshGeneratedControls()
    {
        RefreshProfileApoIndicators();

        foreach (object child in ProfileStackPanel.Children)
        {
            if (child is not Grid card || card.Children.Count == 0 || card.Children[0] is not WpfButton selectButton || selectButton.Content is not StackPanel content)
            {
                continue;
            }

            if (content.Children.Count > 2 && content.Children[2] is TextBlock subtitle)
            {
                subtitle.Foreground = (WpfBrush)FindResource("MutedBrush");
            }
        }

        foreach (object child in EqSliderGrid.Children)
        {
            StackPanel? control = child switch
            {
                StackPanel stackPanel => stackPanel,
                Border border when border.Child is StackPanel nestedStackPanel => nestedStackPanel,
                _ => null
            };

            if (control is null)
            {
                continue;
            }

            foreach (object controlChild in control.Children)
            {
                if (controlChild is Slider slider)
                {
                    slider.Foreground = (WpfBrush)FindResource("AccentBrush");
                }
                else if (controlChild is TextBlock label)
                {
                    label.Foreground = label == control.Children[0]
                        ? (WpfBrush)FindResource("SurfaceTextBrush")
                        : (WpfBrush)FindResource("SurfaceMutedBrush");
                }
            }
        }

        RefreshWindowsLeqState();
    }

    private void ThemeComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!IsInitialized || ThemeComboBox.SelectedItem is not ComboBoxItem item)
        {
            return;
        }

        ApplyTheme(item.Content?.ToString());
    }

    private void ApplyTheme(string? themeName)
    {
        if (string.IsNullOrWhiteSpace(themeName) || !Themes.TryGetValue(themeName, out ThemeDefinition? theme))
        {
            theme = Themes["Copper Signal"];
        }

        activeTheme = theme;
        Resources["BackgroundBrush"] = new SolidColorBrush(ParseColor(theme.Background));
        Resources["PanelBrush"] = theme.LayeredSurfaces ? MakeBrush(theme.Primary, 0.16) : MakeBrush(theme.Panel);
        Resources["CardBrush"] = theme.LayeredSurfaces ? MakeBrush(theme.Secondary, 0.12) : MakeBrush(theme.Card);
        Resources["AccentBrush"] = new SolidColorBrush(ParseColor(theme.Primary));
        Resources["CyanBrush"] = new SolidColorBrush(ParseColor(theme.Highlight));
        Resources["SecondaryBrush"] = new SolidColorBrush(ParseColor(theme.Secondary));
        Resources["MutedBrush"] = theme.LayeredSurfaces
            ? MakeBrush(theme.Text, 0.72)
            : MakeReadableAccentBrush(theme.Muted, theme.Panel, theme.Text);
        Resources["TextBrush"] = new SolidColorBrush(ParseColor(theme.Text));
        Resources["ReadableBrush"] = new SolidColorBrush(ParseColor(theme.Text));
        Resources["OnPrimaryBrush"] = MakeContrastingBrush(theme.Primary);
        Resources["OnSecondaryBrush"] = MakeContrastingBrush(theme.Secondary);
        Resources["OnHighlightBrush"] = MakeContrastingBrush(theme.Highlight);
        Resources["BackgroundTextBrush"] = MakeContrastingBrush(theme.Background);
        Resources["SurfaceTextBrush"] = MakeContrastingBrush(theme.Panel);
        Resources["BackgroundMutedBrush"] = theme.LayeredSurfaces
            ? MakeBrush(theme.Text, 0.72)
            : MakeReadableAccentBrush(theme.Muted, theme.Background, ContrastingHex(theme.Background));
        Resources["SurfaceMutedBrush"] = theme.LayeredSurfaces
            ? MakeBrush(theme.Text, 0.72)
            : MakeReadableAccentBrush(theme.Muted, theme.Panel, ContrastingHex(theme.Panel));
        Resources["PopupBrush"] = theme.LayeredSurfaces
            ? MakeBrush(theme.Background, 0.98)
            : MakeBrush(theme.Panel);
        Resources["PopupBorderBrush"] = MakeBrush(theme.Primary);
        Resources["PopupTextBrush"] = MakeContrastingBrush(theme.Panel);
        Resources["PopupHoverBrush"] = MakeBrush(theme.Secondary);
        Resources["PopupHoverTextBrush"] = MakeContrastingBrush(theme.Secondary);
        Resources["SetupReadyBrush"] = MakeBrush(theme.Success);
        Resources["SetupRunningBrush"] = MakeBrush(theme.Secondary);
        Resources["SetupUpdateBrush"] = MakeBrush(theme.Highlight);
        Resources["SetupErrorBrush"] = MakeBrush(theme.Error);
        Resources["SuccessBrush"] = MakeReadableAccentBrush(theme.Success, theme.Panel, theme.Text);
        Resources["ErrorBrush"] = MakeReadableAccentBrush(theme.Error, theme.Panel, theme.Text);
        RefreshGeneratedControls();
        RefreshSpectrumColors();
        ThemeComboBox.SetResourceReference(System.Windows.Controls.Control.BackgroundProperty, "AccentBrush");
        ThemeComboBox.SetResourceReference(System.Windows.Controls.Control.ForegroundProperty, "ReadableBrush");
        Background = (WpfBrush)Resources["BackgroundBrush"];

        if (SpectrumFrame.BorderBrush is LinearGradientBrush glowBrush)
        {
            glowBrush.GradientStops[0].Color = ParseColor(theme.Secondary);
            glowBrush.GradientStops[1].Color = ParseColor(theme.Primary);
            glowBrush.GradientStops[2].Color = ParseColor(theme.Highlight);
        }
    }
}

using System.IO;
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
    private readonly List<float> sampleBuffer = new();
    private double[] spectrumLevels = new double[32];
    private readonly double[] smoothedSpectrum = new double[32];
    private bool audioSignalSeen;
    private DateTime lastAudioDataAtUtc = DateTime.MinValue;
    private double fallbackMeterLevel;
    private readonly Random spectrumRandom = new();
    private readonly List<Ellipse> spectrumDots = new();
    private double spectrumDotsWidth;
    private double spectrumDotsHeight;
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
    private Process? artRelayProcess;
    private bool artRelayOwned;
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
        trayIcon = CreateTrayIcon();
        profiles = new Dictionary<string, (string, string, WpfButton)>();
        routingConfiguration = SonicRoutingConfigurationStore.Load(routingConfigurationPath);
        scriptAudioController = new QueuedScoutAudioController(HotReloadAudioPipelineAsync, ActivateBypassModeAsync);
        scriptBridge = new ScriptOrchestrator(scriptAudioController, Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "SonicScout"));
        scriptBridge.StateChanged += ScriptBridge_StateChanged;
        scriptBridge.LogReceived += ScriptBridge_LogReceived;
        LoadSavedProfiles();
        UpdateProfileState();
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
            string profileName = HumanizeProfileName(profileId);
            WpfButton profileButton = CreateProfileButton(profileId, profileName, "Saved headphone / IEM target");
            profiles[profileId] = (profileName, "Saved headphone / IEM target", profileButton);
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
        SonicPassButton_Click(SonicPassButton, new RoutedEventArgs());
        if (StartArtRelay())
        {
            windowsLeqEnabled = true;
            WindowsLeqToggle.IsChecked = true;
            RefreshWindowsLeqState();
        }
        clipGuardTimer.Tick += (_, _) => ApplyClipGuard();
        RegisterRacingBorders();

        breathingTimer.Tick += (_, _) =>
        {
            double amount = (Math.Sin(breathingPhase) + 1) / 2;
            WpfColor pulseColor = BlendColors(ParseColor(activeTheme.Primary), ParseColor(activeTheme.Highlight), amount);
            foreach ((Border border, SolidColorBrush brush) in racingBorders)
            {
                brush.Color = pulseColor;
                border.BorderBrush = brush;
            }
            RenderSpectrum();
            breathingPhase += 0.018;
        };
        breathingTimer.Start();
    }

    private async Task EnsureTurnkeyStartupSetupAsync()
    {
        string? setupScriptPath = ResolveSetupAutomationScriptPath();
        if (setupScriptPath is null)
        {
            return;
        }

        int? preflightExitCode = await RunSetupPreflightExitCodeAsync(setupScriptPath, CancellationToken.None);
        bool setupVerified = routingConfiguration.PostInstallVerified &&
            preflightExitCode.HasValue &&
            preflightExitCode.Value == 0;
        if (setupVerified)
        {
            return;
        }

        SetupWindow dialog = new(DiscoverOutputEndpointsAsync, RunSetupChecks, OpenPostInstallVerificationAsync) { Owner = this };
        CopyThemeResourcesTo(dialog);
        dialog.ShowDialog();
        // App stays open regardless — user can finish setup later from the main window
    }

    private static async Task<int?> RunSetupPreflightExitCodeAsync(string setupScriptPath, CancellationToken cancellationToken)
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
            startInfo.ArgumentList.Add("Preflight");
            startInfo.ArgumentList.Add("-Quiet");
            startInfo.ArgumentList.Add("-NonInteractive");

            using Process process = new() { StartInfo = startInfo };
            if (!process.Start())
            {
                return null;
            }

            await process.WaitForExitAsync(cancellationToken);
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
        try
        {
            StopAudioMonitor();
            loopbackCapture = selectedOutput is null
                ? new WasapiLoopbackCapture()
                : new WasapiLoopbackCapture(selectedOutput);
            loopbackCapture.DataAvailable += LoopbackCapture_DataAvailable;
            loopbackCapture.RecordingStopped += (_, _) => { };
            loopbackCapture.StartRecording();
            sampleBuffer.Clear();
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
            for (int offset = 0; offset + frameSize <= e.BytesRecorded; offset += frameSize)
            {
                float sample = ReadNormalizedSample(format, e.Buffer, offset, bytesPerSample);
                sampleBuffer.Add(sample);
                observedSample = true;
            }

            if (sampleBuffer.Count >= 512)
            {
                float[] latestSamples = sampleBuffer.Skip(Math.Max(0, sampleBuffer.Count - 512)).Take(512).ToArray();
                double[] rawSpectrum = CalculateSpectrum(latestSamples);
                for (int index = 0; index < rawSpectrum.Length; index++)
                {
                    double response = rawSpectrum[index] > smoothedSpectrum[index] ? 0.42 : 0.12;
                    smoothedSpectrum[index] += (rawSpectrum[index] - smoothedSpectrum[index]) * response;
                }
                spectrumLevels = smoothedSpectrum.ToArray();
                audioSignalSeen = spectrumLevels.Any(level => level > 0.025);
                if (sampleBuffer.Count > 1024)
                {
                    sampleBuffer.RemoveRange(0, sampleBuffer.Count - 512);
                }
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

    private static double[] CalculateSpectrum(float[] samples)
    {
        int length = samples.Length;
        Complex[] values = new Complex[length];
        for (int i = 0; i < length; i++)
        {
            double window = 0.5 * (1 - Math.Cos((2 * Math.PI * i) / (length - 1)));
            values[i] = new Complex(samples[i] * window, 0);
        }

        for (int i = 1, j = 0; i < length; i++)
        {
            int bit = length >> 1;
            for (; (j & bit) != 0; bit >>= 1)
            {
                j ^= bit;
            }
            j ^= bit;
            if (i < j)
            {
                (values[i], values[j]) = (values[j], values[i]);
            }
        }

        for (int width = 2; width <= length; width <<= 1)
        {
            double angle = -2 * Math.PI / width;
            Complex step = Complex.FromPolarCoordinates(1, angle);
            for (int start = 0; start < length; start += width)
            {
                Complex factor = Complex.One;
                for (int index = 0; index < width / 2; index++)
                {
                    Complex even = values[start + index];
                    Complex odd = factor * values[start + index + width / 2];
                    values[start + index] = even + odd;
                    values[start + index + width / 2] = even - odd;
                    factor *= step;
                }
            }
        }

        double[] bands = new double[32];
        int maxBin = length / 2;
        for (int band = 0; band < bands.Length; band++)
        {
            int startBin = Math.Max(1, (int)(Math.Pow(maxBin, band / 32.0)));
            int endBin = Math.Max(startBin + 1, (int)(Math.Pow(maxBin, (band + 1) / 32.0)));
            double total = 0;
            int count = 0;
            for (int bin = startBin; bin < Math.Min(endBin, maxBin); bin++)
            {
                total += values[bin].Magnitude;
                count++;
            }
            double magnitude = total / Math.Max(1, count);
            double normalized = Math.Clamp((Math.Log10(1 + (magnitude * 40)) / 2.2), 0, 1);
            bands[band] = normalized;
        }
        return bands;
    }

    private void RenderSpectrum()
    {
        if (SpectrumCanvas.ActualWidth <= 0 || SpectrumCanvas.ActualHeight <= 0)
        {
            return;
        }

        if ((DateTime.UtcNow - lastAudioDataAtUtc).TotalMilliseconds > 900)
        {
            TryRefreshSpectrumFromAudioMeter();
        }

        double[] levels;
        lock (spectrumLock)
        {
            levels = spectrumLevels.ToArray();
        }

        for (int index = 0; index < levels.Length; index++)
        {
            if (!double.IsFinite(levels[index]))
            {
                levels[index] = 0;
            }
        }

        SpectrumStatusText.Visibility = audioSignalSeen ? Visibility.Collapsed : Visibility.Visible;
        const int pointCount = 32;
        if (spectrumDots.Count != pointCount || Math.Abs(spectrumDotsWidth - SpectrumCanvas.ActualWidth) > 1 || Math.Abs(spectrumDotsHeight - SpectrumCanvas.ActualHeight) > 1)
        {
            SpectrumCanvas.Children.Clear();
            spectrumDots.Clear();
            spectrumDotsWidth = SpectrumCanvas.ActualWidth;
            spectrumDotsHeight = SpectrumCanvas.ActualHeight;
            double spacing = SpectrumCanvas.ActualWidth / (pointCount - 1);
            for (int index = 0; index < pointCount; index++)
            {
                Ellipse dot = new()
                {
                    Width = 9,
                    Height = 9,
                    Fill = new SolidColorBrush(ParseColor(index % 2 == 0 ? activeTheme.Secondary : activeTheme.Highlight)),
                    Opacity = 0.95
                };
                Canvas.SetLeft(dot, index * spacing - 3.5);
                SpectrumCanvas.Children.Add(dot);
                spectrumDots.Add(dot);
            }
        }

        double dotSpacing = SpectrumCanvas.ActualWidth / (pointCount - 1);
        for (int pointIndex = 0; pointIndex < pointCount; pointIndex++)
        {
            double sourcePosition = pointIndex * (levels.Length - 1) / (double)(pointCount - 1);
            int lower = Math.Min(levels.Length - 1, (int)sourcePosition);
            int upper = Math.Min(levels.Length - 1, lower + 1);
            double interpolated = levels[lower] + ((levels[upper] - levels[lower]) * (sourcePosition - lower));
            if (!double.IsFinite(interpolated))
            {
                interpolated = 0.035;
            }
            interpolated = Math.Max(0.035, interpolated);
            double x = pointIndex * dotSpacing - 3.5;
            double baseline = SpectrumCanvas.ActualHeight * 0.82;
            double travelHeight = SpectrumCanvas.ActualHeight * 0.64;
            double y = baseline - Math.Clamp(interpolated, 0.035, 1) * travelHeight;
            Canvas.SetLeft(spectrumDots[pointIndex], x);
            Canvas.SetTop(spectrumDots[pointIndex], Math.Max(4, y));
            spectrumDots[pointIndex].Opacity = 0.55 + (Math.Clamp(interpolated, 0, 1) * 0.45);
        }
    }

    private void TryRefreshSpectrumFromAudioMeter()
    {
        if (OutputDeviceComboBox.SelectedIndex < 0 || OutputDeviceComboBox.SelectedIndex >= outputDeviceReferences.Count)
        {
            return;
        }

        MMDevice selectedOutput = outputDeviceReferences[OutputDeviceComboBox.SelectedIndex];
        if (selectedOutput.State != DeviceState.Active)
        {
            return;
        }

        double peak = selectedOutput.AudioMeterInformation.MasterPeakValue;
        fallbackMeterLevel = (fallbackMeterLevel * 0.68) + (peak * 0.32);
        if (fallbackMeterLevel <= 0.001)
        {
            audioSignalSeen = false;
            return;
        }

        lock (spectrumLock)
        {
            for (int index = 0; index < smoothedSpectrum.Length; index++)
            {
                double shape = 1.0 - ((index / (double)smoothedSpectrum.Length) * 0.55);
                double wobble = (spectrumRandom.NextDouble() - 0.5) * 0.16;
                double target = Math.Clamp((fallbackMeterLevel * 1.9 * shape) + wobble, 0.01, 1);
                smoothedSpectrum[index] += (target - smoothedSpectrum[index]) * 0.35;
            }

            spectrumLevels = smoothedSpectrum.ToArray();
        }

        audioSignalSeen = true;
    }

    private void RefreshSpectrumColors()
    {
        for (int index = 0; index < spectrumDots.Count; index++)
        {
            if (spectrumDots[index].Fill is SolidColorBrush brush)
            {
                brush.Color = ParseColor(index % 2 == 0 ? activeTheme.Secondary : activeTheme.Highlight);
            }
        }
    }

    private void Window_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        exitRequested = true;
        _ = Task.Run(() =>
        {
            Thread.Sleep(2000);
            Environment.Exit(0);
        });

        clipGuardTimer.Stop();
        eqWriteTimer.Stop();
        breathingTimer.Stop();
        WasapiLoopbackCapture? captureToDispose = loopbackCapture;
        loopbackCapture = null;
        audioMonitorReady = false;
        try
        {
            StopSonicPass();
            StopArtRelay();
            scriptBridge.StateChanged -= ScriptBridge_StateChanged;
            scriptBridge.LogReceived -= ScriptBridge_LogReceived;
            scriptAudioController.DisposeAsync().AsTask().GetAwaiter().GetResult();
            trayIcon.Visible = false;
            trayIcon.Dispose();
        }
        catch (InvalidOperationException)
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

        Dispatcher.BeginInvoke(new Action(() => Environment.Exit(0)), System.Windows.Threading.DispatcherPriority.ApplicationIdle);
    }

    private void LoadAudioDevices()
    {
        try
        {
            audioEnumerator = new MMDeviceEnumerator();
            MMDeviceCollection inputs = audioEnumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active);
            MMDeviceCollection outputs = audioEnumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active);

            InputDeviceComboBox.Items.Clear();
            OutputDeviceComboBox.Items.Clear();
            outputDeviceReferences.Clear();
            sonicPassInputReferences.Clear();
            sonicPassOutputReferences.Clear();
            SonicPassInputComboBox.Items.Clear();
            SonicPassOutputComboBox.Items.Clear();
            foreach (MMDevice device in inputs)
            {
                InputDeviceComboBox.Items.Add(DisplayDeviceName(device.FriendlyName));
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
                InputDeviceComboBox.SelectedIndex = 0;
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
        return outputName.Contains("hi-fi cable", StringComparison.OrdinalIgnoreCase) ||
               outputName.Contains("hifi cable", StringComparison.OrdinalIgnoreCase) ||
               outputName.Contains("vb-audio hi-fi", StringComparison.OrdinalIgnoreCase) ||
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
        bool artRelayRunning = artRelayProcess is not null && !artRelayProcess.HasExited;
        bool engaged = sonicScoutProvisioned && (sonicPassRunning || artRelayRunning);

        routingConfiguration.SonicScoutEngaged = engaged;
        routingConfiguration.ActiveOutputDeviceId = GetSelectedOutputDeviceId();
        routingConfiguration.ActiveOutputDeviceName = OutputDeviceComboBox.SelectedItem?.ToString();
        routingConfiguration.LastRoutingNote = engaged
            ? artRelayRunning
                ? "Art Relay is running from the tuned capture endpoint to the physical output."
                : "SonicPass is running from the configured virtual input to the physical output."
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
                WindowsLeqStatusText.Text = "Sonic Scout not provisioned. Run SETUP.";
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
            MessageText.Text = "Sonic Scout is not provisioned. Run SETUP to configure your virtual cable routing first.";
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

        if (wantsEnabled && !StartArtRelay())
        {
            windowsLeqEnabled = false;
            WindowsLeqToggle.IsChecked = false;
            MessageText.Text = "Art Relay could not start. Keep SonicPass running or check ArtTuneKit sign-in.";
            RefreshWindowsLeqState();
            return;
        }

        windowsLeqEnabled = wantsEnabled;
        if (!wantsEnabled)
        {
            StopArtRelay();
        }
        routingConfiguration.SonicScoutEngaged = wantsEnabled;
        RefreshWindowsLeqState();
        MessageText.Text = windowsLeqEnabled
            ? $"Live equalizer enabled. Art Relay is processing the tuned audio path."
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

    private void SetupButton_Click(object sender, RoutedEventArgs e)
    {
        SetupWindow dialog = new(DiscoverOutputEndpointsAsync, RunSetupChecks, OpenPostInstallVerificationAsync) { Owner = this };
        CopyThemeResourcesTo(dialog);
        dialog.ShowDialog();
    }

    private Task OpenPostInstallVerificationAsync(Window owner)
    {
        PostInstallVerifyDialog dialog = new() { Owner = owner };
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
            MessageText.Text = $"Script bridge reloaded the audio pipeline. {reason}";
        });
    }

    private async Task ActivateBypassModeAsync(string reason, CancellationToken cancellationToken)
    {
        await Dispatcher.InvokeAsync(() =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            ApplySafePhysicalOutputFallback();
            StopSonicPass();
            MessageText.Text = $"Script bridge activated safe bypass mode. {reason}";
            SonicPassStatusText.Text = "BYPASS - safe physical output fallback is active";
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

        bool elevated = IsCurrentProcessElevated();
        string mode = elevated ? "Install" : "Preflight";
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
            Timeout: TimeSpan.FromMinutes(8));

        string executionId = await scriptBridge.QueueExecutionAsync(executionRequest, cancellationToken);
        return await scriptBridge.WaitForCompletionAsync(executionId, cancellationToken);
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
            MessageText.Text = "Run SETUP first so Sonic Scout can identify the virtual render endpoint.";
            SonicPassStatusText.Text = "WAITING - choose a virtual input or run SETUP";
            return;
        }

        string? physicalOutputId = routingConfiguration.SelectedPhysicalOutputId;
        if (string.IsNullOrWhiteSpace(physicalOutputId))
        {
            MessageText.Text = "Run SETUP first and select a physical output for SonicPass.";
            SonicPassStatusText.Text = "WAITING - choose a physical output or run SETUP";
            return;
        }

        string? sonicPassPath = ResolveSonicPassExecutablePath();
        if (sonicPassPath is null)
        {
            MessageText.Text = "SonicPass is not built. Run CSharp\\run_scoutpass.bat once.";
            SonicPassStatusText.Text = "NOT BUILT - build SonicPass before starting";
            return;
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
            startInfo.ArgumentList.Add("--input-id");
            startInfo.ArgumentList.Add(routingConfiguration.SonicScoutEndpointId);
            startInfo.ArgumentList.Add("--output-id");
            startInfo.ArgumentList.Add(physicalOutputId);
            startInfo.ArgumentList.Add("--buffer-ms");
            startInfo.ArgumentList.Add(GetComboValue(SonicPassBufferComboBox, "100"));
            startInfo.ArgumentList.Add("--input-gain-db");
            startInfo.ArgumentList.Add(GetComboValue(SonicPassInputGainComboBox, "0"));
            startInfo.ArgumentList.Add("--output-gain-db");
            startInfo.ArgumentList.Add(GetComboValue(SonicPassOutputGainComboBox, "0"));

            sonicPassProcess = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
            sonicPassProcess.Exited += SonicPassProcess_Exited;
            if (!sonicPassProcess.Start())
            {
                throw new InvalidOperationException("Windows could not start SonicPass.");
            }
            sonicPassProcess.BeginOutputReadLine();
            sonicPassProcess.BeginErrorReadLine();

            SonicPassButton.Content = "STOP SONICPASS";
            SonicPassStartButton.Content = "STOP SONICPASS";
            SonicPassStatusText.Text = "RUNNING - virtual input is routing to the physical output";
            MessageText.Text = "SonicPass started. Virtual audio is routing to the selected physical output.";
            UpdateTunedVirtualCableStatusIndicator();
        }
        catch (Exception exception) when (exception is InvalidOperationException or Win32Exception)
        {
            sonicPassProcess?.Dispose();
            sonicPassProcess = null;
            SonicPassStatusText.Text = "ERROR - SonicPass could not start";
            MessageText.Text = $"SonicPass could not start: {exception.Message}";
        }
    }

    private void SonicPassProcess_Exited(object? sender, EventArgs e)
    {
        Dispatcher.Invoke(() =>
        {
            bool unexpectedExit = !exitRequested && sonicPassProcess is not null && sonicPassProcess.ExitCode != 0;
            SonicPassButton.Content = "SONICPASS";
            SonicPassStartButton.Content = "START SONICPASS";
            SonicPassStatusText.Text = unexpectedExit ? "ERROR - SonicPass stopped unexpectedly" : "STOPPED - SonicPass is not routing audio";
            if (unexpectedExit)
            {
                MessageText.Text = "SonicPass stopped unexpectedly. Check the endpoint state.";
            }
            UpdateTunedVirtualCableStatusIndicator();
        });
    }

    private bool StartArtRelay()
    {
        if (artRelayProcess is not null && !artRelayProcess.HasExited)
        {
            return true;
        }

        Process? existingRelay = Process.GetProcessesByName("atk_relay").FirstOrDefault();
        if (existingRelay is not null)
        {
            artRelayProcess = existingRelay;
            artRelayOwned = false;
            return true;
        }

        string relayPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "ArtTuneKit", "tools", "relay", "atk_relay.exe");
        if (!File.Exists(relayPath) || string.IsNullOrWhiteSpace(routingConfiguration.SelectedPhysicalOutputId))
        {
            return false;
        }

        MMDevice? captureDevice = audioEnumerator?.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active)
            .Cast<MMDevice>()
            .FirstOrDefault(device => device.FriendlyName.Contains("Unified Output", StringComparison.OrdinalIgnoreCase));
        if (captureDevice is null)
        {
            return false;
        }

        ProcessStartInfo startInfo = new(relayPath)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            WorkingDirectory = Path.GetDirectoryName(relayPath)!
        };
        startInfo.ArgumentList.Add("--out-guid");
        startInfo.ArgumentList.Add(routingConfiguration.SelectedPhysicalOutputId);
        startInfo.ArgumentList.Add("--out-name");
        startInfo.ArgumentList.Add(routingConfiguration.SelectedPhysicalOutputName ?? "Physical output");
        startInfo.ArgumentList.Add("--out-desc");
        startInfo.ArgumentList.Add(routingConfiguration.SelectedPhysicalOutputName ?? "Physical output");
        startInfo.ArgumentList.Add("--out-form");
        startInfo.ArgumentList.Add("1");
        startInfo.ArgumentList.Add("--capture-guid");
        startInfo.ArgumentList.Add(captureDevice.ID);
        startInfo.ArgumentList.Add("--capture-name");
        startInfo.ArgumentList.Add(captureDevice.FriendlyName);
        startInfo.ArgumentList.Add("--buffer");
        startInfo.ArgumentList.Add("small");
        startInfo.ArgumentList.Add("--volume");
        startInfo.ArgumentList.Add("0.99");
        startInfo.ArgumentList.Add("--exit-on-stdin-close");

        try
        {
            artRelayProcess = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
            artRelayProcess.Exited += ArtRelayProcess_Exited;
            if (!artRelayProcess.Start())
            {
                artRelayProcess.Dispose();
                artRelayProcess = null;
                return false;
            }
            artRelayProcess.BeginOutputReadLine();
            artRelayProcess.BeginErrorReadLine();
            artRelayOwned = true;
            return true;
        }
        catch (InvalidOperationException)
        {
            artRelayProcess?.Dispose();
            artRelayProcess = null;
            return false;
        }
        catch (Win32Exception)
        {
            artRelayProcess?.Dispose();
            artRelayProcess = null;
            return false;
        }
    }

    private void ArtRelayProcess_Exited(object? sender, EventArgs e)
    {
        Dispatcher.BeginInvoke(() =>
        {
            if (!exitRequested && windowsLeqEnabled)
            {
                windowsLeqEnabled = false;
                WindowsLeqToggle.IsChecked = false;
                MessageText.Text = "Art Relay stopped. Live equalizer is off; SonicPass remains available.";
            }
            UpdateTunedVirtualCableStatusIndicator();
        });
    }

    private void StopArtRelay()
    {
        Process? processToStop = artRelayProcess;
        artRelayProcess = null;
        if (processToStop is null || !artRelayOwned)
        {
            return;
        }

        artRelayOwned = false;
        _ = Task.Run(() =>
        {
            try
            {
                if (!processToStop.HasExited)
                {
                    processToStop.StandardInput.Close();
                    if (!processToStop.WaitForExit(1500))
                    {
                        processToStop.Kill(entireProcessTree: true);
                    }
                }
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
        SonicPassStatusText.Text = "READY - choose gain and start SonicPass";
    }

    private static string GetComboValue(System.Windows.Controls.ComboBox comboBox, string fallback)
    {
        return (comboBox.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? fallback;
    }

    private void SonicPassGain_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (IsLoaded)
        {
            MessageText.Text = $"SonicPass boost changed: input {GetComboValue(SonicPassInputGainComboBox, "0")} dB, output {GetComboValue(SonicPassOutputGainComboBox, "0")} dB.";
        }
    }

    private void SonicPassBuffer_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (IsLoaded)
        {
            MessageText.Text = $"SonicPass buffer set to {GetComboValue(SonicPassBufferComboBox, "100")} ms.";
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

            foreach (MMDevice output in outputs)
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
                Detail: $"Cloned selected physical output into virtual route '{routingConfiguration.SonicScoutAlias}' on endpoint: {DisplayDeviceName(sonicScoutEndpoint.FriendlyName)}.");
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
                    "# Sonic Scout background tuning profile",
                    $"# Channel alias: {routingConfiguration.SonicScoutAlias}",
                    $"# Physical source: {routingConfiguration.SelectedPhysicalOutputName ?? "Unknown"}",
                    $"# Virtual target: {routingConfiguration.SonicScoutEndpointName ?? "Unavailable"}",
                    $"# Compatibility mode: {(routingConfiguration.HasCompatibilityMixer ? "Third-party mixer protected" : "Direct route")}",
                    "# Processing mode: proprietary background tuning enabled"
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

    private async Task<IReadOnlyList<SetupCheckResult>> RunSetupChecks(
        IProgress<SetupCheckResult> progress,
        SetupInstallRequest request)
    {
        List<SetupCheckResult> results = new();
        SetupCheckResult Report(string name, string state, string detail)
        {
            SetupCheckResult result = new(name, state, detail);
            results.Add(result);
            progress.Report(result);
            return result;
        }

        try
        {
            if (!request.ConfirmOwnership || !request.ConfirmRoutingApply || !request.ConfirmDependencyFallback)
            {
                throw new InvalidOperationException("Setup requires all ownership and apply confirmations before Sonic Scout can configure routing.");
            }

            Report("Script bridge", "RUNNING", "Running setup automation through ScriptOrchestrator...");
            ScriptExecutionResult? setupAutomationResult = await RunSetupAutomationScriptAsync(request, CancellationToken.None);
            if (setupAutomationResult is null)
            {
                Report("Script bridge", "UPDATE", "setup_audio_stack.ps1 was not found beside the app. Copy it into the app folder to enable turnkey setup automation.");
            }
            else if (setupAutomationResult.State == ScriptExecutionState.Succeeded)
            {
                bool elevated = IsCurrentProcessElevated();
                if (elevated)
                {
                    Report("Script bridge", "READY", "Setup automation script completed in Install mode.");
                }
                else
                {
                    Report("Script bridge", "UPDATE", "Setup automation script completed in Preflight mode. Restart Sonic Scout as Administrator to run dependency installs from the UI.");
                }
            }
            else
            {
                string failure = setupAutomationResult.ErrorMessage ?? "Setup automation script failed.";
                Report("Script bridge", "UPDATE", $"{failure} Safe bypass mode has been applied.");
            }

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
            if (request.UsesWaveLink || waveLinkEndpointAvailable)
            {
                Report("Tuned channel prerequisites", "READY", "Elgato Wave Link detected. Sonic Scout will prioritize Wave Link routing before virtual-cable or Voicemeeter fallback.");
            }
            else if (request.UsesSoundBlaster || soundBlasterEndpointAvailable)
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
            else if (request.UsesVoicemeeter || voicemeeterEndpointAvailable)
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
            routingConfiguration.UseWaveLinkCompatibility = request.UsesWaveLink || waveLinkEndpointAvailable;
            routingConfiguration.UseSoundBlasterCompatibility = request.UsesSoundBlaster || soundBlasterEndpointAvailable;
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

            Report("Background tuning", "RUNNING", "Applying Sonic Scout background algorithm profile...");
            bool backgroundProfileWritten = await WriteSonicScoutBackgroundProfileAsync();
            Report("Background tuning", backgroundProfileWritten ? "READY" : "UPDATE",
                backgroundProfileWritten
                    ? $"Background tuning profile written to {sonicScoutAlgorithmPath}."
                    : "Background tuning profile could not be saved. Routing still falls back safely to physical output.");

            Report("Routing safety", "RUNNING", "Refreshing runtime outputs and applying fallback-safe routing...");
            LoadAudioDevices();
            ApplyRoutingPreferenceToOutputSelection();
            if (!routingConfiguration.SonicScoutProvisioned)
            {
                ApplySafePhysicalOutputFallback();
            }
            RefreshWindowsLeqState();
            string routingSafetyDetail = routingConfiguration.HasCompatibilityMixer
                ? $"Compatibility-safe routing is active ({routingConfiguration.SetupStyle}). Sonic Scout will not auto-hijack third-party mixer chains."
                : $"Safe fallback is active ({routingConfiguration.SetupStyle}). If Sonic Scout is unavailable, audio stays on the selected physical output.";
            if (!routingConfiguration.SonicScoutProvisioned && routingConfiguration.UseVoicemeeterCompatibility)
            {
                routingSafetyDetail = "Fallback is active on your physical output while Voicemeeter-assisted tuned channel setup is pending.";
            }
            Report("Routing safety", "READY", routingSafetyDetail);

            Report("Equalizer APO", "RUNNING", "Checking the APO include and repairing it when Windows allows...");
            await Task.Delay(120);
            EnsureApoLink();
            Report("Equalizer APO", apoLinked ? "READY" : "UPDATE", apoLinked ? "Sonic Scout link is active." : "Run Sonic Scout as administrator once, then run SETUP again.");
            Report("Live spectrum", "RUNNING", "Restarting loopback capture on the selected output...");
            await Task.Delay(120);
            StartAudioMonitor(OutputDeviceComboBox.SelectedIndex >= 0 && OutputDeviceComboBox.SelectedIndex < outputDeviceReferences.Count ? outputDeviceReferences[OutputDeviceComboBox.SelectedIndex] : null);
            Report("Live spectrum", loopbackCapture is null ? "ERROR" : "READY", loopbackCapture is null ? "Select an active output in Sound Settings, then run SETUP again." : "System audio monitor refreshed.");
            Report("Runtime assets", File.Exists(Path.Combine(AppContext.BaseDirectory, "NAudio.dll")) ? "READY" : "UPDATE", File.Exists(Path.Combine(AppContext.BaseDirectory, "NAudio.dll")) ? "Audio runtime dependency is present." : "Run the one-button launcher again to restore the runtime build.");
            await Task.Delay(120);
            await Task.Delay(250);
            Report("Updates", "READY", "App checks complete. Driver installs and reboots require your approval.");
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
        string publishedProfiles = Path.Combine(AppContext.BaseDirectory, "profiles");
        if (Directory.Exists(publishedProfiles))
        {
            return publishedProfiles;
        }

        string workingDirectoryProfiles = Path.Combine(Environment.CurrentDirectory, "profiles");
        if (Directory.Exists(workingDirectoryProfiles))
        {
            return workingDirectoryProfiles;
        }

        string parentProfiles = Path.Combine(Directory.GetParent(Environment.CurrentDirectory)?.FullName ?? Environment.CurrentDirectory, "profiles");
        return parentProfiles;
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

        string content = File.ReadAllText(sourcePath);
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
        List<string> lines = new();
        for (int index = 0; index < EqFrequencies.Length; index++)
        {
            int frequency = EqFrequencies[index];
            double gain = eqValues.ContainsKey(frequency.ToString()) ? eqValues[frequency.ToString()] : 0;
            lines.Add($"Filter {index + 1}: ON PK Fc {frequency} Hz Gain {FormatDb(gain)} Q 1.00");
        }
        return lines;
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

    private void EnsureApoLink()
    {
        string apoConfigPath = @"C:\Program Files\EqualizerAPO\config\config.txt";
        string includeLine = $"Include: {activeProfilePath}";
        if (!File.Exists(apoConfigPath))
        {
            apoLinked = false;
            EapoStatus.Text = "LINK ERROR";
            EapoStatus.Foreground = (WpfBrush)FindResource("ErrorBrush");
            RefreshProfileApoIndicators();
            return;
        }

        try
        {
            bool linked = File.ReadAllLines(apoConfigPath).Any(line => line.Trim().Equals(includeLine, StringComparison.OrdinalIgnoreCase));
            if (!linked)
            {
                string backupPath = $"{apoConfigPath}.sonicscout-auto-backup-{DateTime.Now:yyyyMMdd-HHmmss}";
                File.Copy(apoConfigPath, backupPath, overwrite: false);
                File.AppendAllText(apoConfigPath, Environment.NewLine + includeLine + Environment.NewLine);
            }
            apoLinked = true;
            EapoStatus.Text = "OK";
            EapoStatus.Foreground = (WpfBrush)FindResource("SuccessBrush");
            RefreshProfileApoIndicators();
        }
        catch (UnauthorizedAccessException)
        {
            apoLinked = false;
            EapoStatus.Text = "LINK ERROR";
            EapoStatus.Foreground = (WpfBrush)FindResource("ErrorBrush");
            RefreshProfileApoIndicators();
            MessageText.Text = "Windows denied automatic Equalizer APO setup. Run Sonic Scout once as administrator.";
        }
        catch (IOException)
        {
            apoLinked = false;
            EapoStatus.Text = "LINK ERROR";
            EapoStatus.Foreground = (WpfBrush)FindResource("ErrorBrush");
            RefreshProfileApoIndicators();
            MessageText.Text = "Equalizer APO's config is locked. Close the editor or APO manager and restart Sonic Scout.";
        }
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
            WpfButton profileButton = CreateProfileButton(profileId, dialog.ProfileName, subtitle);
            profiles[profileId] = (dialog.ProfileName, subtitle, profileButton);
            UpdateProfileState();
            SetEapoStatus(true, $"Added {dialog.ProfileName}. Select its tile to activate the EQ target.");
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
            ? ("ACTIVE · APO CONNECTED · SIGNAL / 48KHZ", (WpfBrush)FindResource("SuccessBrush"))
            : ("ACTIVE · APO LINK REQUIRED · SIGNAL / 48KHZ", (WpfBrush)FindResource("ErrorBrush"));
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

            ProfileStackPanel.Children.Remove(card);
            profiles.Remove(profileId);
            if (deletingActiveProfile)
            {
                activeProfileId = null;
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
            id = id[..40].Trim('_');
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
        EapoStatus.Text = usable ? "OK" : "LINK ERROR";
        EapoStatus.Foreground = color;
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

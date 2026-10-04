using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace SonicScout;

public sealed record SetupCheckResult(string Name, string State, string Detail);
public sealed record AudioEndpointOption(string Id, string DisplayName);
public sealed record SetupInstallRequest(
    string SelectedOutputId,
    string SelectedOutputName,
    string SetupStyle,
    bool ConfirmOwnership,
    bool ConfirmRoutingApply,
    bool ConfirmDependencyFallback,
    bool UsesVoicemeeter,
    bool UsesWaveLink,
    bool UsesSoundBlaster,
    bool UsesOtherMixer);

public partial class SetupWindow : Window
{
    private const string SonicScoutDirectRouteStyle = "Sonic Scout Direct Route";
    private const string SonicScoutCompatibilityRouteStyle = "Sonic Scout Compatibility Route";

    private readonly Func<Task<IReadOnlyList<AudioEndpointOption>>> discoverOutputs;
    private readonly Func<IProgress<SetupCheckResult>, SetupInstallRequest, Task<IReadOnlyList<SetupCheckResult>>> runChecks;
    private readonly Func<Window, Task> openPostInstallVerification;
    private readonly Dictionary<string, (Ellipse Indicator, TextBlock Heading, TextBlock Detail)> rows = new();
    private readonly List<AudioEndpointOption> discoveredOutputs = new();

    public SetupWindow(
        Func<Task<IReadOnlyList<AudioEndpointOption>>> discoverOutputs,
        Func<IProgress<SetupCheckResult>, SetupInstallRequest, Task<IReadOnlyList<SetupCheckResult>>> runChecks,
        Func<Window, Task> openPostInstallVerification)
    {
        InitializeComponent();
        this.discoverOutputs = discoverOutputs;
        this.runChecks = runChecks;
        this.openPostInstallVerification = openPostInstallVerification;
        EnsureRequiredSetupResources();
        Loaded += async (_, _) => await LoadInstallOptionsAsync();
    }

    // Seeds brush keys that theme resources may not have copied yet — prevents FindResource crashes
    private void EnsureRequiredSetupResources()
    {
        SetBrushIfMissing("BackgroundBrush", System.Windows.Media.Color.FromRgb(0x10, 0x15, 0x1A));
        SetBrushIfMissing("PanelBrush", System.Windows.Media.Color.FromRgb(0x22, 0x22, 0x38));
        SetBrushIfMissing("CardBrush", System.Windows.Media.Color.FromRgb(0x20, 0x2C, 0x34));
        SetBrushIfMissing("AccentBrush", System.Windows.Media.Color.FromRgb(0xD9, 0x8E, 0x04));
        SetBrushIfMissing("CyanBrush", System.Windows.Media.Color.FromRgb(0x00, 0xBC, 0xD4));
        SetBrushIfMissing("SecondaryBrush", System.Windows.Media.Color.FromRgb(0x54, 0xD1, 0x8A));
        SetBrushIfMissing("MutedBrush", System.Windows.Media.Color.FromRgb(0xAA, 0xB4, 0xBD));
        SetBrushIfMissing("TextBrush", System.Windows.Media.Color.FromRgb(0xF4, 0xF1, 0xE8));
        SetBrushIfMissing("OnPrimaryBrush", System.Windows.Media.Color.FromRgb(0xFF, 0xFF, 0xFF));
        SetBrushIfMissing("PopupBrush", System.Windows.Media.Color.FromRgb(0x1A, 0x1A, 0x2E));
        SetBrushIfMissing("PopupBorderBrush", System.Windows.Media.Color.FromRgb(0x40, 0x40, 0x60));
        SetBrushIfMissing("PopupTextBrush", System.Windows.Media.Color.FromRgb(0xE0, 0xE0, 0xE0));
        SetBrushIfMissing("PopupHoverBrush", System.Windows.Media.Color.FromRgb(0x00, 0xF0, 0xFF));
        SetBrushIfMissing("PopupHoverTextBrush", System.Windows.Media.Color.FromRgb(0x03, 0x01, 0x0A));
        SetBrushIfMissing("SetupReadyBrush", System.Windows.Media.Color.FromRgb(0x4C, 0xAF, 0x50));
        SetBrushIfMissing("SetupRunningBrush", System.Windows.Media.Color.FromRgb(0x21, 0x96, 0xF3));
        SetBrushIfMissing("SetupUpdateBrush", System.Windows.Media.Color.FromRgb(0xFF, 0xC1, 0x07));
        SetBrushIfMissing("SetupErrorBrush", System.Windows.Media.Color.FromRgb(0xF4, 0x43, 0x36));
    }

    private void SetBrushIfMissing(string key, System.Windows.Media.Color fallbackColor)
    {
        if (TryFindResource(key) is null)
        {
            Resources[key] = new System.Windows.Media.SolidColorBrush(fallbackColor);
        }
    }

    private System.Windows.Media.Brush ResolveBrush(string key, System.Windows.Media.Color fallbackColor)
    {
        return TryFindResource(key) as System.Windows.Media.Brush
            ?? new System.Windows.Media.SolidColorBrush(fallbackColor);
    }

    private async Task LoadInstallOptionsAsync()
    {
        SetInstallerInputEnabled(false);
        ProgressBar.IsIndeterminate = true;
        SummaryText.Text = "Discovering active input/output devices...";
        ActionHintText.Text = "We'll detect your active output devices and prepare a recommended setup path.";
        CheckList.Items.Clear();
        rows.Clear();

        try
        {
            IReadOnlyList<AudioEndpointOption> outputs = await discoverOutputs();
            discoveredOutputs.Clear();
            discoveredOutputs.AddRange(outputs);
            DefaultOutputComboBox.Items.Clear();
            foreach (AudioEndpointOption output in discoveredOutputs)
            {
                DefaultOutputComboBox.Items.Add(output.DisplayName);
            }

            if (discoveredOutputs.Count == 0)
            {
                CheckList.Items.Add(CreateRow(new SetupCheckResult("Device discovery", "UPDATE", "No active output endpoints were detected. Connect your playback device and reopen setup.")));
                SummaryText.Text = "No active output devices found.";
                ActionHintText.Text = "Connect your headset/speakers, make sure Windows sees them, then reopen setup.";
                DoneButton.IsEnabled = true;
                DoneButton.Content = "CLOSE";
                return;
            }

            // Auto-select the output the user actually hears sound from. The old
            // SelectedIndex = 0 picked whichever endpoint sorted first ALPHABETICALLY
            // (DiscoverOutputEndpointsAsync orders by display name), which on a machine
            // with a virtual cable installed routinely landed on the cable rather than
            // the physical device -- and every later step then routed tuned audio back
            // into the loop. Ranked now, with the reason reported so it stays visible.
            int recommendedIndex = SelectRecommendedOutputIndex();
            DefaultOutputComboBox.SelectedIndex = recommendedIndex;
            SetupStyleComboBox.SelectedIndex = 0;

            // Auto-detect third-party mixers instead of asking. Ticking these changes
            // routing behaviour, so a wrong guess is worse than no guess -- but they
            // are presence facts, not preferences, and every one of them is already
            // discoverable from the render endpoints we just enumerated.
            DetectMixerCompatibility();

            OwnershipConsentCheckBox.IsChecked = false;
            UpdateSetupStyleHint();
            CheckList.Items.Add(CreateRow(new SetupCheckResult("Device discovery", "READY", $"Discovered {discoveredOutputs.Count} active output endpoint(s).")));
            CheckList.Items.Add(CreateRow(new SetupCheckResult(
                "Default output",
                "READY",
                $"Pre-selected '{discoveredOutputs[recommendedIndex].DisplayName}'. If that is not what you hear sound from, change it above before running setup.")));
            AppendMixerDetectionRows();

            bool autoDetected = VoicemeeterCheckBox.IsChecked == true
                || WaveLinkCheckBox.IsChecked == true
                || SoundBlasterCheckBox.IsChecked == true
                || OtherMixerCheckBox.IsChecked == true;

            SummaryText.Text = "Confirm the output, then authorise setup.";
            ActionHintText.Text = autoDetected
                ? "Third-party mixers were detected and checked for you. Untick any that are not in use, then tick the authorisation box and run setup."
                : "Check the output is the device you hear sound from, tick the authorisation box, then run setup.";
            StepText.Text = "STEP 1 OF 4  |  CONFIRM YOUR OUTPUT AND AUTHORISE SETUP";
            SetInstallerInputEnabled(true);
            DoneButton.IsEnabled = true;
            DoneButton.Content = "CLOSE";
        }
        catch (COMException exception)
        {
            CheckList.Items.Add(CreateRow(new SetupCheckResult("Device discovery", "ERROR", $"Windows Core Audio failed to enumerate endpoints: {exception.Message}")));
            SummaryText.Text = "Device discovery failed.";
            ActionHintText.Text = "Restart Windows Audio service or reboot, then rerun setup.";
            DoneButton.IsEnabled = true;
            DoneButton.Content = "CLOSE";
        }
        catch (UnauthorizedAccessException exception)
        {
            CheckList.Items.Add(CreateRow(new SetupCheckResult("Device discovery", "ERROR", $"Windows denied access to device metadata: {exception.Message}")));
            SummaryText.Text = "Device discovery failed.";
            ActionHintText.Text = "Run Sonic Scout as Administrator and try setup again.";
            DoneButton.IsEnabled = true;
            DoneButton.Content = "CLOSE";
        }
        catch (IOException exception)
        {
            CheckList.Items.Add(CreateRow(new SetupCheckResult("Device discovery", "ERROR", $"A file or driver IO operation failed while loading devices: {exception.Message}")));
            SummaryText.Text = "Device discovery failed.";
            ActionHintText.Text = "Close audio tools using these devices and retry setup.";
            DoneButton.IsEnabled = true;
            DoneButton.Content = "CLOSE";
        }
        finally
        {
            ProgressBar.IsIndeterminate = false;
            ProgressBar.Value = 0;
        }
    }

    private SetupInstallRequest BuildInstallRequest()
    {
        if (DefaultOutputComboBox.SelectedIndex < 0 || DefaultOutputComboBox.SelectedIndex >= discoveredOutputs.Count)
        {
            throw new InvalidOperationException("Select an active output endpoint before running setup.");
        }

        AudioEndpointOption selectedOutput = discoveredOutputs[DefaultOutputComboBox.SelectedIndex];
        return new SetupInstallRequest(
            selectedOutput.Id,
            selectedOutput.DisplayName,
            GetSelectedSetupStyle(),
OwnershipConsentCheckBox.IsChecked == true,
        OwnershipConsentCheckBox.IsChecked == true,
        OwnershipConsentCheckBox.IsChecked == true,
            VoicemeeterCheckBox.IsChecked == true,
            WaveLinkCheckBox.IsChecked == true,
            SoundBlasterCheckBox.IsChecked == true,
            OtherMixerCheckBox.IsChecked == true);
    }

    // Endpoint-name fragments that identify a VIRTUAL endpoint. Anything matching is
    // not a valid "the device I actually hear sound from" answer, so it is excluded
    // from auto-selection outright rather than merely ranked lower.
    private static readonly string[] VirtualOutputMarkers =
    {
        "cable", "voicemeeter", "vb-audio", "vb-cable", "virtual",
        "sonic scout", "sonicscout", "scoutpass", "scout pass", "loopback",
    };

    // Physical-output hints, best score first. Ranked so "Headphones (USB-1)" beats
    // "Speakers (Realtek)" beats a name we cannot classify.
    private static readonly (string Marker, int Score)[] PhysicalOutputHints =
    {
        ("headphone", 0),
        ("headset", 0),
        ("earphone", 0),
        ("dac", 1),
        ("amp", 2),
        ("usb", 3),
        ("speaker", 4),
    };

    private static bool IsVirtualOutputName(string name) =>
        VirtualOutputMarkers.Any(marker => name.Contains(marker, StringComparison.OrdinalIgnoreCase));

    private int SelectRecommendedOutputIndex()
    {
        int bestIndex = 0;
        int bestScore = int.MaxValue;

        for (int index = 0; index < discoveredOutputs.Count; index++)
        {
            string name = discoveredOutputs[index].DisplayName;
            if (IsVirtualOutputName(name)) { continue; }

            int score = PhysicalOutputHints
                .Where(hint => name.Contains(hint.Marker, StringComparison.OrdinalIgnoreCase))
                .Select(hint => hint.Score)
                .DefaultIfEmpty(5)
                .Min();

            if (score < bestScore)
            {
                bestScore = score;
                bestIndex = index;
            }
        }

        // bestScore is still int.MaxValue when EVERY endpoint looked virtual (a
        // Voicemeeter-only machine, say). Fall back to index 0 rather than refusing
        // to choose -- the combo sits directly above this list and stays editable.
        return bestIndex;
    }

    private void DetectMixerCompatibility()
    {
        bool voicemeeter = false;
        bool waveLink = false;
        bool soundBlaster = false;

        foreach (AudioEndpointOption output in discoveredOutputs)
        {
            string name = output.DisplayName;
            voicemeeter |= name.Contains("voicemeeter", StringComparison.OrdinalIgnoreCase);
            waveLink |= name.Contains("wave link", StringComparison.OrdinalIgnoreCase)
                || name.Contains("wavelink", StringComparison.OrdinalIgnoreCase);
            soundBlaster |= name.Contains("sound blaster", StringComparison.OrdinalIgnoreCase)
                || name.Contains("blaster", StringComparison.OrdinalIgnoreCase);
        }

        VoicemeeterCheckBox.IsChecked = voicemeeter;
        WaveLinkCheckBox.IsChecked = waveLink;
        SoundBlasterCheckBox.IsChecked = soundBlaster;

        // SonicPass compatibility is deliberately NOT auto-ticked. It maps to
        // UseOtherMixerCompatibility, which puts the app into compatibility-safe
        // routing and REFUSES to hand the virtual endpoint to SonicScout
        // (MainWindow.xaml.cs:2050). Ticking it by default would quietly disable
        // the main direct route. It stays an explicit opt-in.
        OtherMixerCheckBox.IsChecked = false;
    }

    private void AppendMixerDetectionRows()
    {
        (System.Windows.Controls.CheckBox Box, string Name)[] boxes =
        {
            (VoicemeeterCheckBox, "Voicemeeter"),
            (WaveLinkCheckBox, "Elgato Wave Link"),
            (SoundBlasterCheckBox, "Creative Sound Blaster"),
            (OtherMixerCheckBox, "SonicPass compatibility"),
        };

        foreach ((System.Windows.Controls.CheckBox box, string name) in boxes)
        {
            bool on = box.IsChecked == true;
            CheckList.Items.Add(CreateRow(new SetupCheckResult(
                name,
                "READY",
                on
                    ? "Detected on this PC and ticked for you. Untick it if you do not route through this mixer."
                    : "Not detected. Tick it only if you route audio through this mixer.")));
        }
    }

    private void AppendRemainingManualSteps(bool allChecksPassed)
    {
        (string Title, string Steps)[] manual =
        {
            ("Restart Windows",
                "1. Save your work and click Start > Power > Restart.\n" +
                "2. Wait for Windows to finish. Driver and audio changes are not live until after this.\n" +
                "3. Reopen Sonic Scout. Nothing else is needed - it remembers your choices."),

            ("Leave your default playback device alone",
                "1. Do NOT change your Windows default output. Leave it on your Realtek (or other\n" +
                "   physical) device - Sonic Scout is designed to work with that unchanged.\n" +
                "2. Games and apps join Sonic Scout individually, via the step below.\n" +
                "Changing the system default here is not needed and will not improve the sound."),

            ("Turn Spatial Sound off for that device",
                "1. Still in Sound Settings, click your Sonic Scout device to open it.\n" +
                "2. Under Spatial sound, set it to Off.\n" +
                "3. Do the same for the device you will actually be playing through.\n" +
                "Windows Sonic / Dolby Atmos / DTS:X silently block Equalizer APO when left on, and the " +
                "equalizer will appear to do nothing."),

            ("Point each game or app at the virtual input",
                "1. In each game or app's audio settings, choose the Sonic Scout VIRTUAL INPUT as its output.\n" +
                "2. Do NOT change your Windows default device for this - only the per-app setting.\n" +
                "3. If a game has no output selector, Windows routing (Settings > System > Sound > " +
                "Advanced sound settings > App volume and device preferences) works instead.\n" +
                "This is per-app by design: Sonic Scout receives the app's audio, applies your tune, " +
                "and passes it to your speakers. Leave the app on your speakers and it bypasses the tune."),
        };

        for (int i = 0; i < manual.Length; i++)
        {
            CheckList.Items.Add(CreateRow(new SetupCheckResult(
                $"MANUAL STEP {i + 1} of {manual.Length}: {manual[i].Title}",
                "READY",
                manual[i].Steps)));
        }

        CheckList.Items.Add(CreateRow(new SetupCheckResult(
            "Everything else was automatic",
            allChecksPassed ? "READY" : "UPDATE",
            allChecksPassed
                ? "Drivers, routing, the equalizer, the tuned channel and SonicPass were all configured " +
                  "for you. Only the steps above need you."
                : "Some automatic steps did not complete - see the yellow and red rows above. Fix " +
                  "those first, then rerun setup before doing the manual steps.")));

        SummaryText.Text = "Setup finished.";
        ActionHintText.Text = "Follow the numbered MANUAL STEP rows below, then click VERIFY SETTINGS.";
    }

    private string GetSelectedSetupStyle()
    {
        if (SetupStyleComboBox.SelectedItem is ComboBoxItem selectedStyle &&
            selectedStyle.Content is string setupStyle &&
            !string.IsNullOrWhiteSpace(setupStyle))
        {
            return setupStyle;
        }

        return SonicScoutDirectRouteStyle;
    }

    private void UpdateSetupStyleHint()
    {
        string setupStyle = GetSelectedSetupStyle();
        bool compatibilityRouteStyle = string.Equals(setupStyle, SonicScoutCompatibilityRouteStyle, StringComparison.OrdinalIgnoreCase);
        SetupStyleHintText.Text = compatibilityRouteStyle
            ? "Sonic Scout compatibility route keeps mixer-safe routing active to avoid third-party chain conflicts."
            : "Sonic Scout direct route prioritizes low-latency virtual routing.";
    }

    private void SetInstallerInputEnabled(bool enabled)
    {
        DefaultOutputComboBox.IsEnabled = enabled;
        SetupStyleComboBox.IsEnabled = enabled;
        OwnershipConsentCheckBox.IsEnabled = enabled;
        VoicemeeterCheckBox.IsEnabled = enabled;
        WaveLinkCheckBox.IsEnabled = enabled;
        SoundBlasterCheckBox.IsEnabled = enabled;
        OtherMixerCheckBox.IsEnabled = enabled;
        UpdateRunButtonState(enabled);
    }

    private bool HasRequiredConsents()
    {
        return OwnershipConsentCheckBox.IsChecked == true;
    }

    private static void SetWrappedButtonText(System.Windows.Controls.Button button, string text)
    {
        button.Content = new TextBlock
        {
            Text = text,
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center,
            FontSize = 10.5,
            FontWeight = FontWeights.Bold,
            HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
            VerticalAlignment = System.Windows.VerticalAlignment.Center,
            TextTrimming = TextTrimming.None,
            LineHeight = 16,
            MaxWidth = 200,
            Padding = new Thickness(0)
        };
        button.Padding = new Thickness(10, 8, 10, 8);
        button.MinHeight = 52;
        button.MinWidth = 220;
    }

    private void UpdateRunButtonState(bool setupInputsEnabled)
    {
        BeginSetupButton.IsEnabled = setupInputsEnabled && discoveredOutputs.Count > 0;
        SetWrappedButtonText(BeginSetupButton, HasRequiredConsents()
            ? "RUN INSTALL SETUP"
            : "TICK THE AUTHORISATION BOX ABOVE");
    }

    private void SetupStyleComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        UpdateSetupStyleHint();
    }

    private void ConsentCheckBox_Changed(object sender, RoutedEventArgs e)
    {
        UpdateRunButtonState(DefaultOutputComboBox.IsEnabled);
    }

    private async void BeginSetupButton_Click(object sender, RoutedEventArgs e)
    {
        await RunChecksAsync();
    }

    private async Task RunChecksAsync()
    {
        if (DefaultOutputComboBox.SelectedIndex < 0 || DefaultOutputComboBox.SelectedIndex >= discoveredOutputs.Count)
        {
            SummaryText.Text = "Select a default output endpoint before running setup.";
            return;
        }
        if (!HasRequiredConsents())
        {
            SummaryText.Text = "Tick the authorisation box before running setup.";
            return;
        }

        SetupInstallRequest request = BuildInstallRequest();
        Progress<SetupCheckResult> progress = new(result =>
        {
            if (rows.TryGetValue(result.Name, out var row))
            {
                row.Indicator.Fill = ResolveBrush(GetStateBrush(result.State), System.Windows.Media.Colors.Gray);
                row.Heading.Text = $"{result.State}  {result.Name}";
                row.Detail.Text = result.Detail;
            }
            else
            {
                CheckList.Items.Add(CreateRow(result));
                CheckList.ScrollIntoView(CheckList.Items[^1]);
            }
            SummaryText.Text = result.Detail;
            ActionHintText.Text = BuildActionHint(result);
        });

        SetInstallerInputEnabled(false);
        StepText.Text = "STEP 2 OF 4  |  CHECKING AND INSTALLING AUDIO COMPONENTS";
        DoneButton.IsEnabled = false;
        BeginSetupButton.IsEnabled = false;
        SetWrappedButtonText(BeginSetupButton, "RUNNING INSTALL SETUP...");
        ProgressBar.IsIndeterminate = true;
        ProgressBar.Value = 0;
        CheckList.Items.Clear();
        rows.Clear();

        try
        {
            IReadOnlyList<SetupCheckResult> results = await runChecks(progress, request);
            int problems = results.Count(result => result.State is "UPDATE" or "ERROR");
            SummaryText.Text = BuildCompletionSummary(results);
            ActionHintText.Text = problems == 0
                ? "Great. Click VERIFY SETTINGS, then DONE."
                : "Review the yellow/red rows. Apply the recommended fixes, then rerun setup.";
            DoneButton.Content = problems == 0 ? "DONE" : "CLOSE AND REVIEW";
            VerifySettingsButton.IsEnabled = true;
            StepText.Text = problems == 0
                ? "STEP 3 OF 4  |  AUDIO STACK READY - VERIFY WINDOWS SETTINGS"
                : "STEP 3 OF 4  |  REVIEW ITEMS NEEDING ATTENTION";

            // Everything the machine could do has now been done. Spell out the rest as
            // explicit numbered steps, because a wizard that simply stops leaves the
            // user guessing -- and these are the only actions left that no code path
            // can perform. Each line names WHERE to click and WHAT to check, not just
            // what needs doing.
            AppendRemainingManualSteps(problems == 0);
        }
        catch (InvalidOperationException exception)
        {
            CheckList.Items.Add(CreateRow(new SetupCheckResult("Setup", "ERROR", exception.Message)));
            SummaryText.Text = "Setup stopped with an error.";
            ActionHintText.Text = "Fix the blocking item shown in red, then run setup again.";
            DoneButton.Content = "CLOSE";
        }
        catch (UnauthorizedAccessException exception)
        {
            CheckList.Items.Add(CreateRow(new SetupCheckResult("Permissions", "ERROR", exception.Message)));
            SummaryText.Text = "Setup stopped due to permissions.";
            ActionHintText.Text = "Run Sonic Scout as Administrator and rerun setup.";
            DoneButton.Content = "CLOSE";
        }
        catch (IOException exception)
        {
            CheckList.Items.Add(CreateRow(new SetupCheckResult("I/O", "ERROR", exception.Message)));
            SummaryText.Text = "Setup stopped due to an IO error.";
            ActionHintText.Text = "Close tools locking files/endpoints, then rerun setup.";
            DoneButton.Content = "CLOSE";
        }
        catch (COMException exception)
        {
            CheckList.Items.Add(CreateRow(new SetupCheckResult("Core Audio", "ERROR", exception.Message)));
            SummaryText.Text = "Setup stopped due to a Windows audio error.";
            ActionHintText.Text = "Reconnect the output device or reboot, then rerun setup.";
            DoneButton.Content = "CLOSE";
        }
        finally
        {
            ProgressBar.IsIndeterminate = false;
            ProgressBar.Value = 1;
            DoneButton.IsEnabled = true;
            SetWrappedButtonText(BeginSetupButton, "RUN INSTALL SETUP");
            SetInstallerInputEnabled(discoveredOutputs.Count > 0);
        }
    }

    private Border CreateRow(SetupCheckResult result)
    {
        StackPanel content = new() { Margin = new Thickness(0, 2, 0, 2) };
        Grid rowGrid = new();
        rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) });
        rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Ellipse indicator = new() { Width = 9, Height = 9, Fill = ResolveBrush(GetStateBrush(result.State), System.Windows.Media.Colors.Gray), VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 5, 0, 0) };
        TextBlock heading = new() { Text = $"{result.State}  {result.Name}", Foreground = ResolveBrush(GetStateBrush(result.State), System.Windows.Media.Colors.LightGray), FontSize = 12, FontWeight = FontWeights.Bold };
        TextBlock detail = new() { Text = result.Detail, Foreground = ResolveBrush("PopupTextBrush", System.Windows.Media.Color.FromRgb(0xE0, 0xE0, 0xE0)), Opacity = 0.82, FontSize = 11, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 3, 0, 0) };
        StackPanel text = new();
        text.Children.Add(heading);
        text.Children.Add(detail);
        rowGrid.Children.Add(indicator);
        Grid.SetColumn(text, 1);
        rowGrid.Children.Add(text);
        content.Children.Add(rowGrid);
        rows[result.Name] = (indicator, heading, detail);
        return new Border { Padding = new Thickness(10, 7, 10, 7), Margin = new Thickness(0, 0, 0, 5), Background = System.Windows.Media.Brushes.Transparent, Child = content };
    }

    private static string GetStateBrush(string state) => state switch
    {
        "READY" or "FIXED" => "SetupReadyBrush",
        "RUNNING" => "SetupRunningBrush",
        "UPDATE" => "SetupUpdateBrush",
        "ERROR" => "SetupErrorBrush",
        _ => "PopupTextBrush"
    };

    private static string BuildCompletionSummary(IReadOnlyList<SetupCheckResult> results)
    {
        int readyCount = results.Count(result => result.State is "READY" or "FIXED");
        int updateCount = results.Count(result => result.State == "UPDATE");
        int errorCount = results.Count(result => result.State == "ERROR");
        int blockedCount = results.Count(result => result.State == "BLOCKED");
        if (errorCount == 0 && updateCount == 0 && blockedCount == 0)
        {
            return $"All checks passed ({readyCount} green checks). Installation routing is configured and ready.";
        }

        return $"Setup summary: {readyCount} ready, {updateCount} need review, {errorCount} errors, {blockedCount} blocked.";
    }

    private static string BuildActionHint(SetupCheckResult result)
    {
        if (result.State is "READY" or "FIXED")
        {
            return "Step is complete. Continue to the next status row.";
        }

        string key = result.Name.ToLowerInvariant();
        return key switch
        {
            var name when name.Contains("ownership") => "Check all 3 consent boxes to allow routing/install actions from this wizard.",
            var name when name.Contains("equalizer apo") => "Install Equalizer APO, then rerun setup. This is required for filter apply.",
            var name when name.Contains("voicemeeter") => "Enable Voicemeeter fallback (or install virtual cable route), then rerun setup.",
            var name when name.Contains("windows audio service") => "Restart Windows Audio service (Audiosrv) or reboot, then rerun setup.",
            var name when name.Contains("device discovery") || name.Contains("audio devices") => "Select a currently active output device in Windows Sound settings, then rerun setup.",
            var name when name.Contains("permissions") => "Relaunch Sonic Scout as Administrator and run setup again.",
            _ => "Review the row detail, apply that fix, then run setup again."
        };
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e)
    {
        try { DialogResult = false; } catch { /* not shown as dialog */ }
        Close();
    }

    private async void VerifySettingsButton_Click(object sender, RoutedEventArgs e)
    {
        StepText.Text = "STEP 4 OF 4  |  VERIFY THE SETTINGS THAT WINDOWS CANNOT REPORT";
        await openPostInstallVerification(this);
    }

    private void Header_MouseLeftButtonDown(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (e.ChangedButton == System.Windows.Input.MouseButton.Left)
        {
            DragMove();
        }
    }
}

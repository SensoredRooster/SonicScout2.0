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
        Loaded += async (_, _) => await LoadInstallOptionsAsync();
    }

    private async Task LoadInstallOptionsAsync()
    {
        SetInstallerInputEnabled(false);
        ProgressBar.IsIndeterminate = true;
        SummaryText.Text = "Looking for active playback devices...";
        ActionHintText.Text = "We'll auto-detect your available outputs, then you choose where Sonic Scout should play audio.";
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

            DefaultOutputComboBox.SelectedIndex = 0;
            SetupStyleComboBox.SelectedIndex = 0;
            OwnershipConsentCheckBox.IsChecked = false;
            RoutingConsentCheckBox.IsChecked = false;
            DependencyConsentCheckBox.IsChecked = false;
            UpdateSetupStyleHint();
            CheckList.Items.Add(CreateRow(new SetupCheckResult("Device discovery", "READY", $"Discovered {discoveredOutputs.Count} active output endpoint(s).")));
            SummaryText.Text = "Choose your listening device and setup options, then start setup.";
            ActionHintText.Text = "Most users should keep Direct Route. Switch to Compatibility Route only if you use third-party mixers or have routing conflicts.";
            StepText.Text = "STEP 1 OF 4  |  PICK OUTPUT, ROUTE STYLE, AND COMPATIBILITY";
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
        catch (Exception exception)
        {
            CheckList.Items.Add(CreateRow(new SetupCheckResult("Device discovery", "ERROR", $"Unexpected setup error: {exception.Message}")));
            SummaryText.Text = "Device discovery failed unexpectedly.";
            ActionHintText.Text = "Close and reopen setup. If it repeats, run Sonic Scout as Administrator.";
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
            RoutingConsentCheckBox.IsChecked == true,
            DependencyConsentCheckBox.IsChecked == true,
            VoicemeeterCheckBox.IsChecked == true,
            WaveLinkCheckBox.IsChecked == true,
            SoundBlasterCheckBox.IsChecked == true,
            OtherMixerCheckBox.IsChecked == true);
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
            ? "Compatibility Route is safer with third-party mixers (Voicemeeter, Wave Link, custom chains)."
            : "Direct Route (recommended) keeps routing simple and low-latency.";
    }

    private void SetInstallerInputEnabled(bool enabled)
    {
        DefaultOutputComboBox.IsEnabled = enabled;
        SetupStyleComboBox.IsEnabled = enabled;
        OwnershipConsentCheckBox.IsEnabled = enabled;
        RoutingConsentCheckBox.IsEnabled = enabled;
        DependencyConsentCheckBox.IsEnabled = enabled;
        VoicemeeterCheckBox.IsEnabled = enabled;
        WaveLinkCheckBox.IsEnabled = enabled;
        SoundBlasterCheckBox.IsEnabled = enabled;
        OtherMixerCheckBox.IsEnabled = enabled;
        UpdateRunButtonState(enabled);
    }

    private bool HasRequiredConsents()
    {
        return OwnershipConsentCheckBox.IsChecked == true &&
               RoutingConsentCheckBox.IsChecked == true &&
               DependencyConsentCheckBox.IsChecked == true;
    }

    private void UpdateRunButtonState(bool setupInputsEnabled)
    {
        BeginSetupButton.IsEnabled = setupInputsEnabled && discoveredOutputs.Count > 0;
        BeginSetupButton.Content = HasRequiredConsents()
            ? "RUN INSTALL SETUP"
            : "CHECK THE 3 CONSENT BOXES TO CONTINUE";
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
            ActionHintText.Text = "Pick the device you actually hear sound from, then click RUN INSTALL SETUP.";
            return;
        }
        if (!HasRequiredConsents())
        {
            SummaryText.Text = "Confirm ownership, routing apply permission, and dependency acknowledgement before running setup.";
            ActionHintText.Text = "Check all three consent boxes, then click RUN INSTALL SETUP.";
            return;
        }

        SetupInstallRequest request = BuildInstallRequest();
        Progress<SetupCheckResult> progress = new(result =>
        {
            if (rows.TryGetValue(result.Name, out var row))
            {
                row.Indicator.Fill = (System.Windows.Media.Brush)FindResource(GetStateBrush(result.State));
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
        BeginSetupButton.Content = "RUNNING INSTALL SETUP...";
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
        catch (Exception exception)
        {
            CheckList.Items.Add(CreateRow(new SetupCheckResult("Setup", "ERROR", $"Unexpected setup error: {exception.Message}")));
            SummaryText.Text = "Setup stopped due to an unexpected error.";
            ActionHintText.Text = "Rerun setup. If this repeats, run Sonic Scout as Administrator and report this message.";
            DoneButton.Content = "CLOSE";
        }
        finally
        {
            ProgressBar.IsIndeterminate = false;
            ProgressBar.Value = 1;
            DoneButton.IsEnabled = true;
            BeginSetupButton.Content = "RUN INSTALL SETUP";
            SetInstallerInputEnabled(discoveredOutputs.Count > 0);
        }
    }

    private Border CreateRow(SetupCheckResult result)
    {
        StackPanel content = new() { Margin = new Thickness(0, 2, 0, 2) };
        Grid rowGrid = new();
        rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) });
        rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Ellipse indicator = new() { Width = 9, Height = 9, Fill = (System.Windows.Media.Brush)FindResource(GetStateBrush(result.State)), VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 5, 0, 0) };
        TextBlock heading = new() { Text = $"{result.State}  {result.Name}", Foreground = (System.Windows.Media.Brush)FindResource(GetStateBrush(result.State)), FontSize = 12, FontWeight = FontWeights.Bold };
        TextBlock detail = new() { Text = result.Detail, Foreground = (System.Windows.Media.Brush)FindResource("PopupTextBrush"), Opacity = 0.82, FontSize = 11, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 3, 0, 0) };
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
            var name when name.Contains("ownership") => "Check all 3 consent boxes so setup is allowed to apply routing/install changes.",
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

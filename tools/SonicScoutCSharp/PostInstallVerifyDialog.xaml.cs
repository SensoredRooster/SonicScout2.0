using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using NAudio.CoreAudioApi;
using WpfBrush = System.Windows.Media.Brush;
using WpfCheckBox = System.Windows.Controls.CheckBox;

namespace SonicScout;

public sealed record VerificationItem(string Question, string Guidance);
public sealed record VerificationResult(string Question, string State, string Detail);

public static class WindowsSpatialSoundProbe
{
    // Spatial sound (Windows Sonic / Dolby Atmos / DTS:X) is stored as a per-device
    // subkey under MMDevice\Audio\Effects\{GUID}\{PKEY_AudioEndpoint_Format}.
    // NAudio exposes volume and mute but not this flag, so the only reliable read is
    // the registry. The key is created by the user toggling Spatial Sound in Sound
    // Settings; absence means OFF, which is the safe default.
    private const string EffectsRoot = "HKLM\\SYSTEM\\CurrentControlSet\\Control\\MMDevice\\Audio\\Effects";

    public static string Probe(string deviceId)
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            MMDevice? device = enumerator.GetDevice(deviceId);
            if (device == null)
            {
                return "UNKNOWN";
            }

            return IsSpatialSoundOn(deviceId) ? "ON" : "OFF";
        }
        catch (Exception exception)
        {
            return $"ERROR ({exception.Message})";
        }
    }

    private static bool IsSpatialSoundOn(string deviceId)
    {
        using Microsoft.Win32.RegistryKey? effectsRoot = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(EffectsRoot);
        if (effectsRoot == null)
        {
            return false;
        }

        foreach (string effectGuid in effectsRoot.GetSubKeyNames())
        {
            using Microsoft.Win32.RegistryKey? effect = effectsRoot.OpenSubKey(effectGuid);
            if (effect == null)
            {
                continue;
            }

            foreach (string sub in effect.GetSubKeyNames())
            {
                using Microsoft.Win32.RegistryKey? subKey = effect.OpenSubKey(sub);
                if (subKey == null)
                {
                    continue;
                }

                object? state = subKey.GetValue("State");
                if (state is int intState && intState != 0)
                {
                    return true;
                }
            }
        }

        return false;
    }
}

public partial class PostInstallVerifyDialog : Window
{
    private static readonly VerificationItem[] Items =
    [
        new(
            "Is your Windows default playback still your physical device (Realtek etc.)?",
            "It should be. Sonic Scout is opt-in per app, so leave the system default on your Realtek or other physical device. Only change it if you deliberately want every app routed through Sonic Scout."),
        new(
            "Is Windows Spatial Sound turned OFF for that device?",
            "Sound Settings > (device) > Spatial sound. Windows Sonic, Dolby Atmos, and DTS:X will silently block Equalizer APO processing if left on."),
        new(
            "Is the output volume above 0% and not muted?",
            "A muted or zeroed endpoint will pass silence through the whole chain even though Sonic Scout is routing correctly."),
        new(
            "Does the SonicPass panel show it running and not stopped?",
            "Reopen the main window and check the SCOUTPASS status line. If it says STOPPED, click it again to restart the pass."),
    ];

    private readonly List<WpfCheckBox> itemCheckBoxes = new();

    public bool AllConfirmed { get; private set; }

    public PostInstallVerifyDialog()
    {
        InitializeComponent();
        BuildChecklist();
        UpdateSummary();
    }

    private void BuildChecklist()
    {
        // Three of the four items are machine-readable. The fourth (SonicPass
        // status) is a live process state this dialog cannot see, so it stays a
        // self-attestation. Probing the readable three turns the dialog from a
        // tick-box sheet into something that can actually disagree with the user.
        VerificationResult[] probes = RunMachineProbes();

        for (int i = 0; i < Items.Length; i++)
        {
            VerificationItem item = Items[i];
            StackPanel row = new() { Margin = new Thickness(10, 8, 10, 8) };
            WpfCheckBox checkBox = new()
            {
                Content = item.Question,
                FontWeight = FontWeights.SemiBold,
                Foreground = (WpfBrush)FindResource("PopupTextBrush"),
            };
            checkBox.Checked += (_, _) => UpdateSummary();
            checkBox.Unchecked += (_, _) => UpdateSummary();

            TextBlock guidance = new()
            {
                Text = item.Guidance,
                Foreground = (WpfBrush)FindResource("PopupTextBrush"),
                Opacity = 0.75,
                FontSize = 11,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(20, 4, 0, 0),
            };

            // Surface the probe result under the question so a wrong answer is
            // visible without expanding the guidance. The self-attestation item has
            // no probe, so it renders guidance only.
            if (i < probes.Length)
            {
                TextBlock probeLine = new()
                {
                    Text = $"Machine says: {probes[i].State} -- {probes[i].Detail}",
                    Foreground = (WpfBrush)FindResource(
                        probes[i].State == "READY" ? "SetupReadyBrush" : "SetupUpdateBrush"),
                    FontSize = 10.5,
                    FontWeight = FontWeights.SemiBold,
                    Margin = new Thickness(20, 2, 0, 2),
                };
                row.Children.Add(probeLine);
            }

            row.Children.Add(checkBox);
            row.Children.Add(guidance);
            itemCheckBoxes.Add(checkBox);
            ChecklistItemsControl.Items.Add(row);
        }
    }

    private static VerificationResult[] RunMachineProbes()
    {
        VerificationResult[] results = new VerificationResult[3];

        // 1. Default playback device is the physical one the user expects.
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            MMDevice? defaultOutput = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            results[0] = defaultOutput == null
                ? new VerificationResult(Items[0].Question, "UPDATE", "Windows has no default multimedia render device.")
                : new VerificationResult(
                    Items[0].Question,
                    "READY",
                    $"Default is '{defaultOutput.FriendlyName}'. Leave it on your physical device; Sonic Scout is per-app.");
        }
        catch (Exception exception)
        {
            results[0] = new VerificationResult(Items[0].Question, "UPDATE", $"Could not read the default device: {exception.Message}");
        }

        // 2. Spatial Sound is OFF for that device.
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            MMDevice? defaultOutput = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            string spatial = defaultOutput == null ? "UNKNOWN" : WindowsSpatialSoundProbe.Probe(defaultOutput.ID);
            results[1] = spatial == "OFF"
                ? new VerificationResult(Items[1].Question, "READY", "Spatial Sound is off for the default device.")
                : spatial == "ON"
                    ? new VerificationResult(Items[1].Question, "UPDATE", "Spatial Sound is ON. Turn it off in Sound Settings or Equalizer APO will be silently blocked.")
                    : new VerificationResult(Items[1].Question, "UPDATE", $"Could not read the Spatial Sound state ({spatial}).");
        }
        catch (Exception exception)
        {
            results[1] = new VerificationResult(Items[1].Question, "UPDATE", $"Could not read the Spatial Sound state: {exception.Message}");
        }

        // 3. Output volume is above 0% and not muted.
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            MMDevice? defaultOutput = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            if (defaultOutput == null)
            {
                results[2] = new VerificationResult(Items[2].Question, "UPDATE", "Windows has no default multimedia render device.");
            }
            else
            {
                bool muted = defaultOutput.AudioEndpointVolume.Mute;
                float scalar = defaultOutput.AudioEndpointVolume.MasterVolumeLevelScalar;
                results[2] = muted
                    ? new VerificationResult(Items[2].Question, "UPDATE", "The default output is muted.")
                    : scalar <= 0.001f
                        ? new VerificationResult(Items[2].Question, "UPDATE", "The default output volume is at 0%.")
                        : new VerificationResult(Items[2].Question, "READY", $"Default output is unmuted at {scalar:P0}.");
            }
        }
        catch (Exception exception)
        {
            results[2] = new VerificationResult(Items[2].Question, "UPDATE", $"Could not read the output volume: {exception.Message}");
        }

        return results;
    }

    private void UpdateSummary()
    {
        int confirmed = itemCheckBoxes.Count(c => c.IsChecked == true);
        AllConfirmed = confirmed == itemCheckBoxes.Count;
        SummaryText.Text = $"{confirmed} of {itemCheckBoxes.Count} confirmed";
        DoneButton.Content = AllConfirmed ? "DONE - ALL VERIFIED" : "DONE FOR NOW";
    }

    private void OpenSoundSettingsButton_Click(object sender, System.Windows.RoutedEventArgs e)
    {
        try
        {
            Process.Start(new ProcessStartInfo("control", "mmsys.cpl") { UseShellExecute = true });
        }
        catch (System.ComponentModel.Win32Exception)
        {
            SummaryText.Text = "Could not open Windows Sound Settings. Open it manually from the Start menu.";
        }
    }

    private void DoneButton_Click(object sender, System.Windows.RoutedEventArgs e)
    {
        DialogResult = true;
        Close();
    }

    private void CloseButton_Click(object sender, System.Windows.RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }

    private void Header_MouseLeftButtonDown(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (e.ChangedButton == System.Windows.Input.MouseButton.Left)
        {
            DragMove();
        }
    }
}

using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using WpfBrush = System.Windows.Media.Brush;
using WpfCheckBox = System.Windows.Controls.CheckBox;

namespace SonicScout;

public sealed record VerificationItem(string Question, string Guidance);

public partial class PostInstallVerifyDialog : Window
{
    private static readonly VerificationItem[] Items =
    [
        new(
            "Is your default playback device set to the Sonic Scout endpoint?",
            "Windows Sound Settings > Output. The active output must match the endpoint Sonic Scout provisioned during SETUP."),
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
        foreach (VerificationItem item in Items)
        {
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
            row.Children.Add(checkBox);
            row.Children.Add(guidance);
            itemCheckBoxes.Add(checkBox);
            ChecklistItemsControl.Items.Add(row);
        }
    }

    private void UpdateSummary()
    {
        int confirmed = itemCheckBoxes.Count(c => c.IsChecked == true);
        AllConfirmed = confirmed == itemCheckBoxes.Count;
        SummaryText.Text = $"{confirmed} of {itemCheckBoxes.Count} confirmed";
        DoneButton.Content = AllConfirmed ? "DONE - ALL VERIFIED" : "DONE FOR NOW";
    }

    private void OpenSoundSettingsButton_Click(object sender, RoutedEventArgs e)
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

    private void DoneButton_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = true;
        Close();
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e)
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

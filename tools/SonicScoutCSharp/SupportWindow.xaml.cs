using System.Text.Json;
using System.Windows;
using System.Windows.Input;

namespace SonicScout;

public partial class SupportWindow : Window
{
    public SupportWindow()
    {
        InitializeComponent();
        SessionText.Text = $"Session ID: {SupportService.SessionId}";
        DiagnosticsText.Text = JsonSerializer.Serialize(
            SupportService.HealthSnapshot(),
            new JsonSerializerOptions { WriteIndented = true });
    }

    private void CreateBundle_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            string bundle = SupportService.CreateBundle();
            System.Windows.MessageBox.Show(this, $"Support bundle created:\n\n{bundle}", "Support bundle", MessageBoxButton.OK, MessageBoxImage.Information);
        }
        catch (Exception ex)
        {
            SupportService.Log("support_bundle_failed", new { error = ex.Message }, true);
            System.Windows.MessageBox.Show(this, ex.Message, "Support bundle failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private async void SendDiagnostics_Click(object sender, RoutedEventArgs e)
    {
        MessageBoxResult confirm = System.Windows.MessageBox.Show(
            this,
            "Create and send a diagnostic bundle to the SonicScout2.0 developer now?\n\nNo upload occurs unless you confirm this action.",
            "Send diagnostics?",
            MessageBoxButton.YesNo,
            MessageBoxImage.Question);

        if (confirm != MessageBoxResult.Yes)
        {
            return;
        }

        try
        {
            Mouse.OverrideCursor = System.Windows.Input.Cursors.Wait;
            var result = await SupportService.UploadBundleAsync();
            System.Windows.MessageBox.Show(this, $"Diagnostics sent successfully.\nHTTP status: {result.Status}", "Diagnostics sent", MessageBoxButton.OK, MessageBoxImage.Information);
        }
        catch (Exception ex)
        {
            SupportService.Log("support_send_failed", new { error = ex.Message }, true);
            System.Windows.MessageBox.Show(
                this,
                $"{ex.Message}\n\nYou can still create a local support bundle and attach it manually.",
                "Upload failed",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
        finally
        {
            Mouse.OverrideCursor = null;
        }
    }

    private void OpenLogs_Click(object sender, RoutedEventArgs e) => SupportService.OpenLogsFolder();
    private void ReportIssue_Click(object sender, RoutedEventArgs e) => SupportService.ReportIssue();
    private void OpenRepository_Click(object sender, RoutedEventArgs e) => SupportService.OpenRepository();\n    private void OpenTesterShare_Click(object sender, RoutedEventArgs e)\n        => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("https://sonicscout2-share.sensoredrooster-com.workers.dev") { UseShellExecute = true });
    private void Close_Click(object sender, RoutedEventArgs e) => Close();
}

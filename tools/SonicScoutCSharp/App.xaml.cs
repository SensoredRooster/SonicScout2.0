using System.IO;
using System.Windows;
using System.Windows.Threading;

namespace SonicScout;

public partial class App : System.Windows.Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        SupportService.Initialize();

        DispatcherUnhandledException += (_, args) =>
        {
            LogCrash(args.Exception);
            System.Windows.MessageBox.Show(
                $"An unexpected error occurred:\n\n{args.Exception.Message}\n\nSonic Scout will stay open. Check logs for details.",
                "Sonic Scout Error",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            args.Handled = true;
        };

        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            if (args.ExceptionObject is Exception ex)
            {
                LogCrash(ex);
            }
        };

        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            LogCrash(args.Exception);
            args.SetObserved();
        };
    }

    private static void LogCrash(Exception ex)
    {
        try
        {
            SupportService.Log(
                "uncaught_exception",
                new { exception_type = ex.GetType().Name, error = ex.Message, stack = ex.StackTrace },
                error: true);
            string logDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "SonicScout", "logs");
            Directory.CreateDirectory(logDir);
            string logPath = Path.Combine(logDir, "wizard-crash.log");
            File.AppendAllText(logPath,
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {ex.GetType().Name}: {ex.Message}\n{ex.StackTrace}\n\n");
        }
        catch { /* never throw from crash handler */ }
    }
}

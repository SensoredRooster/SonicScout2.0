using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Threading;

namespace SonicScout;

public partial class App : System.Windows.Application
{
    private static readonly object CrashLogLock = new();
    private static readonly string CrashLogPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "SonicScout",
        "logs",
        "wizard-crash.log");

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += OnDispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += OnUnhandledException;
        TaskScheduler.UnobservedTaskException += OnUnobservedTaskException;
    }

    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        LogCrash("DispatcherUnhandledException", e.Exception);
        System.Windows.MessageBox.Show(
            $"Sonic Scout hit an unexpected error but stayed open.\n\n{e.Exception.Message}\n\nCrash log:\n{CrashLogPath}",
            "Sonic Scout setup error",
            MessageBoxButton.OK,
            MessageBoxImage.Error);
        e.Handled = true;
    }

    private static void OnUnhandledException(object sender, UnhandledExceptionEventArgs e)
    {
        if (e.ExceptionObject is Exception exception)
        {
            LogCrash("UnhandledException", exception);
        }
    }

    private static void OnUnobservedTaskException(object? sender, UnobservedTaskExceptionEventArgs e)
    {
        LogCrash("UnobservedTaskException", e.Exception);
        e.SetObserved();
    }

    private static void LogCrash(string source, Exception exception)
    {
        try
        {
            string? folder = Path.GetDirectoryName(CrashLogPath);
            if (!string.IsNullOrWhiteSpace(folder))
            {
                Directory.CreateDirectory(folder);
            }

            StringBuilder builder = new();
            builder.AppendLine("==================================================");
            builder.AppendLine(DateTimeOffset.Now.ToString("O"));
            builder.AppendLine(source);
            builder.AppendLine(exception.ToString());

            lock (CrashLogLock)
            {
                File.AppendAllText(CrashLogPath, builder.ToString());
            }
        }
        catch
        {
            // Best-effort crash logging only.
        }
    }
}

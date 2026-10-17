using System.IO;
using System.Windows;
using System.Windows.Threading;

namespace SonicScout;

public partial class App : System.Windows.Application
{
    /// <summary>Set when Windows relaunched us after a driver-install reboot (RunOnce) to continue SETUP.</summary>
    public static bool ResumeSetupRequested { get; private set; }

    /// <summary>Launched by the HKCU Run entry at sign-in: start minimized.</summary>
    public static bool AutoStartLaunch { get; private set; }

    private const string SingleInstanceName = @"Local\SonicScout.App.SingleInstance";
    private const string ShowEventName = @"Local\SonicScout.App.Show";
    private const string ResumeEventName = @"Local\SonicScout.App.ResumeSetup";
    private static Mutex? singleInstance;
    private static EventWaitHandle? showEvent, resumeEvent;

    protected override void OnStartup(StartupEventArgs e)
    {
        ResumeSetupRequested = e.Args.Any(a => string.Equals(a, SetupResume.CommandLineFlag, StringComparison.OrdinalIgnoreCase));
        AutoStartLaunch = AutoStart.IsAutoStartLaunch(e.Args);
        // A setup resume is still queued for this sign-in (RunOnce not yet processed): behave as the resume.
        if (AutoStartLaunch && !ResumeSetupRequested && AutoStart.ResumePending()) ResumeSetupRequested = true;

        // Single instance per user session. A second launch hands off to the running one:
        // a plain launch shows its window, a --resume-setup launch asks it to resume SETUP,
        // an --autostart launch just exits.
        singleInstance = new Mutex(true, SingleInstanceName, out bool firstInstance);
        if (!firstInstance)
        {
            if (!AutoStartLaunch || ResumeSetupRequested)
            {
                try { using EventWaitHandle signal = EventWaitHandle.OpenExisting(ResumeSetupRequested ? ResumeEventName : ShowEventName); signal.Set(); }
                catch (Exception ex) when (ex is WaitHandleCannotBeOpenedException or UnauthorizedAccessException) { }
            }
            Environment.Exit(0);
            return;
        }
        showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
        resumeEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ResumeEventName);
        Thread listener = new(() =>
        {
            WaitHandle[] handles = [showEvent, resumeEvent];
            while (true)
            {
                int which = WaitHandle.WaitAny(handles);
                Dispatcher.BeginInvoke(new Action(() => (MainWindow as MainWindow)?.ActivateFromSecondInstance(resume: which == 1)));
            }
        }) { IsBackground = true, Name = "SingleInstanceListener" };
        listener.Start();
        AutoStart.ApplyForCurrentUser(AutoStart.LoadEnabled());
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

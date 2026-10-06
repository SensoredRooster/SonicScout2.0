using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using SonicScout;

/// <summary>
/// Scenario harness for the REAL SetupWindow.xaml / .xaml.cs.
///
/// Every behaviour the window needs is injected as a stub, so no discovery, installer,
/// driver or audio-device work runs. That lets us reach states which are otherwise
/// very hard to produce on a live machine: no endpoints at all, a COM failure,
/// a permission failure, checks that come back failing.
///
/// Two jobs per scenario:
///   - assert the LOGIC (which output got selected, which boxes got ticked, whether
///     the run button is enabled, what the step text says)
///   - optionally RENDER the state to PNG so it can be looked at
///
/// The window must be Shown(): an unshown WPF Window never runs layout and
/// RenderTargetBitmap returns a blank bitmap for both the Window and its content.
/// </summary>
internal static class Program
{
    private const double W = 720, H = 700;
    private const int S = 2;

    private static string _outDir = "";
    private static readonly List<(string Name, bool Ok, string Detail)> Results = new();

    private static void Assert(string name, bool ok, string detail = "")
    {
        Results.Add((name, ok, detail));
        Console.WriteLine($"  [{(ok ? "PASS" : "FAIL")}] {name}{(detail.Length > 0 ? " -- " + detail : "")}");
    }

    [STAThread]
    private static int Main(string[] args)
    {
        _outDir = args.Length > 0 ? args[0] : Directory.GetCurrentDirectory();
        Directory.CreateDirectory(_outDir);

        // Wipe PNGs from a PREVIOUS render run so the directory can only ever
        // contain frames from this invocation. Without this, a blank render
        // followed by a real one left two files and the stale one made it look
        // like the suite had rendered more than it had.
        foreach (string stale in Directory.GetFiles(_outDir, "*.png"))
            File.Delete(stale);

        SynchronizationContext.SetSynchronizationContext(
            new DispatcherSynchronizationContext(Dispatcher.CurrentDispatcher));
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };

        Func<Window, Task> noopPost = w => Task.CompletedTask;
        var endpoints = new List<AudioEndpointOption> { new("physical", "Speakers (Realtek Audio)") };
        var blocked = new [] { new SetupCheckResult("Required installer", "BLOCKED", "Installation was blocked.") };
        var win = Build(app, () => Task.FromResult<IReadOnlyList<AudioEndpointOption>>(endpoints),
            (prog, req) => { prog.Report(blocked[0]); return Task.FromResult<IReadOnlyList<SetupCheckResult>>(blocked); }, noopPost, "blocked");
        Pump(400); Layout(win);
        if (Field<CheckBox>(win, "OwnershipConsentCheckBox") is { } consent) consent.IsChecked = true;
        Pump(100);
        Field<Button>(win, "BeginSetupButton")?.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
        Pump(1200); Layout(win);
        var step=Field<TextBlock>(win,"StepText")?.Text ?? "";
        var hint=Field<TextBlock>(win,"ActionHintText")?.Text ?? "";
        var summary=Field<TextBlock>(win,"SummaryText")?.Text ?? "";
        var done=Field<Button>(win,"DoneButton")?.Content?.ToString() ?? "";
        File.WriteAllText(Path.Combine(_outDir,"blocked-result.txt"),$"Summary: {summary}\nStep: {step}\nHint: {hint}\nDone: {done}\n");
        Assert("Blocked installation must not say AUDIO STACK READY",!step.Contains("AUDIO STACK READY"),step);
        Assert("Blocked installation must not show DONE",done != "DONE",done);
        Shot(win,"blocked-install.png"); win.Close();
        app.Shutdown();

        // =====================================================================
        Console.WriteLine("\n================ SUMMARY ================");
        int pass = Results.Count(r => r.Ok);
        int fail = Results.Count - pass;
        Console.WriteLine($"PASS {pass}   FAIL {fail}   TOTAL {Results.Count}");
        foreach (var r in Results.Where(r => !r.Ok))
            Console.WriteLine($"  FAILED: {r.Name} -- {r.Detail}");
        return fail == 0 ? 0 : 1;
    }

    // -----------------------------------------------------------------------
    private static SetupWindow Build(
        Application app,
        Func<Task<IReadOnlyList<AudioEndpointOption>>> discover,
        Func<IProgress<SetupCheckResult>, SetupInstallRequest, Task<IReadOnlyList<SetupCheckResult>>> checks,
        Func<Window, Task> postVerify,
        string tag)
    {
        var win = new SetupWindow(discover, checks, postVerify)
        {
            WindowStartupLocation = WindowStartupLocation.CenterScreen,
            ShowActivated = false,
        };
        win.Show();
        return win;
    }

    private static void Layout(Window w)
    {
        w.Width = W;
        w.Height = H;
        w.Measure(new Size(W, H));
        w.Arrange(new Rect(0, 0, W, H));
        w.UpdateLayout();
    }

    private static string ChecklistText(Window w)
    {
        var list = Field<ItemsControl>(w, "CheckList");
        if (list == null) return "";
        var sb = new System.Text.StringBuilder();
        foreach (string line in EnumerateText(list))
            sb.AppendLine(line);
        return sb.ToString();
    }

    private static IEnumerable<string> EnumerateText(DependencyObject root)
    {
        if (root is TextBlock tb && !string.IsNullOrEmpty(tb.Text))
            yield return tb.Text;
        for (int i = 0; i < System.Windows.Media.VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = System.Windows.Media.VisualTreeHelper.GetChild(root, i);
            foreach (string line in EnumerateText(child))
                yield return line;
        }
    }

    private static void Shot(Window w, string name)
    {
        w.UpdateLayout();
        var visual = (w.Content as Visual) ?? w;
        var bmp = new RenderTargetBitmap((int)(W * S), (int)(H * S), 96 * S, 96 * S, PixelFormats.Pbgra32);
        bmp.Render(visual);
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(bmp));
        using var fs = File.Create(Path.Combine(_outDir, name));
        enc.Save(fs);
        Console.WriteLine("  rendered " + name);
    }

    private static void Pump(int ms)
    {
        var frame = new DispatcherFrame();
        var timer = new DispatcherTimer(
            TimeSpan.FromMilliseconds(ms), DispatcherPriority.Normal,
            (_, _) => frame.Continue = false, Dispatcher.CurrentDispatcher);
        Dispatcher.PushFrame(frame);
    }

    private static object? Field(object? target, string name)
    {
        var t = target?.GetType();
        while (t != null)
        {
            var f = t.GetField(name, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
            if (f != null) return f.GetValue(target);
            t = t.BaseType;
        }
        return null;
    }

    private static T? Field<T>(object? target, string name) where T : class =>
        Field(target, name) as T;

    private static T? Invoke<T>(object? target, string method) where T : class
    {
        var t = target?.GetType();
        while (t != null)
        {
            var m = t.GetMethod(method, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
            if (m != null) return m.Invoke(target, null) as T;
            t = t.BaseType;
        }
        return null;
    }
}


using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Path = System.IO.Path;
using WpfBrush = System.Windows.Media.Brush;
using WpfButton = System.Windows.Controls.Button;
using WpfRectangle = System.Windows.Shapes.Rectangle;

namespace SonicScout;

/// <summary>
/// Real-time analyzer + editable target curve ("ArtTuneKit-style" graph). Drag a handle up/down
/// to boost/cut that band; the curve is written to %LOCALAPPDATA%\SonicScout\eapo\user_target.txt
/// (included by sonicscout.txt) shortly after you stop moving, so Equalizer APO applies it live.
/// </summary>
public partial class MainWindow
{
    private const double GraphTopPad = 14, GraphBottomPad = 18, HandleSize = 13;
    private readonly TargetCurveStore targetStore = new();
    private readonly string currentTargetPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SonicScout", "targets", "current-target.json");
    private TargetCurve currentTarget = TargetCurve.Flat("Flat");
    private bool targetGraphInitialized;
    private bool targetDirty;
    private int draggingHandle = -1;
    private readonly DispatcherTimer targetApplyTimer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private readonly List<WpfRectangle> spectrumBars = new();
    private readonly List<Ellipse> targetHandles = new();
    private Polyline? targetLine;
    private Polyline? zeroLine;
    private double graphWidth, graphHeight;
    private bool suppressTargetSelection;

    private void InitializeTargetGraph()
    {
        if (targetGraphInitialized) return;
        targetGraphInitialized = true;
        try
        {
            if (File.Exists(currentTargetPath))
                currentTarget = TargetCurve.Parse(File.ReadAllText(currentTargetPath), "Custom Target").ResampleToDefaultBands();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or FormatException)
        {
            currentTarget = TargetCurve.Flat("Flat");
        }
        targetApplyTimer.Tick += (_, _) => { targetApplyTimer.Stop(); ApplyTargetLive(); };
        SpectrumCanvas.Background = System.Windows.Media.Brushes.Transparent; // hit-testable
        SpectrumCanvas.MouseLeftButtonDown += SpectrumCanvas_MouseLeftButtonDown;
        SpectrumCanvas.MouseMove += SpectrumCanvas_MouseMove;
        SpectrumCanvas.MouseLeftButtonUp += SpectrumCanvas_MouseLeftButtonUp;
        SpectrumCanvas.LostMouseCapture += (_, _) => EndTargetDrag();
        SpectrumCanvas.ToolTip = "Drag a dot up or down to fine-tune that band. Changes apply live through Equalizer APO.";
        RefreshTargetList();
        UpdateTargetStatus();
    }

    /// <summary>Called from EnsureApoLink before sonicscout.txt includes user_target.txt.</summary>
    private void EnsureUserTargetFileExists()
    {
        if (!targetGraphInitialized && File.Exists(currentTargetPath))
        {
            try { currentTarget = TargetCurve.Parse(File.ReadAllText(currentTargetPath), "Custom Target").ResampleToDefaultBands(); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or FormatException) { }
        }
        if (!File.Exists(targetStore.LiveApoPath)) targetStore.ApplyLive(currentTarget);
    }

    private void ResetTargetGraphVisuals()
    {
        SpectrumCanvas.Children.Clear();
        spectrumBars.Clear();
        targetHandles.Clear();
        targetLine = null;
        zeroLine = null;
        graphWidth = graphHeight = 0;
    }

    private double GainToY(double db) =>
        GraphTopPad + ((TargetCurve.MaxGainDb - db) / (TargetCurve.MaxGainDb - TargetCurve.MinGainDb) * (graphHeight - GraphTopPad - GraphBottomPad));

    private double YToGain(double y) =>
        TargetCurve.MaxGainDb - ((y - GraphTopPad) / Math.Max(1, graphHeight - GraphTopPad - GraphBottomPad) * (TargetCurve.MaxGainDb - TargetCurve.MinGainDb));

    private double FreqToCanvasX(double hz) => SpectrumAnalyzer.FrequencyToX(hz) * graphWidth;

    private void BuildGraphVisuals()
    {
        ResetTargetGraphVisuals();
        graphWidth = SpectrumCanvas.ActualWidth;
        graphHeight = SpectrumCanvas.ActualHeight;
        WpfBrush grid = new SolidColorBrush(System.Windows.Media.Color.FromArgb(48, 255, 255, 255));
        WpfBrush label = new SolidColorBrush(System.Windows.Media.Color.FromArgb(150, 255, 255, 255));
        foreach (double hz in new double[] { 50, 100, 200, 500, 1000, 2000, 5000, 10000 })
        {
            double x = FreqToCanvasX(hz);
            SpectrumCanvas.Children.Add(new Line { X1 = x, X2 = x, Y1 = 0, Y2 = graphHeight - GraphBottomPad + 4, Stroke = grid, StrokeThickness = 1, IsHitTestVisible = false });
            TextBlock t = new() { Text = hz >= 1000 ? $"{hz / 1000:0.#}k" : $"{hz:0}", FontSize = 9, Foreground = label, IsHitTestVisible = false };
            Canvas.SetLeft(t, x - 8); Canvas.SetTop(t, graphHeight - GraphBottomPad + 3);
            SpectrumCanvas.Children.Add(t);
        }
        foreach (double db in new double[] { 12, 6, -6, -12 })
        {
            double y = GainToY(db);
            SpectrumCanvas.Children.Add(new Line { X1 = 0, X2 = graphWidth, Y1 = y, Y2 = y, Stroke = grid, StrokeThickness = 1, StrokeDashArray = new DoubleCollection { 2, 4 }, IsHitTestVisible = false });
            TextBlock t = new() { Text = $"{db:+0;-0} dB", FontSize = 9, Foreground = label, IsHitTestVisible = false };
            Canvas.SetLeft(t, 2); Canvas.SetTop(t, y - 12);
            SpectrumCanvas.Children.Add(t);
        }

        WpfBrush barBrush = new SolidColorBrush(ParseColor(activeTheme.Secondary)) { Opacity = 0.55 };
        double bandWidth = graphWidth / SpectrumBandCount;
        for (int i = 0; i < SpectrumBandCount; i++)
        {
            WpfRectangle bar = new() { Width = Math.Max(1, bandWidth - 2), Height = 0, Fill = barBrush, IsHitTestVisible = false, RadiusX = 1, RadiusY = 1 };
            Canvas.SetLeft(bar, (i * bandWidth) + 1);
            Canvas.SetTop(bar, graphHeight - GraphBottomPad);
            SpectrumCanvas.Children.Add(bar);
            spectrumBars.Add(bar);
        }

        zeroLine = new Polyline { Stroke = grid, StrokeThickness = 1.5, IsHitTestVisible = false };
        zeroLine.Points.Add(new System.Windows.Point(0, GainToY(0)));
        zeroLine.Points.Add(new System.Windows.Point(graphWidth, GainToY(0)));
        SpectrumCanvas.Children.Add(zeroLine);

        targetLine = new Polyline { Stroke = new SolidColorBrush(ParseColor(activeTheme.Highlight)), StrokeThickness = 2.5, IsHitTestVisible = false };
        SpectrumCanvas.Children.Add(targetLine);
        WpfBrush handleFill = new SolidColorBrush(ParseColor(activeTheme.Highlight));
        for (int i = 0; i < currentTarget.Count; i++)
        {
            Ellipse handle = new() { Width = HandleSize, Height = HandleSize, Fill = handleFill, Stroke = System.Windows.Media.Brushes.White, StrokeThickness = 1.5, Cursor = System.Windows.Input.Cursors.SizeNS };
            AutomationProperties.SetAutomationId(handle, $"TargetHandle{i}");
            SpectrumCanvas.Children.Add(handle);
            targetHandles.Add(handle);
        }
        LayoutTargetCurve();
    }

    private void LayoutTargetCurve()
    {
        if (targetLine is null || graphWidth <= 0) return;
        targetLine.Points.Clear();
        for (int i = 0; i <= 120; i++)
        {
            double hz = SpectrumAnalyzer.XToFrequency(i / 120.0);
            targetLine.Points.Add(new System.Windows.Point(FreqToCanvasX(hz), GainToY(currentTarget.GainAt(hz))));
        }
        for (int i = 0; i < targetHandles.Count && i < currentTarget.Count; i++)
        {
            Canvas.SetLeft(targetHandles[i], FreqToCanvasX(currentTarget.Frequencies[i]) - (HandleSize / 2));
            Canvas.SetTop(targetHandles[i], GainToY(currentTarget.Gains[i]) - (HandleSize / 2));
            targetHandles[i].ToolTip = $"{FormatHz(currentTarget.Frequencies[i])}: {currentTarget.Gains[i]:+0.0;-0.0;0.0} dB";
        }
    }

    private static string FormatHz(double hz) => hz >= 1000 ? $"{hz / 1000:0.#} kHz" : $"{hz:0} Hz";

    private readonly double[] lastRenderedLevels = new double[SpectrumBandCount];
    private bool spectrumRendered;

    private void RenderSpectrum()
    {
        if (audioConfigurationInProgress) return;
        if (SpectrumCanvas.ActualWidth <= 0 || SpectrumCanvas.ActualHeight <= 0) return;
        InitializeTargetGraph();
        if ((DateTime.UtcNow - lastAudioDataAtUtc).TotalMilliseconds > 900) TryRefreshSpectrumFromAudioMeter();
        if (spectrumBars.Count != SpectrumBandCount || Math.Abs(graphWidth - SpectrumCanvas.ActualWidth) > 1 || Math.Abs(graphHeight - SpectrumCanvas.ActualHeight) > 1)
            { BuildGraphVisuals(); spectrumRendered = false; }

        double[] levels = spectrumRenderCopy;
        lock (spectrumLock) Array.Copy(spectrumLevels, levels, spectrumLevels.Length);
        bool changed = !spectrumRendered;
        for (int i = 0; i < levels.Length && !changed; i++)
            if (Math.Abs(levels[i] - lastRenderedLevels[i]) > 0.002) changed = true;
        if (!changed) return; // silence / steady state: no repaint of the layered window
        Array.Copy(levels, lastRenderedLevels, levels.Length);
        spectrumRendered = true;
        SpectrumStatusText.Visibility = audioSignalSeen ? Visibility.Collapsed : Visibility.Visible;
        double usable = graphHeight - GraphTopPad - GraphBottomPad;
        for (int i = 0; i < spectrumBars.Count; i++)
        {
            double v = double.IsFinite(levels[i]) ? Math.Clamp(levels[i], 0, 1) : 0;
            double h = v * usable;
            spectrumBars[i].Height = h;
            Canvas.SetTop(spectrumBars[i], graphHeight - GraphBottomPad - h);
        }
    }

    private int NearestHandle(System.Windows.Point p)
    {
        int best = -1; double bestDistance = double.MaxValue;
        for (int i = 0; i < currentTarget.Count; i++)
        {
            double d = Math.Abs(FreqToCanvasX(currentTarget.Frequencies[i]) - p.X);
            if (d < bestDistance) { bestDistance = d; best = i; }
        }
        return bestDistance <= Math.Max(18, graphWidth / (currentTarget.Count * 2.2)) ? best : -1;
    }

    private void SpectrumCanvas_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        System.Windows.Point p = e.GetPosition(SpectrumCanvas);
        draggingHandle = NearestHandle(p);
        if (draggingHandle < 0) return;
        SpectrumCanvas.CaptureMouse();
        if (e.ClickCount == 2) { SetTargetGain(draggingHandle, 0); EndTargetDrag(); }
        else SetTargetGain(draggingHandle, YToGain(p.Y));
        e.Handled = true;
    }

    private void SpectrumCanvas_MouseMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (draggingHandle < 0 || e.LeftButton != MouseButtonState.Pressed) return;
        SetTargetGain(draggingHandle, YToGain(e.GetPosition(SpectrumCanvas).Y));
    }

    private void SpectrumCanvas_MouseLeftButtonUp(object sender, MouseButtonEventArgs e) => EndTargetDrag();

    private void EndTargetDrag()
    {
        if (draggingHandle < 0) return;
        draggingHandle = -1;
        if (SpectrumCanvas.IsMouseCaptured) SpectrumCanvas.ReleaseMouseCapture();
        targetApplyTimer.Stop();
        ApplyTargetLive();
    }

    /// <summary>Changes one band (also used by keyboard / UI automation via TargetNudge).</summary>
    private void SetTargetGain(int index, double db)
    {
        double before = currentTarget.Gains[index];
        currentTarget.SetGain(index, Math.Round(db * 2) / 2); // 0.5 dB steps while dragging
        if (Math.Abs(before - currentTarget.Gains[index]) < 0.01) return;
        targetDirty = true;
        LayoutTargetCurve();
        UpdateTargetStatus();
        // Debounced: Equalizer APO reloads its whole chain on each file change, so never write
        // on every mouse-move. One write ~250 ms after movement pauses, one more on release.
        targetApplyTimer.Stop();
        targetApplyTimer.Start();
    }

    private void ApplyTargetLive()
    {
        try
        {
            bool changed = targetStore.ApplyLive(currentTarget);
            Directory.CreateDirectory(Path.GetDirectoryName(currentTargetPath)!);
            File.WriteAllText(currentTargetPath + ".tmp", currentTarget.ToJson());
            File.Move(currentTargetPath + ".tmp", currentTargetPath, overwrite: true);
            if (changed) EnsureApoLink();
            UpdateTargetStatus();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            MessageText.Text = $"Could not write the live target ({targetStore.LiveApoPath}): {ex.Message}";
        }
    }

    private void UpdateTargetStatus()
    {
        if (TargetStatusText is null) return;
        string link = apoLinked ? "LIVE IN EQUALIZER APO" : "NOT LINKED - run SETUP";
        string mod = targetDirty ? " (unsaved)" : string.Empty;
        TargetStatusText.Text = currentTarget.IsFlat
            ? $"TARGET: {currentTarget.Name}{mod} - flat, no processing - {link}"
            : $"TARGET: {currentTarget.Name}{mod} - preamp {currentTarget.PreampDb:0.0} dB - {link}";
    }

    private void RefreshTargetList(string? select = null)
    {
        suppressTargetSelection = true;
        try
        {
            TargetComboBox.Items.Clear();
            TargetComboBox.Items.Add("Flat (reset)");
            foreach (string name in targetStore.ListNames()) TargetComboBox.Items.Add(name);
            string want = select ?? currentTarget.Name;
            int index = TargetComboBox.Items.IndexOf(want);
            TargetComboBox.SelectedIndex = index >= 0 ? index : -1;
        }
        finally { suppressTargetSelection = false; }
    }

    private void TargetComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (suppressTargetSelection || TargetComboBox.SelectedItem is not string name) return;
        try
        {
            currentTarget = TargetComboBox.SelectedIndex == 0 ? TargetCurve.Flat("Flat") : targetStore.Load(name).ResampleToDefaultBands();
            targetDirty = false;
            LayoutTargetCurve();
            ApplyTargetLive();
            MessageText.Text = $"Target '{currentTarget.Name}' loaded and applied.";
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or FormatException)
        {
            MessageText.Text = $"Could not load target '{name}': {ex.Message}";
        }
    }

    private void TargetSaveButton_Click(object sender, RoutedEventArgs e)
    {
        string suggested = currentTarget.Name is "Flat" or "Custom Target" ? "My Target" : currentTarget.Name;
        string? name = PromptForTargetName(suggested);
        if (string.IsNullOrWhiteSpace(name)) return;
        if (File.Exists(targetStore.PathFor(name)) &&
            System.Windows.MessageBox.Show(this, $"A target named '{name}' already exists. Replace it?", "Save target", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes)
            return;
        try
        {
            currentTarget.Name = name.Trim();
            string path = targetStore.Save(currentTarget);
            targetDirty = false;
            ApplyTargetLive();
            RefreshTargetList(currentTarget.Name);
            MessageText.Text = $"Target '{currentTarget.Name}' saved to {path}.";
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            MessageText.Text = $"Could not save the target: {ex.Message}";
        }
    }

    private void TargetExportButton_Click(object sender, RoutedEventArgs e)
    {
        Microsoft.Win32.SaveFileDialog dialog = new()
        {
            Title = "Export SonicScout target",
            FileName = TargetCurveStore.SanitizeFileName(currentTarget.Name) + TargetCurveStore.FileExtension,
            Filter = "SonicScout target (*.sstarget.json)|*.sstarget.json|Equalizer APO GraphicEQ (*.txt)|*.txt",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments)
        };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            TargetCurveStore.Export(currentTarget, dialog.FileName);
            MessageText.Text = $"Target exported to {dialog.FileName}.";
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            MessageText.Text = $"Could not export the target: {ex.Message}";
        }
    }

    private void TargetImportButton_Click(object sender, RoutedEventArgs e)
    {
        Microsoft.Win32.OpenFileDialog dialog = new()
        {
            Title = "Import target",
            Filter = "Targets (*.sstarget.json;*.json;*.txt;*.csv)|*.sstarget.json;*.json;*.txt;*.csv|All files (*.*)|*.*",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments)
        };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            currentTarget = TargetCurveStore.Import(dialog.FileName);
            targetStore.Save(currentTarget);
            targetDirty = false;
            LayoutTargetCurve();
            ApplyTargetLive();
            RefreshTargetList(currentTarget.Name);
            MessageText.Text = $"Imported '{currentTarget.Name}', saved it to your targets and applied it.";
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or FormatException)
        {
            MessageText.Text = $"Could not import {Path.GetFileName(dialog.FileName)}: {ex.Message}";
        }
    }

    private void TargetResetButton_Click(object sender, RoutedEventArgs e)
    {
        string name = currentTarget.Name;
        currentTarget = TargetCurve.Flat(name);
        targetDirty = true;
        LayoutTargetCurve();
        ApplyTargetLive();
        MessageText.Text = "Target reset to flat (not saved until you press SAVE).";
    }

    private string? PromptForTargetName(string suggested)
    {
        Window prompt = new()
        {
            Title = "Save target", Owner = this, Width = 360, SizeToContent = SizeToContent.Height,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ResizeMode = ResizeMode.NoResize,
            Background = (WpfBrush)FindResource("PanelBrush")
        };
        StackPanel panel = new() { Margin = new Thickness(16) };
        panel.Children.Add(new TextBlock { Text = "Name this target:", Foreground = (WpfBrush)FindResource("SurfaceTextBrush"), Margin = new Thickness(0, 0, 0, 6) });
        System.Windows.Controls.TextBox box = new() { Text = suggested, Height = 26 };
        AutomationProperties.SetAutomationId(box, "TargetNameTextBox");
        panel.Children.Add(box);
        StackPanel buttons = new() { Orientation = System.Windows.Controls.Orientation.Horizontal, HorizontalAlignment = System.Windows.HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        WpfButton ok = new() { Content = "SAVE", IsDefault = true, Width = 80, Margin = new Thickness(0, 0, 8, 0) };
        AutomationProperties.SetAutomationId(ok, "TargetNameOk");
        WpfButton cancel = new() { Content = "CANCEL", IsCancel = true, Width = 80 };
        ok.Click += (_, _) => prompt.DialogResult = !string.IsNullOrWhiteSpace(box.Text);
        buttons.Children.Add(ok); buttons.Children.Add(cancel);
        panel.Children.Add(buttons);
        prompt.Content = panel;
        prompt.Loaded += (_, _) => { box.Focus(); box.SelectAll(); };
        return prompt.ShowDialog() == true ? box.Text.Trim() : null;
    }

    /// <summary>Keyboard fine-tuning: focus the graph, Left/Right picks a band, Up/Down nudges 0.5 dB.</summary>
    private int keyboardBand = 5;
    private void SpectrumCanvas_KeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Left: keyboardBand = Math.Max(0, keyboardBand - 1); break;
            case Key.Right: keyboardBand = Math.Min(currentTarget.Count - 1, keyboardBand + 1); break;
            case Key.Up: SetTargetGain(keyboardBand, currentTarget.Gains[keyboardBand] + 0.5); break;
            case Key.Down: SetTargetGain(keyboardBand, currentTarget.Gains[keyboardBand] - 0.5); break;
            default: return;
        }
        MessageText.Text = $"{FormatHz(currentTarget.Frequencies[keyboardBand])}: {currentTarget.Gains[keyboardBand]:+0.0;-0.0;0.0} dB";
        e.Handled = true;
    }
}

/// <summary>Canvas with a UI Automation peer so the graph is focusable/locatable by screen readers and tests.</summary>
public sealed class TargetGraphCanvas : System.Windows.Controls.Canvas
{
    protected override System.Windows.Automation.Peers.AutomationPeer OnCreateAutomationPeer() =>
        new TargetGraphAutomationPeer(this);

    private sealed class TargetGraphAutomationPeer : System.Windows.Automation.Peers.FrameworkElementAutomationPeer
    {
        public TargetGraphAutomationPeer(TargetGraphCanvas owner) : base(owner) { }
        protected override System.Windows.Automation.Peers.AutomationControlType GetAutomationControlTypeCore() =>
            System.Windows.Automation.Peers.AutomationControlType.Custom;
        protected override string GetClassNameCore() => nameof(TargetGraphCanvas);
        protected override bool IsKeyboardFocusableCore() => true;
    }
}

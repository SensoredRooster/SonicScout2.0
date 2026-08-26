using System.Windows;

namespace SonicScout;

public partial class ConfirmProfileDeleteWindow : Window
{
    public ConfirmProfileDeleteWindow(string profileName)
    {
        InitializeComponent();
        MessageText.Text = $"Delete '{profileName}'? This removes its saved EQ settings.";
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
    }

    private void Delete_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = true;
    }

    private void Header_MouseLeftButtonDown(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (e.ChangedButton == System.Windows.Input.MouseButton.Left)
        {
            DragMove();
        }
    }
}

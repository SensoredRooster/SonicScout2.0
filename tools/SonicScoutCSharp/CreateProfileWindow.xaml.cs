using System.Windows;

namespace SonicScout;

public partial class CreateProfileWindow : Window
{
    public string ProfileName => NameBox.Text.Trim();
    public string GameTag => GameBox.Text.Trim();
    public string FilterContent => FiltersBox.Text.Trim();

    public CreateProfileWindow()
    {
        InitializeComponent();
        FiltersBox.Text = "Preamp: 0.0 dB\nFilter 1: ON PK Fc 100 Hz Gain 0.0 dB Q 1.00";
        NameBox.Focus();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
    }

    private void DialogHeader_MouseLeftButtonDown(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (e.ChangedButton == System.Windows.Input.MouseButton.Left)
        {
            DragMove();
        }
    }

    private void Create_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(ProfileName) || string.IsNullOrWhiteSpace(FilterContent))
        {
            DialogTitleText.Text = "PROFILE NAME AND FILTERS REQUIRED";
            return;
        }

        DialogResult = true;
    }
}

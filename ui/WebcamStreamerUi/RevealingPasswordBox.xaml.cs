using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;

namespace WebcamStreamerUi;

// Password input that briefly reveals each character as it's typed,
// then masks it after a short delay -- the iOS/Android keyboard
// pattern. Trade-off vs. a regular PasswordBox: the user can verify
// what they typed without showing the entire password.
//
// Design:
//   - The visible TextBox stores ONLY the masked representation; the
//     real password lives in a separate string field that we mutate
//     ourselves on every keystroke (PreviewTextInput + PreviewKeyDown
//     for Back/Delete). We Handle those events so the TextBox never
//     sees the raw chars -- it only ever holds bullets + the briefly-
//     revealed last char.
//   - On blur or after kHideAfter elapses, the last char re-masks.
//   - Paste re-uses the paste handler but masks fully (no per-char
//     reveal for pasted chunks).
public partial class RevealingPasswordBox : UserControl
{
    private const string kBullet = "•";
    private static readonly TimeSpan kHideAfter = TimeSpan.FromMilliseconds(800);

    private string _real = "";
    private readonly DispatcherTimer _hideTimer;

    public static readonly DependencyProperty PasswordProperty =
        DependencyProperty.Register(
            nameof(Password), typeof(string), typeof(RevealingPasswordBox),
            new FrameworkPropertyMetadata("", FrameworkPropertyMetadataOptions.BindsTwoWayByDefault,
                OnPasswordChanged));

    public string Password
    {
        get => (string)GetValue(PasswordProperty);
        set => SetValue(PasswordProperty, value);
    }

    public RevealingPasswordBox()
    {
        InitializeComponent();
        _hideTimer = new DispatcherTimer { Interval = kHideAfter };
        _hideTimer.Tick += (_, _) => { _hideTimer.Stop(); MaskAll(); };
        DataObject.AddPastingHandler(Input, OnPaste);
    }

    private static void OnPasswordChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        // External update from a binding: sync internal state + display.
        // Skip when we're the source of the change (we set Password
        // ourselves on each keystroke).
        var box = (RevealingPasswordBox)d;
        var newVal = (string?)e.NewValue ?? "";
        if (newVal == box._real) return;
        box._real = newVal;
        box.MaskAll();
    }

    private void MaskAll()
    {
        Input.Text = string.Concat(Enumerable.Repeat(kBullet, _real.Length));
    }

    private void Input_PreviewTextInput(object sender, TextCompositionEventArgs e)
    {
        int selStart = Input.SelectionStart;
        int selLen   = Input.SelectionLength;
        _real = _real.Remove(selStart, selLen).Insert(selStart, e.Text);
        // Display: all bullets, with the just-typed run shown verbatim.
        var sb = new System.Text.StringBuilder(string.Concat(Enumerable.Repeat(kBullet, _real.Length)));
        for (int i = 0; i < e.Text.Length; i++) sb[selStart + i] = e.Text[i];
        Input.Text = sb.ToString();
        Input.CaretIndex = selStart + e.Text.Length;
        e.Handled = true;
        Password = _real;
        _hideTimer.Stop();
        _hideTimer.Start();
    }

    private void Input_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Back && e.Key != Key.Delete) return;
        int selStart = Input.SelectionStart;
        int selLen   = Input.SelectionLength;
        if (selLen > 0)
        {
            _real = _real.Remove(selStart, selLen);
            MaskAll();
            Input.CaretIndex = selStart;
        }
        else if (e.Key == Key.Back && selStart > 0)
        {
            _real = _real.Remove(selStart - 1, 1);
            MaskAll();
            Input.CaretIndex = selStart - 1;
        }
        else if (e.Key == Key.Delete && selStart < _real.Length)
        {
            _real = _real.Remove(selStart, 1);
            MaskAll();
            Input.CaretIndex = selStart;
        }
        e.Handled = true;
        Password = _real;
        _hideTimer.Stop();
    }

    private void OnPaste(object sender, DataObjectPastingEventArgs e)
    {
        if (e.DataObject.GetData(DataFormats.UnicodeText) is not string clip) { e.CancelCommand(); return; }
        e.CancelCommand();
        int selStart = Input.SelectionStart;
        int selLen   = Input.SelectionLength;
        _real = _real.Remove(selStart, selLen).Insert(selStart, clip);
        MaskAll();
        Input.CaretIndex = selStart + clip.Length;
        Password = _real;
        _hideTimer.Stop();
    }

    private void Input_LostFocus(object sender, RoutedEventArgs e)
    {
        _hideTimer.Stop();
        MaskAll();
    }
}

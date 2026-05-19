// Project-wide type aliases. We enabled <UseWindowsForms>true</UseWindowsForms>
// for the NotifyIcon (tray icon) -- but that pulls in System.Windows.Forms,
// whose Application/MessageBox/Button/ComboBox names collide with the
// equivalent System.Windows / System.Windows.Controls types we actually
// want everywhere else in this WPF app. Disambiguate centrally.

global using Application      = System.Windows.Application;
global using MessageBox       = System.Windows.MessageBox;
global using MessageBoxButton = System.Windows.MessageBoxButton;
global using MessageBoxImage  = System.Windows.MessageBoxImage;
global using Button           = System.Windows.Controls.Button;
global using ComboBox         = System.Windows.Controls.ComboBox;
global using UserControl      = System.Windows.Controls.UserControl;
global using KeyEventArgs     = System.Windows.Input.KeyEventArgs;
global using DataObject       = System.Windows.DataObject;
global using DataFormats      = System.Windows.DataFormats;

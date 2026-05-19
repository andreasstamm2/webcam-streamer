using System.Globalization;
using System.Windows.Data;

namespace WebcamStreamerUi;

// Returns the bound per-cam AvailableResolutions when non-empty; otherwise
// substitutes the static Resolutions.All list. Lets us drive the
// Resolution combobox from the supervisor's advertised-formats data
// without falling apart when that data hasn't arrived yet (initial
// startup race, or older supervisor build).
public sealed class ResolutionFallbackConverter : IValueConverter
{
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is IReadOnlyList<string> list && list.Count > 0) return list;
        return Resolutions.All;
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}

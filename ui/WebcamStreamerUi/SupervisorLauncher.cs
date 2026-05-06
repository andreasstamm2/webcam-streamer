using System.Diagnostics;
using System.IO;

namespace WebcamStreamerUi;

// Launches supervisor.exe and assigns it to a Job Object with KILL_ON_JOB_CLOSE.
// When this object is disposed (or the UI process dies), the supervisor and
// its children are torn down by the OS.
public sealed class SupervisorLauncher : IDisposable
{
    private IntPtr _jobHandle = IntPtr.Zero;
    private Process? _proc;
    private readonly string _exePath;

    public Process? Process => _proc;
    public string ExePath => _exePath;

    public event EventHandler<string>? StdoutLine;
    public event EventHandler<string>? StderrLine;
    public event EventHandler<int>? Exited;

    public SupervisorLauncher(string supervisorExePath)
    {
        _exePath = supervisorExePath;
    }

    /// <summary>Search up from the WPF exe directory for supervisor.exe.</summary>
    public static string? LocateSupervisorExe()
    {
        var here = AppContext.BaseDirectory;
        var dir = new DirectoryInfo(here);
        for (int i = 0; i < 8 && dir != null; i++)
        {
            var candidate = Path.Combine(dir.FullName, "supervisor", "build", "Release", "supervisor.exe");
            if (File.Exists(candidate)) return candidate;
            // Also accept supervisor.exe sitting next to the UI (deployed scenario).
            var sibling = Path.Combine(dir.FullName, "supervisor.exe");
            if (File.Exists(sibling)) return sibling;
            dir = dir.Parent;
        }
        return null;
    }

    public void Start()
    {
        if (_proc != null) throw new InvalidOperationException("Already started");
        if (!File.Exists(_exePath))
            throw new FileNotFoundException("supervisor.exe not found", _exePath);

        _jobHandle = Native.CreateJobObjectW(IntPtr.Zero, null);
        if (_jobHandle == IntPtr.Zero)
            throw new InvalidOperationException("CreateJobObject failed");

        var info = new Native.JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags =
            Native.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
            Native.JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
        uint sz = (uint)System.Runtime.InteropServices.Marshal.SizeOf<Native.JOBOBJECT_EXTENDED_LIMIT_INFORMATION>();
        if (!Native.SetInformationJobObject(_jobHandle, Native.JobObjectExtendedLimitInformation, ref info, sz))
            throw new InvalidOperationException("SetInformationJobObject failed");

        var psi = new ProcessStartInfo
        {
            FileName               = _exePath,
            UseShellExecute        = false,
            CreateNoWindow         = true,
            RedirectStandardOutput = true,
            RedirectStandardError  = true,
        };
        _proc = new Process { StartInfo = psi, EnableRaisingEvents = true };

        _proc.OutputDataReceived += (s, e) => { if (e.Data != null) StdoutLine?.Invoke(this, e.Data); };
        _proc.ErrorDataReceived  += (s, e) => { if (e.Data != null) StderrLine?.Invoke(this, e.Data); };
        _proc.Exited             += (s, e) => Exited?.Invoke(this, _proc?.ExitCode ?? -1);

        _proc.Start();
        if (!Native.AssignProcessToJobObject(_jobHandle, _proc.Handle))
            throw new InvalidOperationException("AssignProcessToJobObject failed");

        _proc.BeginOutputReadLine();
        _proc.BeginErrorReadLine();
    }

    public void Dispose()
    {
        // Closing the job handle triggers KILL_ON_JOB_CLOSE -> supervisor + children die.
        if (_jobHandle != IntPtr.Zero)
        {
            Native.CloseHandle(_jobHandle);
            _jobHandle = IntPtr.Zero;
        }
        try { _proc?.Dispose(); } catch { /* ignored */ }
        _proc = null;
    }
}

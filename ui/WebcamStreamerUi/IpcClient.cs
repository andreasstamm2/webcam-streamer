using System.Collections.Concurrent;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;

namespace WebcamStreamerUi;

// Single-task message pump for the supervisor's named-pipe IPC.
// Always finishes the in-flight read before starting another (StreamReader
// constraint). Routes responses to per-id TaskCompletionSources; events go
// to the EventReceived handler.
public sealed class IpcClient : IDisposable
{
    private readonly string _pipeName;
    private NamedPipeClientStream? _pipe;
    private StreamReader? _reader;
    private StreamWriter? _writer;
    private CancellationTokenSource? _cts;
    private Task? _pumpTask;
    private int _nextId;

    private readonly ConcurrentDictionary<int, TaskCompletionSource<JsonElement>> _waiters = new();

    public event EventHandler<EventArrived>? EventReceived;
    public event EventHandler<string>? Disconnected;
    public event EventHandler<string>? PumpError;

    public bool IsConnected => _pipe?.IsConnected ?? false;

    public IpcClient(string pipeName = "webcam-streamer-supervisor")
    {
        _pipeName = pipeName;
    }

    public async Task ConnectAsync(int timeoutMs = 5000, CancellationToken ct = default)
    {
        _pipe = new NamedPipeClientStream(".", _pipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
        await _pipe.ConnectAsync(timeoutMs, ct).ConfigureAwait(false);
        _reader = new StreamReader(_pipe, Encoding.UTF8, leaveOpen: true);
        _writer = new StreamWriter(_pipe, new UTF8Encoding(false), bufferSize: 4096, leaveOpen: true)
        {
            NewLine = "\n",
            AutoFlush = true
        };
        _cts = new CancellationTokenSource();
        _pumpTask = Task.Run(() => Pump(_cts.Token));
    }

    private async Task Pump(CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested && _reader != null)
            {
                string? line = await _reader.ReadLineAsync(ct).ConfigureAwait(false);
                if (line == null)
                {
                    Disconnected?.Invoke(this, "stream closed");
                    return;
                }
                JsonDocument doc;
                try { doc = JsonDocument.Parse(line); }
                catch (Exception ex)
                {
                    PumpError?.Invoke(this, $"bad json: {ex.Message} :: {line}");
                    continue;
                }
                using (doc)
                {
                    var root = doc.RootElement;
                    if (!root.TryGetProperty("type", out var t)) continue;
                    var type = t.GetString();

                    if (type == "resp")
                    {
                        int id = root.TryGetProperty("id", out var idEl) ? idEl.GetInt32() : 0;
                        if (_waiters.TryRemove(id, out var tcs))
                        {
                            // Clone detaches from the JsonDocument that's about
                            // to be disposed at the end of this scope.
                            tcs.TrySetResult(root.Clone());
                        }
                    }
                    else if (type == "event")
                    {
                        var name = root.TryGetProperty("name", out var n) ? (n.GetString() ?? "") : "";
                        var data = root.TryGetProperty("data", out var d) ? d.Clone() : default;
                        EventReceived?.Invoke(this, new EventArrived(name, data));
                    }
                }
            }
        }
        catch (OperationCanceledException) { /* expected on shutdown */ }
        catch (Exception ex)
        {
            PumpError?.Invoke(this, ex.Message);
            Disconnected?.Invoke(this, ex.Message);
        }
    }

    public async Task<JsonElement> CallAsync(string method, object? @params = null,
                                              int timeoutMs = 5000, CancellationToken ct = default)
    {
        if (_writer == null) throw new InvalidOperationException("not connected");
        int id = Interlocked.Increment(ref _nextId);
        var tcs = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        _waiters[id] = tcs;

        var req = new
        {
            type = "req",
            id,
            method,
            @params = @params ?? new object()
        };
        string json = JsonSerializer.Serialize(req);

        await _writer.WriteLineAsync(json).ConfigureAwait(false);

        using var reg = ct.Register(() => tcs.TrySetCanceled());
        using var timeoutCts = new CancellationTokenSource(timeoutMs);
        using var timeoutReg = timeoutCts.Token.Register(
            () => tcs.TrySetException(new TimeoutException($"IPC method '{method}' (id={id}) timed out")));
        try
        {
            return await tcs.Task.ConfigureAwait(false);
        }
        finally
        {
            _waiters.TryRemove(id, out _);
        }
    }

    public void Dispose()
    {
        try { _cts?.Cancel(); } catch { }
        try { _writer?.Dispose(); } catch { }
        try { _reader?.Dispose(); } catch { }
        try { _pipe?.Dispose(); } catch { }
        _writer = null;
        _reader = null;
        _pipe = null;
    }
}

public readonly record struct EventArrived(string Name, JsonElement Data);

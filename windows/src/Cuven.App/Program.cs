using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Cuven.App;

public static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(p =>
        {
            var ctx = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(ctx);
            _ = new App(args);
        });
        return App.ExitCode;
    }
}

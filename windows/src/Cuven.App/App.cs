using Cuven.App.Native;
using Cuven.App.UI;
using Cuven.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.XamlTypeInfo;

namespace Cuven.App;

/// <summary>
/// 不用 XAML 的 WinUI 3 程序：自己实现 IXamlMetadataProvider（交给 WinUI 自带的控件元数据），自己合并 XamlControlsResources
/// </summary>
public sealed partial class App : Application, IXamlMetadataProvider
{
    public static int ExitCode;
    public static string[] Args = Array.Empty<string>();
    public static MainWindow? Window;
    readonly XamlControlsXamlMetaDataProvider _meta = new();

    public App(string[] args)
    {
        Args = args;
        UnhandledException += (_, e) =>
        {
            Log("未处理的异常：" + e.Exception);
            e.Handled = true;
        };
        TaskScheduler.UnobservedTaskException += (_, e) => { Log("后台任务异常：" + e.Exception.InnerException?.Message); e.SetObserved(); };
    }

    public IXamlType GetXamlType(Type type) => _meta.GetXamlType(type);
    public IXamlType GetXamlType(string fullName) => _meta.GetXamlType(fullName);
    public XmlnsDefinition[] GetXmlnsDefinitions() => _meta.GetXmlnsDefinitions();

    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    static extern int MessageBoxW(IntPtr hwnd, string text, string caption, uint type);

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try { Launch(); }
        catch (Exception e)
        {
            // 起不来：别悄悄退出，告诉用户日志在哪
            Log("启动失败：" + e);
            MessageBoxW(IntPtr.Zero, $"Cuven 启动失败：{e.Message}\n\n日志：{Path.Combine(Storage.Root, "logs", "app.log")}", "Cuven", 0x10);
            ExitCode = 1;
            Exit();
        }
    }

    void Launch()
    {
        Resources.MergedDictionaries.Add(new XamlControlsResources());
        Settings.Protector = new Dpapi();
        Native.Native.Init();
        // 下载线程：EcoQoS（排到能效核，不抢播放）
        DownloadManager.WorkerThreadInit = () => { if (Native.Native.Ready && Settings.Shared.Efficiency) Native.Native.cv_thread_qos(Native.Native.QosEco); };
        Window = new MainWindow();
        Window.Activate();
        var st = Array.IndexOf(Args, "--selftest");
        if (st >= 0) _ = SelfTest.RunAsync(Window, st + 1 < Args.Length ? Args[st + 1] : Path.Combine(Storage.Root, "selftest"));
    }

    public static void Log(string s)
    {
        try
        {
            var dir = Storage.Dir("logs");
            File.AppendAllText(Path.Combine(dir, "app.log"), $"{DateTime.Now:HH:mm:ss.fff} {s}\n");
        }
        catch { }
    }
}

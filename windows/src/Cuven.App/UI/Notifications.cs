using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace Cuven.App.UI;

/// <summary>Windows 通知（请求添加：进入最终发行审批、已就绪、没能添加）</summary>
static class Notifications
{
    static bool _registered, _failed;

    public static void Show(string title, string body)
    {
        if (_failed) return;
        try
        {
            if (!_registered)
            {
                AppNotificationManager.Default.Register();
                _registered = true;
            }
            var n = new AppNotificationBuilder().AddText(title).AddText(body).BuildNotification();
            AppNotificationManager.Default.Show(n);
        }
        catch (Exception e)
        {
            _failed = true;
            App.Log("通知不可用：" + e.Message);
        }
    }
}

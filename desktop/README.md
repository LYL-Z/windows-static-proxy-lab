# Windows Proxy Doctor Desktop 1.3

中文名：网络代理医生。它以当前用户权限运行。故障分类与已合并的 Windows Proxy Doctor Skill 一致。

只读检查不写入系统代理。恢复按钮会把 `proxy_v4\rollback-v4.ps1` 复制到临时目录，强制 `V4_TEST_MODE=1`，执行后删除临时目录，并比较执行前后的当前用户代理指纹。它不重启 StarSky 或 Clash，也不提供账号安全结论。

运行窗口时，本地心跳每 20 秒采样。Windows 报告地址变化后，桌面在下一次空闲刷新时补读本地状态。上游 HTTPS 每 90 秒单独采样，手动检查也可触发。检查执行期间可能跳过周期采样。协议通道按需检查。通道分别显示采样时间、执行耗时、证据有效期和连续失败次数。轮询可能错过短于采样间隔的故障。

托盘提醒发出可观测的异常变化与复测结果，同类连续失败只提醒一次。事件文件保留最近 200 条摘要，退出窗口停止监测。StarSky 与 Clash 核心的进程和监听各自展示，默认代理 HTTPS 样本用于判断当次连通性。客户端自动重连与公网失败关闭保留各自的验收状态。

构建：

```powershell
dotnet test .\ProxyDoctor.sln -c Release
dotnet publish .\src\ProxyDoctor.Desktop\ProxyDoctor.Desktop.csproj -c Release -r win-x64 --self-contained true -o .\publish\win-x64
```

发布目录没有代码签名。使用说明见 `USER-GUIDE.md`。

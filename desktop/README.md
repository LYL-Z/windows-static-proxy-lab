# Windows Proxy Doctor Desktop 1.2

中文名：网络代理医生。它以当前用户权限运行。故障分类与已合并的 Windows Proxy Doctor Skill 一致。

只读检查不写入系统代理。恢复按钮会把 `proxy_v4\rollback-v4.ps1` 复制到临时目录，强制 `V4_TEST_MODE=1`，执行后删除临时目录，并比较执行前后的当前用户代理指纹。它不重启 StarSky 或 Clash，也不提供账号安全结论。

本地心跳每 20 秒采样。上游 HTTPS 每 90 秒单独采样。协议检查只在点击时运行。一条通道失败不会被另一条通道的旧结果显示成正常。

构建：

```powershell
dotnet test .\ProxyDoctor.sln -c Release
dotnet publish .\src\ProxyDoctor.Desktop\ProxyDoctor.Desktop.csproj -c Release -r win-x64 --self-contained true -o .\publish\win-x64
```

发布目录没有代码签名。使用说明见 `USER-GUIDE.md`。

# Windows Proxy Doctor Desktop 1.0

中文名：网络代理医生。它是一个以当前用户权限运行的 Windows 桌面程序，用来做只读的代理检查。故障分类与 Windows Proxy Doctor Skill 2.0.0 RC2 一致。

这一版不写入系统代理，不重启 StarSky 或 Clash，也不提供“保证不封号”或地区身份。

构建：

```powershell
dotnet test .\ProxyDoctor.sln -c Release
dotnet publish .\src\ProxyDoctor.Desktop\ProxyDoctor.Desktop.csproj -c Release -r win-x64 --self-contained true -o .\publish\win-x64
```

发布目录没有代码签名。使用说明见 `USER-GUIDE.md`。

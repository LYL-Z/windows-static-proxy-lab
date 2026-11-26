# USER-GUIDE-V5

## 现状
- 系统仍运行 V4 配置（独立 profile `v4-managed`），出口 `192.0.2.254`。
- 上游 #7012 未修：**重启后链式代理大概率失效**，需重新 `apply-v4.ps1`。

## 每次开机后
```powershell
powershell -ExecutionPolicy Bypass -File C:\CAB-Lab\proxy_v4\state-v4.ps1
# 若非 HEALTHY，且 StarSky 已"加速中"：
powershell -ExecutionPolicy Bypass -File C:\CAB-Lab\proxy_v4\apply-v4.ps1
```

## 换节点后的正确认知
StarSky 节点与出口 IP 每次可能不同。**只要最终出口等于所购静态 IP 即为正常**，
不要去比对节点名（美国1/美国5）。

## 不要做
- 不要指望"清理指纹/记录"能让账号安全；
- 不要把检测网站全绿当作通行证；
- 不要在未备份时手工改 `profiles.yaml`。
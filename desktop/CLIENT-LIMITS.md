# 客户端能力边界

`ClientLifecycle` 只根据调用方已经拿到的五个事实做分类：进程是否在、本地监听是否在、界面是否显示正在加速、这次上游是否成功、用户是否已经关闭。它不启动进程，不连接端口，不读取系统代理，也不调用正在运行的 StarSky、magicspeed、Clash Verge Rev 或 mihomo。

重启进程、重新打开加速开关、界面显示“正在加速”，都不是加速已经恢复。

## 状态

判断顺序是固定的。前面的条件成立时，后面的输入不再改变状态。

| 状态 | 条件 | 引导 |
| --- | --- | --- |
| `UserOff` | 用户已关闭 | 不要启动客户端，也不要重新打开加速 |
| `ProcessDown` | 进程不在 | 不要把启动进程写成加速已经恢复。报告有监听也不能单独成立 |
| `ProcessUpNoListener` | 进程在，监听没有确认 | 上游结果和界面文案都不能补上监听 |
| `ListenerUpstreamUnknown` | 进程和监听都在，上游还没有这次结果 | 本地监听不等于上游可用 |
| `ListenerUpstreamFailed` | 进程和监听都在，这次上游失败 | 上游失败不能靠重启写成已经恢复 |
| `ListenerUpstreamOk` | 进程、监听和这次上游都有结果 | 只说明这一次上游可达 |

界面是否显示加速只写进引导，不单独构成一个状态。

## 手动恢复清单

下面四项只由用户在自己的客户端里核对。`ClientLifecycle` 不执行它们。做完任何一项都不能写成加速已经恢复。

1. **进程不在。** 由用户自己打开已经安装的客户端。进程出现之后，还要另看本地监听和这次上游。启动进程不是已恢复的加速。
2. **进程在，本地监听没有确认。** 由用户在该客户端自己的界面里看加速开关和它显示的本地端口。界面上的“正在加速”，以及一次上游结果，都不能补上监听。
3. **监听在，这次上游失败。** 由用户在客户端里查看节点和日志，并自行决定是否重试。本地监听仍在，不能把这次上游失败写成已经恢复。文档里的 `POST /restart` 也不等于恢复。
4. **用户已经关闭客户端。** 保持关闭。不要启动进程，也不要重新打开加速。

没有找到已安装 StarSky 界面的公开重连 API。本次打开的 [https://www.skystars.top/](https://www.skystars.top/) 和 [https://skystars.top/](https://skystars.top/) 只有产品说明和 Windows 下载，没有开发者重连接口。[腾讯云聚通 API 概览](https://cloud.tencent.com/document/product/1385/126853) 写的是 `linkboost.exe` 和 `/api/v2/client/mp-speeder/restart`，不是 StarSky，也不是 `magicspeed`。[qdraw/starsky](https://github.com/qdraw/starsky) 是按图片元数据整理文件的程序，不是这个加速客户端。

Clash 的 mihomo external-controller 有公开文档，本构建不调用正在运行的控制器。[通用配置](https://wiki.metacubex.one/en/config/general/) 写了 `external-controller` 和 `secret`。[API](https://wiki.metacubex.one/en/api/) 写了 `GET /version` 和 `POST /restart`。[讨论 #6951](https://github.com/clash-verge-rev/clash-verge-rev/discussions/6951) 说明未打开 External Controller 时不暴露外部控制器，Windows 命名管道不提供文档。[讨论 #7417](https://github.com/clash-verge-rev/clash-verge-rev/discussions/7417) 说明打开后会在本机暴露 HTTP，该项目不打算被远程控制。[其他问题](https://clash-verge-rev.github.io/faq/other.html) 的设置路径是「Clash 设置 → 外部控制」，监听错误示例地址是 `127.0.0.1:9097`。

## StarSky / magicspeed

没有找到适用于 StarSky 界面进程或 `magicspeed` 核心的受支持重连 API，所以这个分类器不提供重连调用。

已查阅并排除的公开材料：

- 对 `StarSky.exe`、`magicspeed.exe`、`magicspeed` 加 `11119` 的公开检索，没有返回该客户端的开发者文档或重连接口。
- [腾讯云聚通 API 概览](https://cloud.tencent.com/document/product/1385/126853) 写的是 `linkboost.exe` 和 `/api/v2/client/mp-speeder/restart`。那不是 StarSky，也不是 `magicspeed`，不能拿来当作本客户端的重连 API。
- [金蝶星空 WebAPI 说明页](https://vip.kingdee.com/knowledge/407944297590364160) 打开后只有浏览器版本提示，没有返回可引用的接口正文。它也不是 StarSky / magicspeed 的重连文档。
- [qdraw/starsky](https://github.com/qdraw/starsky) 是图片管理程序，不是这里的加速客户端。

## Clash / mihomo

mihomo 有文档记载的本地 RESTful API。配置项是 `external-controller`，访问密钥是 `secret`。文档中的读取例子是 `GET /version`，重启内核的例子是 `POST /restart`。本构建不调用正在运行的控制器，也不把 `POST /restart` 当成加速已经恢复。

已核对的页面：

- [mihomo API](https://wiki.metacubex.one/en/api/)：外部控制器上的 REST 接口，包含 `GET /version`、`GET /configs` 和 `POST /restart`。
- [mihomo 通用配置](https://wiki.metacubex.one/en/config/general/)：`external-controller`、`external-controller-pipe` 和 `secret`。
- [Clash Verge Rev 讨论 #6951](https://github.com/clash-verge-rev/clash-verge-rev/discussions/6951)：维护者说明，未打开 External Controller 时不暴露外部控制器；Windows 命名管道和 Unix socket 的控制方式不提供文档。
- [Clash Verge Rev 讨论 #7417](https://github.com/clash-verge-rev/clash-verge-rev/discussions/7417)：打开外部控制器后，mihomo 会在本机暴露 HTTP；该项目不打算被远程控制。
- [Clash Verge Rev 文档，其他问题](https://clash-verge-rev.github.io/faq/other.html)：设置路径是「Clash 设置 → 外部控制」。文档里的监听错误示例地址是 `127.0.0.1:9097`。
- [Clash Verge Rev README](https://github.com/clash-verge-rev/clash-verge-rev/blob/dev/README.md)：说明内置 mihomo，并指向上述文档站。README 没有 StarSky 重连接口。

命名管道只出现在维护者明确拒绝为其写文档的讨论里。本分类器不把未文档化的管道当成可调用的重连接口。

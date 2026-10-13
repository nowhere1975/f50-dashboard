# f50-dashboard

macOS 菜单栏流量看板，适用于中兴 F50 Pro。版本：0.2.0。

显示实时速率、按网络累计的本机用量、路由器本周期用量、信号和接入设备。设置界面可修改额度、刷新间隔和当前网络名称；菜单提供近七天本机用量。

## 流量口径

- **本机用量**：当前网卡的字节增量，仅覆盖 App 运行且采样有效的时段。
- **路由器本周期用量**：F50 管理接口的累计值，包含全部接入设备，尚未证明始终等于运营商账单。
- **估算剩余**：配置额度减去路由器读数，实际套餐余量以运营商查询结果为准。
- 所有容量使用十进制单位：1 GB = 10⁹ B。
- 日用量按本机时区归集；跨午夜的一个短窗口记入采样结束日。未记录的日期显示「—」，不会补成零。
- 切网、换网卡、计数重置、读取失败、休眠或过长采样间隔后重建基线，不回填不确定窗口。

## 构建与安装

需要 Xcode Command Line Tools 和 Python 3，不下载第三方依赖。

~~~bash
./build.sh test       # 离线回归检查
./build.sh            # 构建当前机器架构，显式指定 macOS 12 部署目标
./build.sh install    # 备份旧 App、配置和累计，安装并启动
./build.sh check      # 检查本机采样和 F50 只读接口
./build.sh uninstall  # 移除开机自启，将 App 留存在数据目录
~~~

从 0.1 升级前，在旧版菜单点击一次「退出」，确保内存累计写入 `state.json`。旧版可能自动拉起，安装程序会停止旧服务后替换 App。升级备份位于数据目录的 `upgrades/`。

0.2 正常退出后不自动重启，异常退出由 LaunchAgent 尝试恢复。文件锁阻止多个 App 实例同时写入。

构建目标为 macOS 12+，实际验证环境为 Apple Silicon、macOS 27、Swift 6.4。旧系统与 Intel 运行仍需实机验证。本机 CLT 缺少 Intel 兼容库，Intel 交叉构建未完成。

## 配置与设置

菜单选择「设置…」，保存后立即生效；也可编辑：

~~~text
~/Library/Application Support/F50Dashboard/config.json
~~~

~~~json
{
  "quotaGB": 100,
  "routerGateway": "auto",
  "interface": "auto",
  "localPollSec": 2,
  "routerPollSec": 30,
  "showRateInTitle": true,
  "networkNames": {},
  "enableQuotaAlerts": false
}
~~~

| 配置 | 含义与范围 |
|---|---|
| `quotaGB` | 用于估算的额度，大于 0，且不超过 1000000 GB |
| `routerGateway` | `auto` 使用当前 IPv4 网关；可指定 IP 或主机名，可带端口 |
| `interface` | `auto` 使用系统主接口；可指定网卡，如 `en0` |
| `localPollSec` | 本机采样间隔，1–60 秒 |
| `routerPollSec` | 路由器采样间隔，5–3600 秒 |
| `showRateInTitle` | 菜单栏显示速率或当前网络累计下载量 |
| `networkNames` | 网络标识到显示名称的映射，可在设置界面修改 |
| `enableQuotaAlerts` | 默认关闭；在设置界面开启后请求系统通知权限 |

外部改配置后，下次打开菜单时重新加载并更新定时器。格式、类型或范围错误时，保留原文件与当前有效配置并提示，不覆盖为默认文件。配置加载错误未解决时暂停额度估算，避免默认额度被误当成真实套餐。

提醒按 80%、90%、100% 触发，同一计数周期不重复；计数下降后重置提醒记录。提醒依据路由器读数和配置额度，不代表运营商通知。

## 网络识别与保存

通过 SystemConfiguration 读取主网卡、网关、DNS 和可用的网关 MAC，不读取 SSID、不申请位置权限。优先按 MAC 分桶；MAC 不可用时退回网卡、网关和 DNS，相同配置仍可能合并。

F50 响应必须绑定当前网络并由型号字段确认。切网清空快照，迟到的响应被丢弃。零用量有效；计数缺失、无效或只有单边计数时不估算余量。

接口累计采用本机已交叉验证的 `netstat -ibn` 来源，在串行后台线程读取，不阻塞菜单；进程超过 2 秒时终止并视为失败。本机系统原生计数在第三方进程中与 `netstat` 不一致，因此未采用该读数。

每 30 秒原子保存累计，保留上一份有效 `state.backup.json`。加载失败时先留存损坏文件，再尝试恢复备份并提示。异常退出最多丢失上次成功保存后的有效采样；写入失败时显示提示。

旧版 `f50` 桶保留为「F50 Pro（旧版累计）」，新版按实际网络标识记录。旧累计不强制归入新网络，也不反推每日历史。

## 诊断与数据

~~~bash
~/Applications/F50Dashboard.app/Contents/MacOS/F50Dashboard --check
~~~

检查配置、网络、计数与路由器接口；未连接 F50 或数据无效时返回非零，不表示 App 无法启动。

~~~text
~/Library/Application Support/F50Dashboard/
  config.json
  state.json
  state.backup.json
  runtime.json
  app.stdout.log
  app.stderr.log
  upgrades/
~~~

`runtime.json` 是本地运行快照，包含版本、进程、网络标识、刷新间隔和保存状态。诊断输出可能包含本地网络标识，分享前可按需要遮盖。

## 可选 CSV 脚本

~~~bash
tools/router-traffic.sh status
tools/router-traffic.sh watch
tools/router-traffic.sh report
tools/ssid-traffic.sh sample
tools/ssid-traffic.sh report
~~~

- 路由器脚本只读，不登录、不保存密码或 Cookie。每分钟调用 `watch` 时默认每五分钟采样；检查不更新实际采样时间。
- `ssid-traffic.sh` 保留历史命名，实际按网关 MAC/IP 区分，不读取 SSID。切网和长间隔重建基线。
- 默认输出到 `~/inbox/`。可用 `RT_CSV`、`RT_STATE`、`RT_GATEWAY`、`RT_SAMPLE_SEC` 或 `SSID_TRAFFIC_CSV`、`SSID_TRAFFIC_STATE` 覆盖路径和采样参数。
- 响应文本通过 Python `csv` 模块写入，不作为 shell 代码执行。
- 报告在断线、恢复和计数下降后重建基线。路由器覆盖全部设备，本机读数只覆盖当前接口。

## 文档与许可

- [接口协议](docs/PROTOCOL.md)：单设备、单固件的接口整理。
- [历史踩坑与新版说明](docs/PITFALLS.md)。
- [当前实现与验证范围](docs/REVIEW.md)。
- [0.2.0 更新记录](docs/CHANGELOG.md)。

非官方第三方工具，与中兴通讯无关联。实际设备验证仅覆盖 `F50ProV1.0.0B27` / `MU3356V1.0.0B27`，其他固件未验证。App 与当前脚本只读状态，不修改路由器配置。按现状提供，许可为 [MIT](LICENSE)。

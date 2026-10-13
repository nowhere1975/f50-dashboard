# 中兴 F50 Pro 管理接口协议（逆向整理）

> **本文档的定位**：把 f50-dashboard 依赖的设备接口整理成可复现的规范，
> 让其他平台（Windows / Android / Linux）的开发者也能用。
>
> **验证环境**：仅一台设备、一个固件版本。
> `wa_inner_version = F50ProV1.0.0B27`，`cr_version = MU3356V1.0.0B27`。
> 未验证的推断已明确标注。

---

## 1. 设备标识

| 项目 | 值 |
|---|---|
| 产品名 | 中兴 F50 Pro（5G 随身 Wi-Fi / CPE） |
| 出厂管理地址 | `192.168.0.1` |
| 网页配置里的 `DEVICE_MODEL` | `U30Air` ← **这是通用壳，不代表型号** |
| `PRODUCT_TYPE` | `UFI` |
| `DEVICE` | `ufi/mu3351` |
| 真实型号（来自固件版本串） | `F50ProV1.0.0B27` |

**判定方法**：固件版本串比网页配置里的 `DEVICE_MODEL` 可靠。

---

## 2. 端点

全部走普通 HTTP，无 HTTPS。

| 端点 | 用途 |
|---|---|
| `GET  /goform/goform_get_cmd_process` | 读取 |
| `POST /goform/goform_set_cmd_process` | 写入 |
| `/mmc2/` | 文件存储 |

### 读取请求格式

```
GET /goform/goform_get_cmd_process?isTest=false&cmd=<逗号分隔的命令名>&multi_data=1
Referer: http://192.168.0.1/index.html
```

- `multi_data=1` → 返回 JSON 对象
- `multi_data=0` → 返回逗号分隔的纯文本（未深入验证）
- **`Referer` 头是必需的**（缺失会被拒）

### 响应示例

```json
{
  "wan_ipaddr": "10.134.166.50",
  "Z5g_rsrp": "-82",
  "monthly_tx_bytes": 384301135,
  "monthly_rx_bytes": 1357457950,
  "flux_monthly_tx_bytes": 384301135,
  "flux_monthly_rx_bytes": 1357457950,
  "network_signalbar": 5,
  "network_type": "5G",
  "station_list": [
    {"mac_addr": "ca:e6:09:9d:05:22", "hostname": "--", "ip_addr": "192.168.0.125"}
  ]
}
```

> ⚠️ **值的类型不统一**：`Z5g_rsrp` 是字符串 `"-82"`，`network_signalbar` 是数字 `5`，
> `monthly_time` 是数字。解析时两种都要处理 —— 这是最容易踩的坑之一。

---

## 3. ⚠️ 读命令不需要认证

**这是最重要的发现，也是本工具不需要任何凭据的原因。**

实测（不带任何 Cookie）：

| 命令 | 结果 |
|---|---|
| `flux_monthly_tx_bytes,flux_monthly_rx_bytes` | ✅ 返回真实流量 |
| `station_list` | ✅ 返回接入设备的 MAC 与 IP |
| `Z5g_rsrp` | ✅ 返回信号强度 |
| `wan_ipaddr,network_type` | ✅ 返回公网 IP 与网络类型 |

**安全含义**：任何连上这台 Wi-Fi 的设备都能读到上述信息（包括接入设备的 MAC/IP 列表）。
随身 Wi-Fi 场景下风险有限，但值得知悉。

**写命令需要会话**：未登录时 `POST goformId=REBOOT` 返回 `{}` 且不生效
（已通过 `realtime_time` 连续性确认设备未被重启）。

---

## 4. 登录流程（写操作才需要）

网页端不是明文传密码，而是「服务器下发随机数 + 双重 SHA256」。走查 `js/service.js` 得到：

```javascript
// 关键片段（简化）
LD = GET(nv:"LD").LD
password = WEB_ATTR_IF_SUPPORT_SHA256 == 2
         ? SHA256( SHA256(明文密码) + LD )        // ← 本机固件走这一支
         : WEB_ATTR_IF_SUPPORT_SHA256 == 1
           ? SHA256( Base64(明文密码) )
           : Base64(明文密码)
```

本机 `WEB_ATTR_IF_SUPPORT_SHA256 == 2`（配置值在 `js/config/config.js`）。

### 完整步骤

```bash
GW=192.168.0.1

# ① 取随机数
LD=$(curl -s "http://$GW/goform/goform_get_cmd_process?isTest=false&cmd=LD&multi_data=1" \
     | python3 -c "import sys,json;print(json.load(sys.stdin)['LD'])")

# ② 算密码（注意：设备端 SHA256 返回【大写十六进制】）
h() { printf '%s' "$1" | shasum -a 256 | awk '{print toupper($1)}'; }
PW=$(h "$(h '你的密码')$LD")

# ③ 登录
curl -s -c cookies.txt -H "Referer: http://$GW/index.html" \
     -X POST "http://$GW/goform/goform_set_cmd_process" \
     --data "isTest=false&goformId=LOGIN&password=$PW"
# → {"result":0}   0 表示成功

# ④ 验证
curl -s -b cookies.txt "http://$GW/goform/goform_get_cmd_process?isTest=false&cmd=loginfo&multi_data=1"
# → {"loginfo":"ok"}
```

### 实现要点

1. **SHA256 输出是大写十六进制**，不是 Base64。用 `shasum` 记得 `toupper`。
   若自行实现，建议直接复用设备 `js/util.js` 里的 `SHA256` 函数以确保一致。
2. **`LD` 每次请求都可能变**，必须在登录前重新取，不能缓存。
3. **失败 5 次会锁定 300 秒**（`MAX_LOGIN_COUNT: 5`，`login_lock_time: 300`）。
   调试时务必先用离线方式验证算法，别拿真实设备试错。
4. 成功后会下发会话 Cookie，后续写操作带上即可。

---

## 5. 字段参考（已实测）

| 字段 | 类型 | 含义 |
|---|---|---|
| `flux_monthly_tx_bytes` | number | 本计费周期上传字节 |
| `flux_monthly_rx_bytes` | number | 本计费周期下载字节 |
| `monthly_tx_bytes` / `monthly_rx_bytes` | number | 同上（本机实测与 flux_ 完全一致） |
| `monthly_time` / `flux_monthly_time` | number | 周期相关秒数，含义未确认 |
| `Z5g_rsrp` | string | 5G 参考信号接收功率，单位 dBm（如 `"-82"`） |
| `network_type` | string | `"5G"` / `"4G"` 等 |
| `network_signalbar` | number | 信号格数，0–5 |
| `network_rssi` | number | 另一套信号指标，量纲未确认 |
| `wan_ipaddr` | string | WAN 口地址（多为运营商级 NAT 私网地址） |
| `station_list` | array | 接入设备 `[{mac_addr, hostname, ip_addr}]` |
| `wan_active_band` | string | 当前频段（本机为空） |
| `wa_inner_version` | string | 固件版本，含真实型号 |
| `cr_version` | string | 硬件/软件版本 |
| `LD` | string | 登录用随机数（UUID 形式） |
| `loginfo` | string | `"ok"` 表示已登录 |

### 未取到值的字段（本机固件返回空串）

`Z5g_rsrq`、`Z5g_rssi`、`network_sinr`、`network_cell_id`、`bandwidth`、
`nr5g_action_band`、`wan_active_band`、`flux_total_*`、`realtime_*`、`data_volume_*`

> 推测：这些字段需要设备处于特定状态，或属于其他型号/固件。
> 若你的设备能取到值，欢迎提 issue 补充。

---

## 6. ⚠️ 单位：运营商用十进制，别用二进制

```
1,790,727,216 字节
  ÷ 10⁹  = 1.79 GB   ← 运营商后台显示的口径
  ÷ 2³⁰  = 1.67 GiB  ← 若标签写"GB"就是错的
```

**用二进制会在 100 GB 配额上产生约 7.4% 的误差（累计 7 GB）**，
足以让用户在月中被限速。本工具一律使用十进制。

---

## 7. 固件差异风险

本协议在**单一固件**（`MU3356V1.0.0B27`）上验证。其他版本可能有：

| 风险 | 应对 |
|---|---|
| 字段名不同 | f50-dashboard 为每个指标准备多个候选字段名，逐个尝试 |
| 值类型不同 | 解析时同时接受字符串与数字 |
| 读命令需要认证 | 未遇到；若遇到需实现第 4 节登录流程 |
| 管理地址非 192.168.0.1 | 配置项 `routerGateway` 可覆盖 |
| 登录算法分支不同 | `WEB_ATTR_IF_SUPPORT_SHA256` 可能为 0/1/2，第 4 节三种都列出 |

**如果你在别的固件上跑通（或跑不通），请提 issue 附上
`--check` 的输出** —— 这是完善兼容性的唯一途径。

---

## 8. 命令空间（部分）

从 `js/service.js` 提取的 `goformId` 共 100+ 个，读取类包括：

```
mc_modem_main_state, ppp_status, network_type, network_signalbar,
flux_monthly_tx_bytes, flux_monthly_rx_bytes, station_list,
wan_ipaddr, wan_active_band, neighbor_cell_info, ...
```

写入类（需登录）包括：

```
APN_PROC, CHANGE_PASSWORD, DMZ_SETTING, ADD_PORT_MAP, DEL_PORT_MAP,
FW_FORWARD_ADD, FW_FORWARD_DEL, LTE_BAND_LOCK, DHCP_SETTING,
WIFI_* , CONNECT_NETWORK, DISCONNECT_NETWORK, REBOOT, ...
```

**本工具只使用读取类命令，不调用任何写入命令。**

---

## 9. 网页端资源（便于进一步研究）

| 文件 | 内容 |
|---|---|
| `/js/main.js` | require.js 入口与模块配置 |
| `/js/config/config.js` | 设备能力开关（型号、登录方式、功能支持矩阵） |
| `/js/service.js` | 全部 API 封装（含登录与所有 goformId） |
| `/js/util.js` | 工具函数，含 `SHA256`、`Base64` |

---

## 免责声明

本文档为**互操作性目的**的接口整理，基于对自有设备的正常使用与公开可访问的网页资源。
不包含任何绕过授权的技术。所有读操作均无需凭据；登录流程仅用于说明写操作的认证机制。

「中兴」「ZTE」为其权利人商标，本项目与之无关联。

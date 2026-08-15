# Woow H618 pi-agent 範本機

[![Podman](https://img.shields.io/badge/Podman-4.3.1%20rootless-892CA0)](https://podman.io)
[![Debian](https://img.shields.io/badge/Debian-bookworm%20%2F%20Armbian-red)](https://www.armbian.com)
[![Tailscale](https://img.shields.io/badge/Tailscale-1.100%2B-black?logo=tailscale)](https://tailscale.com)
[![Cloudflare Tunnel](https://img.shields.io/badge/Cloudflare-Tunnel-F38020?logo=cloudflare)](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[English](README.md) · **繁體中文**

一鍵部署 Woow H618（Vontar / Allwinner H618, arm64）**範本機**的完整倉庫。這台機器上跑：

- **pi-web** — pi coding agent 網頁介面，前面有 nginx auth shim，rootless podman 運行
- **cf-tunnel-webgui** — 管理 Cloudflare Tunnel 的瀏覽器介面
- **tailscale** — VPN + 網頁管理 UI，LAN 跟 tailnet 都能連
- **PAM 密碼綁定** — pi-web 的登入跟 Armbian 的 `sudo passwd root` 綁死，兩者無法各改各的

一台燒好 Armbian OS 26.08 bookworm 的空白 H618，從 `git clone` 到能用大約 15 分鐘。所有步驟都 idempotent，失敗後直接重跑 `install.sh` 是安全的。

---

## 部署完你會拿到什麼

| 服務 | URL | 登入 |
|---|---|---|
| Tailscale web UI | `http://<機器 IP>:8088` | 按 "Log in" → 到 login.tailscale.com 完成 OAuth |
| pi coding agent | `http://<機器 IP>:30142` | `root` / `1234`（跟 Armbian sudo 同一組） |
| Cloudflare Tunnel GUI | `http://<機器 IP>:8888` | 第一次進入的精靈；貼你的 CF tunnel token |
| SSH | `ssh root@<機器 IP>` 或 `ssh pi@<機器 IP>` | `root/1234`；`pi` 是 NOPASSWD sudo |

**密碼機制（唯一不直覺的部分）：**

- pi-web 的 HTTP Basic auth 帳號固定 `root`。密碼 hash 來自 `/etc/shadow`。
- 要改 pi-web 密碼？跑 **`sudo passwd root`**。PAM hook 會把新的 hash 原子寫入 pi-web 的 htpasswd — 不用重啟、不用進 pi-web CLI。
- pi-agent 自帶的 `scripts/set-password.sh` 在這台機器上被禁用了。**沒有第二條路徑**可以改 pi-web 密碼。

---

## 前置條件

**目標硬體**：任何跑得動 Armbian bookworm 的 arm64 SBC。在 Vontar H618（Allwinner H618，4×A53，4GB RAM，eMMC）上驗證過。

**目標 OS**：Armbian OS 26.08.0 bookworm（Debian 12）。Bookworm 內建的 **Podman 4.3.1**，本 repo 就是給它設計的。Debian bookworm 本體、Ubuntu 24.04+ 也能跑，但只有 26.08 Armbian 做過端到端驗證。

**假設起始狀態**：Armbian first boot 完成、root 至少 SSH 進去過一次（`/etc/shadow` 有 root 的 hash、`/root` 存在）。

**`install.sh` 會幫你 apt 裝的東西**：

- `podman`、`uidmap`、`slirp4netns`、`fuse-overlayfs`
- `tailscale`（從 `pkgs.tailscale.com/stable/debian/bookworm`）
- `curl`、`jq`、`ca-certificates`、`gnupg`、`git`、`openssl`、`libpam-modules`

**跑之前你自己要準備**：

- 網路能連到 `pkgs.tailscale.com`、`github.com`、`docker.io`、`ghcr.io`
- 空間 ~5 GB（podman images：~1 GB pi-agent + ~250 MB cf-webui + ~50 MB nginx + build cache）
- 一組 Cloudflare Tunnel token（**只有你要 CF 公開網址才需要**；LAN + tailnet 路徑不需要）
- 一個 tailscale 帳號（免費版就夠）

---

## 安裝

```bash
# 在 H618 上，用任何可以 sudo 的帳號：
git clone https://github.com/WOOWTECH/Woow_H618_pi_agent_reference_machine.git
cd Woow_H618_pi_agent_reference_machine
sudo ./install.sh
```

就這樣。script 內部分三個 phase，自動串起來：

| Phase | 執行身份 | 時間 | 做什麼 |
|---|---|---|---|
| 1 | root | ~2 分 | apt 安裝、建 pi user、subuid/subgid、linger、sudoers、啟動 `tailscaled` |
| 2 | pi | ~10 分 | clone 兩個 sibling repo、build 兩個 podman image、裝 user unit、啟動服務 |
| 3 | root | ~30 秒 | tailscale-web unit、PAM sync hook、禁用 pi-agent 自帶的 set-password.sh、seed htpasswd、若 root 密碼空的就設 `1234` |

Phase 2 build image 失敗可以只重跑 phase 2：

```bash
sudo ./install.sh --phase 2
```

如果要跳過 tailscale（例如已經有其他 VPN）：

```bash
sudo ./install.sh --skip-tailscale
```

---

## 裝完之後：三件事在瀏覽器完成

### 1. Tailscale 登入

打開 **`http://<機器 IP>:8088`**（LAN 上任何一台筆電）。tailscale web UI 會顯示 "Not logged in"，有個 **Log in** 按鈕。按下去 → tailscale daemon 會在新分頁開 `https://login.tailscale.com/a/<id>`。用 Google / GitHub / Microsoft 完成 OAuth。網頁自動刷新變成已登入狀態。

這一步完成後：
- 機器有 tailnet 名稱（`armbian.tail-xxxx.ts.net`）跟 `100.x.x.x` IP
- 任何 tailnet peer 都能 SSH：`ssh root@armbian.tail-xxxx.ts.net`

### 2. pi-web 驗證

打開 **`http://<機器 IP>:30142`**。HTTP Basic 提示：**`root`** / **`1234`**。你會看到 pi coding agent UI。如果你要改密碼，**不要在 pi-web 裡改**，去改 Armbian 的：

```bash
sudo passwd root
# 輸入新密碼、確認
# → PAM hook 觸發、htpasswd 更新、下一個請求就用新密碼
```

確認同步有觸發：

```bash
sudo journalctl -t pi-web-passwd-sync -n 5
# pi-web-passwd-sync: htpasswd for 'root' updated from root's shadow hash
```

### 3. Cloudflare Tunnel

打開 **`http://<機器 IP>:8888`**。第一次精靈會問：
- **Tunnel token** — 從 Cloudflare Zero Trust → Networks → Tunnels → 選你的 tunnel → "Install and run a connector"，複製 token 貼進來。GUI 會存成 podman secret（不會用明文寫在硬碟）。
- **Public hostname** — 你要 route 到這台的 FQDN，例如 `pi-armbian-test.woowtech.io`。
- **Backend service** — `http://192.168.2.149:8088` 對 tailscale web、`http://192.168.2.149:30142` 對 pi-agent。也可以設 catch-all 導到 nginx-proxy-manager 做分派。

Tunnel 起來後，任何地方 `curl https://<你的 hostname>` 都能連到這台。

---

## 架構圖

```
                    ┌────────────────────────────────────────────────────────────┐
                    │                     H618 範本機                             │
                    │                                                            │
   瀏覽器 ─LAN──►   │  :8088  tailscale-web ────► tailscaled ────► login.ts.net │
   瀏覽器 ─LAN──►   │  :30142 pi-agent-nginx ──► pi-web (podman rootless)       │
   瀏覽器 ─LAN──►   │  :8888  cf-tunnel-webgui ─► cloudflared (child proc)      │
                    │                                                            │
   internet ─CF──►  │  :8088 or :30142 (透過 cloudflared，如果有設)              │
   tailnet ────►    │  :8088 or :30142 (走 tailscale0)                           │
                    └────────────────────────────────────────────────────────────┘

   passwd root ─► PAM (common-password)
                  └► pam_exec ─► /usr/local/sbin/pi-web-passwd-sync.sh
                                  └► 讀 /etc/shadow → 寫 ~pi/.config/pi-agent/htpasswd
```

看 **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** 有分層詳解、**[docs/SECURITY.md](docs/SECURITY.md)** 有 threat model。

---

## Repo 結構

```
Woow_H618_pi_agent_reference_machine/
├── install.sh                        # 主入口（呼叫 phase 1/2/3）
├── uninstall.sh                      # 回滾（部分 / 完全）
├── scripts/
│   ├── phase1-system-prep.sh         # root：apt、users、linger、sudoers、tailscaled
│   ├── phase2-user-services.sh       # pi：clone、build image、裝 user unit
│   ├── phase3-integration.sh         # root：tailscale-web、PAM hook、htpasswd seed
│   └── pi-web-passwd-sync.sh         # PAM hook target：shadow → htpasswd
├── systemd/
│   └── tailscale-web.service         # tailscale web UI 的 system unit
├── podman/
│   ├── pi-web.service                # pi user systemd unit（podman run 包裝）
│   ├── pi-agent-nginx.service        # pi user systemd unit
│   └── cf-tunnel-webgui.service      # pi user systemd unit
├── etc/
│   ├── tailscale-woow.env            # WEB_LISTEN=0.0.0.0:8088
│   ├── sudoers.d/pi-nopasswd         # pi ALL=(ALL) NOPASSWD:ALL
│   └── pam.d/                        # (預留給未來的 PAM snippet)
├── docs/
│   ├── ARCHITECTURE.md
│   ├── SECURITY.md
│   └── TROUBLESHOOTING.md
├── LICENSE
└── README.md / README_zh-TW.md
```

---

## 驗證

裝完後正常機器：

```bash
# system service
$ systemctl is-active tailscaled tailscale-web
active
active

# user service（用 pi）
$ systemctl --user is-active pi-web pi-agent-nginx cf-tunnel-webgui
active
active
active

# port
$ ss -tlnp 2>/dev/null | grep -E ':(8088|30142|8888)\s'
LISTEN 0 4096 *:8088   *:* users:(("tailscale",...))
LISTEN 0 4096 *:30142  *:*
LISTEN 0 4096 *:8888   *:*

# pi-web 可連 + auth 生效
$ curl -sSo /dev/null -w '%{http_code}\n' http://localhost:30142
401
$ curl -sSo /dev/null -w '%{http_code}\n' -u root:1234 http://localhost:30142
200

# 密碼同步有觸發
$ sudo passwd root                  # 改成別的
$ sudo journalctl -t pi-web-passwd-sync -n 1 --no-pager
... pi-web-passwd-sync: htpasswd for 'root' updated from root's shadow hash
```

---

## 反安裝

```bash
# 停服務、砍 volume：
sudo ./uninstall.sh

# 或保留 pi-web session 跟 cf-tunnel 狀態：
sudo ./uninstall.sh --keep-data

# 或只砍 PAM hook（重新啟用獨立的 pi-web 密碼路徑）：
sudo ./uninstall.sh --pam-only

# 或連 clone 的 source repo 都砍掉：
sudo ./uninstall.sh --purge
```

`uninstall.sh` **不會動**的東西：tailscaled（system tailscale）、linger、subuid/subgid、`/etc/os-release`。要徹底清 tailscale：

```bash
sudo apt purge tailscale && sudo rm -rf /var/lib/tailscale
```

---

## 值得看的設計決策

- **為什麼 pi-web 密碼綁 Armbian root**：範本機只有一個 operator。兩個獨立密碼保證一個月內就會漂移。詳見 [docs/SECURITY.md](docs/SECURITY.md)，包含為什麼**沒**用 nginx-pam auth（rootless container 讀不到 `/etc/shadow`）、為什麼 PAM `pam_exec` 比 inotify watcher 更穩。
- **為什麼手寫 `podman run` systemd unit 而不是 Quadlet**：bookworm 只有 Podman 4.3.1；Quadlet 要 4.4。這個 repo 追的是我們要部署的 OS，不是我們希望存在的 OS。等 bookworm-backports 或 trixie 成主流，`podman/` 目錄改成 Quadlet `*.container` file 就好，其他不用動。
- **為什麼 tailscale-web 綁 `0.0.0.0:8088`**：LAN 上的瀏覽器要能連、cloudflared（在 LAN 介面上）要能 proxy、tailnet peer 在 `100.x.x.x:8088` 也要能連。tailscale 官方預設 `100.x:5252`（tailnet only）對我們的拓樸是錯的。
- **為什麼移除 `tailscale-guard`**：前一版有個 systemd timer 每 30 秒把 tailscale-web 從 `0.0.0.0` 偷偷改綁回 `100.x`「為了安全」。結果 Cloudflare Tunnel（走 LAN IP）壞掉。這個 guard 是自製 hack — tailscale 本身沒有這種東西。這裡拿掉；要限制存取請在公開 URL 前面加 CF Access，不要拿 tailscale-web 綁定動刀。

---

## 授權

MIT。看 [LICENSE](LICENSE)。

## 姊妹 repo

- [`WOOWTECH/Woow_podman_pi_agent_package`](https://github.com/WOOWTECH/Woow_podman_pi_agent_package) — pi coding agent、rootless podman 打包
- [`WOOWTECH/Woow_cloudflare_tunnel_webgui`](https://github.com/WOOWTECH/Woow_cloudflare_tunnel_webgui) — Cloudflare Tunnel 網頁 GUI
- [`WOOWTECH/Woow_ha_vpn_headscale_package`](https://github.com/WOOWTECH/Woow_ha_vpn_headscale_package) — headscale 版本（沒用在這裡，但本 repo 的 tailscale-web 模式是從這裡演化來的）

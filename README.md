# snapback

Debian 服务器整机备份到 Google Drive 的一键脚本。底层是 [restic](https://restic.net)(增量、去重、加密)加 [rclone](https://rclone.org)(连接 Google Drive)。

> ⚠️ 脚本只做过语法检查,还没在真实的 Debian 服务器上跑过。正式依赖它之前,请先完整测一次备份和恢复。

## 功能

- 每天定时备份整机,用 systemd timer 实现,默认凌晨 3 点
- 备份前自动导出 MySQL/MariaDB 和 PostgreSQL
- 默认保留 7 天、4 周、6 个月的快照,自动清理旧快照
- 交互式恢复,三种模式:恢复到单独目录、把某个路径恢复到原位置、整机恢复
- Google Drive 只用 `drive.file` 权限,只能访问自己创建的备份文件
- 可选安装 [Backrest](https://github.com/garethgeorge/backrest) 网页面板,只监听本机,通过 SSH 隧道访问

## 安装

```bash
curl -fsSLO https://raw.githubusercontent.com/tod-zhang/snapback/main/snapback.sh
sudo bash snapback.sh install
```

安装过程会:

1. 安装 restic、rclone、rsync。
2. 授权 Google Drive。需要在一台有浏览器的电脑上运行脚本给出的 `rclone authorize ...` 命令,再把输出的 token 粘回服务器。可以填自己在 Google Cloud 建的 OAuth 客户端(推荐),也可以留空,用 rclone 自带的公共客户端。
3. 新建备份仓库,或连接已有仓库(在新机器上恢复时用)。
4. 启用每日定时备份。

**安装结束时显示的仓库密码一定要另外保存。** 丢了密码,备份就无法解密。

## 使用

| 命令 | 作用 |
|---|---|
| `snapback backup` | 立即备份 |
| `snapback list` | 列出快照 |
| `snapback restore` | 交互式恢复 |
| `snapback status` | 查看上次备份结果、下次运行时间、仓库大小 |
| `snapback panel` | 安装 Backrest 网页面板 |
| `snapback uninstall` | 移除定时任务和命令,保留配置和密码 |

配置文件在 `/etc/snapback/config`,可以修改备份路径、排除规则、保留策略和备份时间。

## 在新机器上整机恢复

1. 装一台和原机器**同版本**的 Debian。
2. 运行 `sudo bash snapback.sh install`,选「连接已有仓库」,填原来的仓库目录名和密码。
3. 运行 `snapback restore`,选「整机恢复」。新机器自己的磁盘挂载、网络配置和引导程序会保留。
4. 重启。

## 隐私

见 [privacy.html](https://tod-zhang.github.io/snapback/privacy.html)。

# config/ —— 配置模板目录

## 统一口径（2026-10-05 起）

1. **本目录只放「可入库的模板」**：命名一律 `*.default.json`，**绝不含任何凭据**
   （password / token 一律留空）。
2. **脚本实际读取配置的位置一律不变** —— 模板只是起步参考，**代码不读模板**：

   | 实际配置文件 | 读取方 | 内容 |
   |---|---|---|
   | `web-install/install-config.json` | `install-server.py`（`CONFIG_FILE`）、`install-remote-spk.sh` / `install-remote-fpk.sh`（`$WS/install-config.json`） | 连接配置（目标主机 / 端口 / 账号 / 密码）—— **含明文密码** |
   | `build/build-config.yaml` | 打包与端口权威（`build-common.sh` / `pack-spk.sh` / `pack-fpk.sh` 等） | 端口 / 品牌 / 分类等，**手动维护、直接生效** |

3. **真实配置永不入库**：`.gitignore` 已忽略 `/config/install-config.json`、`/config/install-tasks.jsonl`
   与当前的实读位置 `/web-install/install-config.json`、`/web-install/install-tasks.jsonl`；
   本目录下**只允许 `*.default.json` 进仓库**。

## 用法

```bash
# 起步：把模板复制到脚本实际读取的位置，再填写
cp config/install-config.default.json web-install/install-config.json
# 然后填 host / username / password；其余可留空
```

## 为什么模板里端口留空

README 的「端口不写死原则」：端口权威在 `build/build-config.yaml`。模板留空（空对象）
即表示「回落权威值」，避免两处各写一份而漂移。

## 注意（2026-10-05 逐处核对，修正过一次误判）

- **本目录的模板对应 `install-config.json`，它只被读【顶层字符串键】**：
  `host`（兼容 `ip`）/ `username`（兼容 `user` / `account`）/ `password` / `system` /
  `appname` / `ssh_port`。**端口不在这个文件里**。
- **端口权威在 `build/build-config.yaml` 的 `defaults` / `spk` / `fpk` 三段**，那里的段名被
  `sec.get('proxy_port')` **按对象**取值 —— 所以**那三个段名必须是对象**，写成字符串才会崩。
- `install-config.json` 里的 `spk` / `fpk` 键**没有任何读取方**（全仓无消费者）：写了无害也无用，
  别把它当成端口覆盖段或包路径入口（README 旧示例中的 `fpk` 包路径即属历史遗留）。

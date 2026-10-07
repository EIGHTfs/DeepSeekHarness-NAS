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

## 注意

`spk` / `fpk` 两个键已被「端口覆盖段」占用（读取方按对象解析：`sec.get('proxy_port')`），
**不要**把 `.spk`/`.fpk` 包路径写进这两个键，否则会报错；包路径请用未占用的键名（如 `spk_path`）。

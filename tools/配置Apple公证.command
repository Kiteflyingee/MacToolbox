#!/bin/sh
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ -f "$task_root/tools/signing.local.env" ]; then . "$task_root/tools/signing.local.env"; fi
task_team="${MACTOOLBOX_TEAM_ID:?请先配置公司开发者团队 ID}"
printf '配置 MacToolbox 的 Apple 公证凭据\n\n'
printf '请使用属于公司开发者团队的 Apple 账户。\n'
printf '先在 https://account.apple.com 的“登录与安全 → App 专用密码”生成专用密码。\n'
printf '随后由 Apple 的 notarytool 安全提示输入，凭据仅存入本机钥匙串，不写入项目。\n'
printf '此步骤只配置并验证凭据，不上传安装包。\n\nApple 账户邮箱：'
IFS= read -r task_apple_id
test -n "$task_apple_id"
xcrun notarytool store-credentials MacToolbox-notary --apple-id "$task_apple_id" --team-id "$task_team"
printf '\n已配置 profile：MacToolbox-notary。可返回聊天继续公证当前候选包。\n'
printf '按回车关闭。'
IFS= read -r task_done

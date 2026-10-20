#!/bin/bash
# 公证 + staple，输入 .app 或 .dmg，发布时两个都要做，顺序是：app → 打 dmg → dmg。
#   .app：ditto 打 zip 提交，票据钉进 app。Homebrew 把 app 从 dmg 里拷出来安装，
#         只钉 dmg 的话装好的 app 没有票据，离线首次启动会被 Gatekeeper 拦下
#   .dmg：签名 → 提交 → staple → 终验（挂载后要求里面的 app 也带票据）
#         签名会改 cdhash，staple 之后不能再签
# 用法：notarize.sh <App.app | App.dmg>
#
# 凭据（env）：ASC_PRIVATE_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID
#   本地：make notarize-app / notarize 从 ~/Sync/apple-developer/secrets.env 加载
#   CI：release.yml 把 ASC_PRIVATE_KEY（p8 的 base64）解码成临时文件
# 不用 notarytool store-credentials 的 keychain profile：非交互环境下会拒绝访问且报 "not found"。
# 可选：SIGN_IDENTITY（默认 "Developer ID Application"）、NOTARY_TIMEOUT（默认 30m）
set -euo pipefail

target=${1:?usage: notarize.sh APP_OR_DMG}
: "${ASC_PRIVATE_KEY_PATH:?}" "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}"
auth=(--key "$ASC_PRIVATE_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
fail() { echo "✗ $*" >&2; exit 1; }

# 提交并等结果，未 Accepted 时打印 Apple 的拒绝原因。新账号首单可能要 45 分钟，之后通常不到 1 分钟
submit() {
    local result id
    result=$(xcrun notarytool submit "$1" "${auth[@]}" --wait --timeout "${NOTARY_TIMEOUT:-30m}" --output-format json) || true
    echo "$result"
    if [[ "$(jq -r '.status // empty' <<<"$result")" != "Accepted" ]]; then
        id=$(jq -r '.id // empty' <<<"$result")
        [[ -n "$id" ]] && xcrun notarytool log "$id" "${auth[@]}" || true
        fail "公证未通过：$1"
    fi
}

# stapler 的 staple 和 validate 每次都要访问 Apple 的 CloudKit。GitHub 的 macOS runner 上
# 实测短时间内连续几次请求常有一次断连（Error 68，"The network connection was lost"），
# 刚 Accepted 时票据也可能还没同步过去，所以统一退避重试。staple 成功时已经顺带 validate
stapler() {
    local i
    for i in 1 2 3 4 5; do
        xcrun stapler "$@" && return 0
        echo "stapler $1 第 ${i} 次失败，$((i * 10)) 秒后重试" >&2
        sleep $((i * 10))
    done
    return 1
}

# Gatekeeper 评估并要求 source=Notarized Developer ID
assess_app() {
    local out
    out=$(spctl --assess --type execute --verbose=2 "$1" 2>&1) || true
    echo "$out"
    grep -q 'source=Notarized Developer ID' <<<"$out" || fail "Gatekeeper 未通过：$1"
}

case "$target" in
    *.app)
        work=$(mktemp -d)
        trap 'rm -rf "$work"' EXIT
        zip="$work/$(basename "$target" .app).zip"
        # 必须 ditto -c -k --keepParent：zip 命令不保留符号链接和扩展属性，签名会失效
        ditto -c -k --keepParent "$target" "$zip"
        submit "$zip"
        stapler staple "$target" || fail "staple 失败：$target"
        assess_app "$target"
        ;;
    *.dmg)
        codesign --sign "${SIGN_IDENTITY:-Developer ID Application}" --timestamp "$target"
        codesign --verify --strict "$target"
        submit "$target"
        stapler staple "$target" || fail "staple 失败：$target"
        spctl --assess --type open --context context:primary-signature --verbose "$target"

        # 用户视角的终验：挂载后对里面的 app 评估，并确认 app 自带票据（Homebrew 装的就是它）
        mnt=$(mktemp -d)
        hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$target" >/dev/null
        trap 'hdiutil detach "$mnt" >/dev/null 2>&1 || true; rmdir "$mnt" 2>/dev/null || true' EXIT
        for app in "$mnt"/*.app; do
            assess_app "$app"
            stapler validate "$app" >/dev/null || fail "dmg 里的 app 没有票据（先对 app 跑 notarize.sh 再打 dmg）"
        done
        ;;
    *) fail "只接受 .app 或 .dmg：$target" ;;
esac
echo "✓ 已公证并 staple：$target"

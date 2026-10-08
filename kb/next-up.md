# Next up

> 接下来要做的事，按时间排。做完一项就删掉，结果记到条目指定的 kb 文档，这里不留记录。

## Apple 开发者账号持有人接受待处理协议后

- **完成首次发布**：运行 `gh workflow run release.yml --ref master`，确认 Apple 公证、staple 与 artifact 上传成功，再推送 `v0.1.0` 标签并检查当前仓库 Release 的 DMG 和依赖安装说明。首次运行已完成签名和打包，但公证返回协议缺失 HTTP 403。
  → 结果记到 `kb/sessions/2026-10-08-release-ci.md`。

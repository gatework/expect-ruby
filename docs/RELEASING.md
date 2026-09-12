# 发布版本

项目名为 `expect-ruby`，RubyGems 名为 `expect-pty`。发布脚本会创建 GitHub Release，附带 Gem 和 `SHA256SUMS`，并把同一个 Gem 推送到 RubyGems。

## 准备版本

1. 更新 `lib/expect/version.rb` 的 `Expect::VERSION`，例如 `0.2.0`。
2. 把 `CHANGELOG.md` 的 `Unreleased` 内容移到对应版本标题下，例如 `## 0.2.0 - 2026-09-12`；可以保留空的 `Unreleased` 标题。
3. 提交并推送到 `main`。发布时工作区必须干净，远端 `main` 必须包含该提交，已有同名标签必须指向该提交。

发布脚本只接受正式版 `X.Y.Z`。仓库当前的 `0.1.1` 仍有未归档的接口变更，应先完成上述版本准备。

## 本地发布

本地已登录 `gem` 时，脚本直接使用已有凭据；GitHub 使用 `gh auth login` 的登录状态。如果 RubyGems 要求一次性验证码，`gem push` 会提示输入。

```sh
bundle install
ruby script/release.rb --dry-run
ruby script/release.rb
```

默认执行 `script/ci` 的检查、完整测试、构建和隔离安装验证，再核对包内文件，在 `pkg/release/版本号/` 生成发布说明和校验文件。正式发布先创建 GitHub Release，再上传 RubyGems，最后下载 RubyGems 上的包核对 SHA256。GitHub 上还没有标签时，会为当前提交创建 `v版本号` 标签。

`--dry-run` 只做本地验证，可在提交前使用。它仍要求版本号和发布说明完整。

## GitHub Actions 发布

GitHub Runner 不会继承本机的 Gem 登录状态。要在 Actions 发布 RubyGems，需在仓库的 Settings → Secrets and variables → Actions 中配置 `RUBYGEMS_API_KEY`，使用具有 `Push rubygem` 权限的发布 Key。

```sh
git tag -a v0.2.0 -m 'Release v0.2.0'
git push origin v0.2.0
gh workflow run release.yml --ref v0.2.0 --repo gatework/expect-ruby
```

也可以在 Actions → Release → Run workflow 选择对应版本标签。工作流仅支持手动触发，避免本地发布时出现第二次并发上传。

发布作业先验证标签与版本号一致，再复用 CI 的 Linux/macOS、Ruby 3.2/3.3/3.4/4.0 共 8 个环境。全部通过后，下载 Ubuntu / Ruby 4.0 作业验证过的 Gem，交给同一个发布脚本；发布阶段不重新构建。

未配置 `RUBYGEMS_API_KEY` 时，GitHub Release 仍会创建，RubyGems 步骤会明确失败；此时可以下载 Release 中的原包，在本地使用已有登录状态完成上传。

## 失败后继续

保留首次验证的 Gem，用它重试发布；更换 RubyGems 工具版本或重新构建可能得到不同字节，同一个版本不得覆盖已有内容。

```sh
ruby script/release.rb --artifact pkg/ci/expect-pty-0.2.0.gem
```

工作流失败时优先使用 Re-run failed jobs，继续使用本次 CI 保存的产物。需要在本地恢复时，检出发布标签对应的干净源码，下载该 Release 的 Gem，再通过 `--artifact` 指定它。

脚本会校验现有 RubyGems 版本和 GitHub Release 附件的 SHA256；一致时复用，不一致时中止。已有 GitHub Release 缺少附件时会补传，已有版本和附件不会被覆盖。

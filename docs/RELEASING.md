# 发布版本

项目名为 `expect-ruby`，RubyGems 名为 `expect-pty`。使用 `script/release.rb --rubygems-only` 可仅发布 RubyGems；不加该选项时还会创建
GitHub Release，附带同一个 Gem 和 `SHA256SUMS`。生成文件统一放在已被 Git 忽略的 `tmp/` 下。

## 准备版本

1. 更新 `lib/expect/version.rb` 的 `Expect::VERSION`，例如 `0.6.0`，同步 README 中的安装版本和构建包路径。
2. 把 `CHANGELOG.md` 的 `Unreleased` 内容移到对应版本标题下，例如 `## 0.6.0 - 2026-09-30`；可以保留空的 `Unreleased` 标题。
3. 提交源码，发布时工作区必须干净。若同时发布 GitHub Release，还需推送到 `main`，远端 `main` 必须包含该提交，已有同名标签必须指向该提交。

发布脚本只接受正式版 `X.Y.Z`；未归档的变更会阻止发布。

## 仅发布 RubyGems

本地已登录 `gem` 时，脚本直接使用已有凭据。如果 RubyGems 要求一次性验证码，`gem push` 会提示输入。此模式不调用 `gh`，不要求推送到
GitHub，也不创建标签或 GitHub Release。

```sh
bundle install
ruby script/release.rb --rubygems-only --dry-run
ruby script/release.rb --rubygems-only
```

默认执行 `script/ci` 的检查、完整测试、构建和隔离安装验证，构建包保存在 `tmp/ci/expect-pty-版本号.gem`。随后复制到
`tmp/release/版本号/candidate-*/` 的独占目录，核对包内文件并生成发布说明和校验文件。该副本贯穿后续发布，目录会保留供失败重试。正式发布前再次确认源码未变，上传
RubyGems 后下载远端包核对 SHA256。

正式发布逐个核对包内普通文件在目标 Git 提交中的存在性、原始字节和执行权限，同时核对 gemspec 的安装元数据及主页。
`git status` 为空不能替代这一检查：忽略规则可能隐藏被 glob 收入包的本地文件，`assume-unchanged` 和 `core.filemode`
也可能隐藏差异。候选包必须与已提交源码一致。

`--dry-run` 只做本地验证，可在提交前使用。它仍要求版本号和发布说明完整。

## 同时发布 GitHub Release

此模式还会复用 `gh auth login` 的登录状态：

```sh
ruby script/release.rb --dry-run
ruby script/release.rb
```

正式发布先创建 GitHub Release，再上传 RubyGems，最后下载 RubyGems 上的包核对 SHA256。GitHub 上还没有标签时，会为当前提交创建
`v版本号` 标签。

## GitHub Actions 发布

GitHub Runner 不会继承本机的 Gem 登录状态。要在 Actions 发布 RubyGems，需在仓库的 Settings → Secrets and variables →
Actions 中配置 `RUBYGEMS_API_KEY`，使用具有 `Push rubygem` 权限的发布 Key。

```sh
git tag -a v0.6.0 -m 'Release v0.6.0'
git push origin v0.6.0
gh workflow run release.yml --ref v0.6.0 --repo gatework/expect-ruby
```

也可以在 Actions → Release → Run workflow 选择对应版本标签。工作流仅支持手动触发，避免本地发布时出现第二次并发上传。

发布作业先验证标签与版本号一致，再复用 CI 的 Linux/macOS、Ruby 3.4/4.0 共 4 个环境。全部通过后，下载 Ubuntu / Ruby
4.0 作业验证过的 Gem，交给同一个发布脚本；发布阶段不重新构建。

未配置 `RUBYGEMS_API_KEY` 时，GitHub Release 仍会创建，RubyGems 步骤会明确失败；此时可以下载 Release 中的原包，在本地使用已有登录状态完成上传。

## 失败后继续

保留脚本输出的 `Artifact` 路径，用该候选 Gem 重试发布；更换 RubyGems 工具版本或重新构建可能得到不同字节，同一个版本不得覆盖已有内容。也可以直接指定从
CI 或 Release 下载的原包：

```sh
ruby script/release.rb --rubygems-only --artifact tmp/ci/expect-pty-0.6.0.gem
```

将示例路径替换为实际输出的 `Artifact` 路径。`--artifact` 会跳过构建和测试，但仍核对包与当前源码是否一致；需要同时恢复
GitHub Release 时去掉 `--rubygems-only`。

工作流失败时优先使用 Re-run failed jobs，继续使用本次 CI 保存的产物。需要在本地恢复时，检出发布标签对应的干净源码，下载该
Release 的 Gem，再通过 `--artifact` 指定它。

脚本会校验现有 RubyGems 版本和 GitHub Release 附件的 SHA256；一致时复用，不一致时中止。已有 GitHub Release
缺少附件时会补传，已有版本和附件不会被覆盖。

上传中断若留下 `starter` 状态的空附件，脚本会明确指出附件名称。先确认没有其他发布或上传在运行，再在 GitHub Release
中删除该失败附件，使用原包重试；脚本不会自动删除可能仍在上传的附件。

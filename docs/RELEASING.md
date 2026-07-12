# Tintap 分支与发布规则

Tintap 使用以 `main` 为稳定分支、以语义化版本标签触发发布的轻量 GitHub Flow。

## 分支规则

- `main`：始终保持可测试、可打包、可发布。禁止直接提交，所有修改通过 Pull Request 合入。
- `feature/<name>`：新功能分支，从最新 `main` 创建。
- `fix/<name>`：普通缺陷修复分支，从最新 `main` 创建。
- `release/vX.Y.Z`：发布准备分支，只允许版本号、发布说明和发布阻塞问题修复。
- `hotfix/vX.Y.Z`：线上紧急修复分支，从 `main` 创建，仍需通过 Pull Request 合入。

建议在 GitHub 的 `main` 分支保护规则中启用：

1. Require a pull request before merging。
2. Require status checks to pass，并选择 `Test (macOS arm64)`。
3. Require branches to be up to date before merging。
4. Block force pushes 和 Block deletions。
5. 合并策略只启用 Squash merge，保持 `main` 历史清晰。

## 版本规则

版本使用 `MAJOR.MINOR.PATCH`：

- `MAJOR`：不兼容的行为或配置变化。
- `MINOR`：向后兼容的新功能。
- `PATCH`：向后兼容的缺陷修复。

Git 标签必须使用 `vMAJOR.MINOR.PATCH`，例如 `v0.2.0`。标签版本必须与 `Resources/Info.plist` 中的 `CFBundleShortVersionString` 完全一致，而且标签必须指向已经合入 `main` 的提交。Release workflow 会强制检查这两项。

## 发布流程

以发布 `0.2.0` 为例：

1. 从最新 `main` 创建发布分支：

   ```zsh
   git switch main
   git pull --ff-only
   git switch -c release/v0.2.0
   ```

2. 将 `Resources/Info.plist` 中的 `CFBundleShortVersionString` 更新为 `0.2.0`，按需递增 `CFBundleVersion`，完成发布说明并提交。
3. 创建 Pull Request 合入 `main`，等待 `Test (macOS arm64)` 检查通过并完成审核。
4. 合并后在准确的 `main` 提交上创建带注释标签：

   ```zsh
   git switch main
   git pull --ff-only
   git tag -a v0.2.0 -m "Tintap 0.2.0"
   git push origin v0.2.0
   ```

5. `Release macOS app` workflow 自动执行以下工作：

   - 校验标签格式、所属分支与应用版本。
   - 在 macOS arm64 和 Intel runner 上分别运行测试。
   - 生成并验证 ad-hoc 签名的 `Tintap.app`。
   - 打包两个架构的 ZIP，并生成 `SHA256SUMS.txt`。
   - 创建 GitHub Release，上传全部下载文件并生成变更说明。

发布标签视为不可变。发现问题时不要移动或覆盖已有标签，应修复后发布新的 PATCH 版本。

## 无证书分发说明

当前自动发布使用 ad-hoc 签名，没有 Developer ID 证书，也不会提交 Apple 公证。用户首次启动时需要手动允许应用运行。获得 Apple Developer 证书后，应在 workflow 中增加 Developer ID 签名、公证和 stapling，再移除 Release 中的未公证提示。

# 和这个仓库的主人协作时的约定

- **不做 CI 屏幕截图**（用户要求，2026-11-25）：
  - 用户用真机配合调试，改完直接编 IPA 发过去，等用户的真机反馈（截图、录屏）。
  - `ios-dissolve.yml`、`ios-ipad.yml`、`ios-preview.yml` 只在手动运行时截图，平时推送不触发。
  - 推送到 `claude/**` 或 `main` 时只有 `ios.yml` 编 IPA。
  - 不要再为新功能加截图用的 UI 测试和工作流步骤。
- **编出 IPA 就发给用户**：用户原话「完成ipa时 推送ipa包给我」。
- 用户用中文交流。
- 用户的设备：iPhone Duo（可折叠，折起时侧边一列放状态栏和导航）、iPhone、iPad。
  - 版面和动效要在这几种形态下都对，iPhone Duo 折起时尤其要注意。
- 改完 CI 编译通过后，开 PR、squash 合并到 `main`；分支再用 `git merge -s ours` 接上 `main`。
- 密钥、口令、胡椒一律不打印、不提交。
- `check.cuven.us` 的 Worker 源码不放进这个公开仓库。

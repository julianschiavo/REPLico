# Releasing REPLico

Every pull request into `main` needs exactly one release label. Choose `release:patch` for a fix, `release:minor` for a compatible feature or `release:major` for a breaking change. The first bump starts at `0.0.0`.

## Set up GitHub

Once the workflows are on GitHub, create the three labels and install the [main branch ruleset](../.github/rulesets/main.json) as a repository administrator.

```sh
gh label create release:patch --color 1D76DB
gh label create release:minor --color 0E8A16
gh label create release:major --color B60205
gh api --method POST 'repos/{owner}/{repo}/rulesets' --input .github/rulesets/main.json
```

The ruleset requires a pull request, the release label check, Swift formatting, and tests on macOS arm64 and Ubuntu 24.04 arm64 and x64. Adding or removing a label reruns the label check. A ruleset file takes effect when a repository administrator installs it. [GitHub rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository)

## After a merge

The release workflow runs formatting and tests on the merged commit. It builds three runtime archives, tags a child commit containing the versioned SwiftPM manifest, and publishes the GitHub release after verifying each uploaded asset. The source manifest on `main` points to the local development runtime. A tagged package downloads its verified runtime through SwiftPM.

If publication stops partway through, rerun the failed workflow. It reuses the tag for that merge, checks existing asset digests and uploads missing assets to the draft. Conflicting bytes fail the run.

## Local development

```sh
scripts/runtime.py prepare
scripts/test.sh
```

Preparation verifies the official Node 26.13.1 download before extracting the executable and its notices.

The test script builds the library and both example apps together using `Tests/Packages.xcworkspace`. The workspace has its own SwiftPM lockfile because MathComplex also uses Swift Argument Parser. SwiftPM 6.4 marks its `--multiroot-data-file` option unsupported, so check this invocation when upgrading the CI toolchain.

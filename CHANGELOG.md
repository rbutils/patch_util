Initial release.

- Add GitHub Actions CI for Ruby matrix testing.
- Fix rewrite replay when git identity is not configured in the environment.
- Fix sequential replay for split text additions and deletions.
- Add rewrite preflight verification so non-replayable chunk series fail before history rewrite starts.

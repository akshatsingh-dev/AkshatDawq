# Contributing to DAWQ

Thanks for contributing.

## Development Setup

1. Install dependencies and generate the Xcode project:
   - `./setup.sh`
2. Open project:
   - `open DAWQ.xcodeproj`
3. Build check:
   - `xcodebuild -project DAWQ.xcodeproj -scheme DAWQ -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build`

## Branch and PR Guidelines

- Create focused branches (`feat/...`, `fix/...`, `chore/...`).
- Keep PRs scoped to one problem.
- Include:
  - what changed
  - why it changed
  - how to test

## Commit Guidelines

- Prefer small, reviewable commits.
- Use clear intent in commit messages:
  - `feat: add document delete in Data tab`
  - `fix: validate GGUF response status before save`
  - `docs: add onboarding setup notes`

## Quality Bar

- Build must pass before opening PR.
- Avoid introducing misleading UI states (status must match real runtime state).
- Keep health/privacy behavior explicit and conservative.

## Security and Privacy

- Do not commit secrets, tokens, credentials, or private datasets.
- Keep user health data handling local-first unless explicitly designed otherwise.

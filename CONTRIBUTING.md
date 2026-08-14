# Contributing

## Reporting Issues

- Check if the issue already exists
- Include your Fedora version and hardware details
- Attach relevant log output if you have it

## Suggesting Features

- Explain what you're trying to do and why
- Check if it fits the scope of a post-install script
- If you have an implementation idea, describe it

## Pull Requests

1. Fork the repo
2. Create a feature branch
3. Make your changes
4. Test in a VM using `--dry-run` first, then for real on a clean Fedora install
5. Update docs if needed
6. Submit a PR with a clear description

## Code Style

- 2-space indentation
- Comments for non-obvious logic (skip the obvious)
- Follow existing function patterns
- Validate user inputs

## Safety Rules

- Don't remove existing safety checks
- Include error handling
- Maintain backward compatibility
- Test different profiles

## Questions?

Open an issue before making large changes.
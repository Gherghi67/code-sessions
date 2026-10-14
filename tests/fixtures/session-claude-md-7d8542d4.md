# Session Documentation Protocol

This is a Claude Code session managed by the cs tool. This session has automatic artifact tracking and documentation support.

## Session Files - READ THESE ON RESUME

When resuming this session, read the following files to restore context:

1. **summary.md** - If exists, read first for previous session overview
2. **README.md** - Session objective, environment, and outcome
3. **discoveries.md** - Findings about the system/environment
4. **changes.md** - Modifications and fixes made
5. **notes.md** - Observations and ideas
6. **artifacts/MANIFEST.json** - List of tracked artifacts

## Artifact Auto-Tracking

Scripts and configuration files you create are **automatically saved to artifacts/**:

- Scripts: .sh, .bash, .zsh, .py, .js, .ts, .rb, .pl
- Configs: .conf, .config, .json, .yaml, .yml, .toml, .ini, .env

When you use the Write tool for these file types, they are automatically redirected to the artifacts/ directory and tracked in MANIFEST.json.

## Documentation Discipline

Update the markdown documentation files throughout the session:

1. **Start of session:** Fill in README.md objective and environment
2. **As you work:** Update discoveries.md with findings and changes.md with modifications
3. **End of session:** Complete the README.md outcome section

Treat these files as a lab notebook - document as you go, not just at the end.

## Summary Command

When the session is complete, use the `/summary` command to generate an intelligent summary of the entire session. This will create a summary.md file synthesizing all documentation.

## Best Practices

- Document discoveries as you find them - don't wait until the end
- Use artifacts/ for any reusable scripts or configs
- Keep changes.md updated with each modification
- Use notes.md for temporary thoughts and ideas
- Run `/summary` at the end to create a cohesive record

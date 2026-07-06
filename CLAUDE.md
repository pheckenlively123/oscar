@AGENTS.md

## Validation commands

After any change to `scripts/update-all.sh`, run:

```bash
bash -n scripts/update-all.sh
UPDATE_ALL_SELFTEST=1 bash scripts/update-all.sh
```

If `shellcheck` is available:

```bash
shellcheck scripts/update-all.sh
```

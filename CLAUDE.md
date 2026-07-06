@AGENTS.md

## Validation commands

After any change to `scripts/update-all-fedora.sh` or `scripts/update-all-ubuntu.sh`, run (against each changed script):

```bash
bash -n scripts/update-all-<distro>.sh
UPDATE_ALL_SELFTEST=1 bash scripts/update-all-<distro>.sh
```

If `shellcheck` is available:

```bash
shellcheck scripts/update-all-<distro>.sh
```

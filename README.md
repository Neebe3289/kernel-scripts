# Kernel build script

`BOT_TOKEN` and `CHAT_ID` are **optional** for Telegram bot notifications and file uploads. If omitted, the build artifact `.zip` will be saved locally to the `release/` directory.

```bash
Usage:
./build.sh -b

Options:
-b, --build # Build normal + KPatch fixes
-k, --ksu # Build KernelSU feat NoMount
-a, --all # Build both kernels
-r, --regen # Regenerate defconfig
-c, --clean # Clean build outputs and temporary artifacts
-h, --help # Show help message
```


# Kernel build script

The script requires `BOT_TOKEN` and `CHAT_ID` environment variables for Telegram bot notifications.

```bash
Usage:
./build.sh -b

Options:
-b, --build # Build normal + kpatch fixes
-k, --ksu # Build KernelSU feat NoMount
-a, --all # Build both
-r, --regen # Regenerate defconfig
-c, --clean # Clean build outputs and temporary artifacts
-h, --help # Show help message
```


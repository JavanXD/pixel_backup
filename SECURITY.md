# Security Policy

## Supported versions

Only the latest release receives security fixes.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Instead, report them privately:

1. Go to the repository's **Security** tab → **Report a vulnerability** (GitHub's private advisory flow), or
2. Email the maintainer directly (add contact here)

Include:
- A description of the vulnerability and its potential impact
- Steps to reproduce or a proof-of-concept
- Any suggested fix, if you have one

You can expect an acknowledgement within 48 hours and a resolution or status update within 14 days.

## Scope

This tool runs entirely locally — it does not send data to any server, has no backend, and makes no network requests except the optional `adb` binary download from Google's servers during build. The primary attack surface is:

- The bundled `adb` binary (sourced directly from Google platform-tools)
- The `pixel_backup.sh` shell script executing on the local machine with user privileges
- The macOS SwiftUI app executing the script as a child process

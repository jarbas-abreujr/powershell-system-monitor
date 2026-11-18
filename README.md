# PowerShell System Monitor

A Windows PowerShell script that continuously monitors CPU, memory, and disk usage. Thresholds and notification channels are configured in a local JSON file.

## Requirements

- Windows PowerShell 5.1 or later
- The `Send-MailKitMessage` PowerShell module only if email alerts are enabled

## Setup

1. Copy `config.example.json` to `config.json`.
2. Set `DiskPath` to a drive on the machine, such as `C:\`.
3. Adjust the warning and critical thresholds as needed.
4. Configure the desired alert channels and set their `Enabled` values to `true`. Keep `config.json` private; it is excluded by `.gitignore`.
5. Run the monitor from PowerShell:

   ```powershell
   .\Monitor.ps1
   ```

The script writes its log to `Logs\CPULogs.txt` beside `Monitor.ps1`. Press `Ctrl+C` to stop it.

## Configuration

- `CheckInterval`: delay between checks, in seconds.
- `Thresholds`: warning and critical percentages for `CPU`, `Memory`, and `Disk`.
- `DiskPath`: drive to monitor, including its colon (for example, `C:\`).
- `Alerts`: independent notification settings for email, Slack, Microsoft Teams, and Discord.

An alert is sent when a metric changes severity, rather than on every check. A transition back to `Normal` is also reported. The script continues monitoring if an individual metric or notification channel encounters an error.

Email notifications use `Send-MailKitMessage`; install and configure that module before enabling email. Webhook-based channels require a valid URL for the corresponding service.

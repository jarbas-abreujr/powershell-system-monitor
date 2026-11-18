<#
.SYNOPSIS
    System resource monitor (CPU, Memory, Disk) with multi-channel alerting.

.DESCRIPTION
    This script continuously monitors CPU, RAM, and Disk usage, classifying each
    metric into two severity levels (Warning/Critical) based on thresholds defined
    in config.json.

    To avoid alert spam, the script only fires a notification when a metric's
    level CHANGES (e.g. Normal -> Warning), not on every loop iteration. This is
    controlled by a state hashtable ($AlertState).

    Alerts can be sent through up to 4 channels, each independently enabled or
    disabled via config.json:
        - Email (via MailKit)
        - Slack (webhook)
        - Microsoft Teams (webhook via Workflows, Adaptive Card format)
        - Discord (webhook)

    The architecture is resilient: a failure collecting one metric, or sending an
    alert through one specific channel, does not stop monitoring of the other
    metrics or delivery through the remaining channels. All events and errors are
    logged to file (CPULogs.txt).

.NOTES
    Author: Jarbas Abreu Jr.
    Requires: Send-MailKitMessage module (for the Email channel)
    Configuration: config.json in the same directory as this script
#>

#___________________Configuration_______________'
# Hashtable to store each resource status.
$AlertState = @{
    Cpu = "Normal"
    Memory = "Normal"
    Disk = "Normal"
}
# Log Environment
$ProjectFolder = $PSScriptRoot
$LogFolder = Join-Path $ProjectFolder "Logs"
$LogFile = Join-Path $LogFolder "CPULogs.txt"

# Config.json


$ConfigFile = Join-Path $ProjectFolder "config.json"

# Create Log Environment if it does not exist.
Try {
if (-not (Test-Path $LogFolder)) {
    [void](New-Item -ItemType Directory -Path $LogFolder -ErrorAction Stop)  
}
}Catch {
    Write-Host "Unable to create log folder. $($_.Exception.Message)" -ForegroundColor Red
    return
}


# Check and get Config JSON data
Try{
    $Config = Get-Content $ConfigFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}
Catch {
    Write-Host "$($_.Exception.Message). Please check the configuration file." -ForegroundColor Red
    return
}

# Check if required fields from JSON are there. ACTUALLY NEED TO UPDATE
if (-not $Config.Thresholds -or -not $Config.CheckInterval -or -not $Config.Alerts -or -not $Config.Alerts.Email -or -not $Config.Alerts.Slack -or -not $Config.Alerts.Teams -or -not $Config.Alerts.Discord){
    Write-Host "Config file is missing required fields"
    return
}

# Update Config Json values:
$DriveLetter = $Config.DiskPath.TrimEnd('\')

#___________________FUNCTIONS___________________

function Get-MemoryUsage {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $totalMemory = $os.TotalVisibleMemorySize
    $freeMemory = $os.FreePhysicalMemory

    $usedPercent = (($totalMemory - $freeMemory) / $totalMemory) * 100
    return [math]::Round($usedPercent, 2)
    }
    catch {
        Write-Log -Message "Unable to retrieve Memory Information. Error: $($_.Exception.Message)" -Level ERROR
        return $null
    }
}

function Get-DiskUsage {
    param(
        [string]$DriveLetter = "C:"
    )

    try {
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$DriveLetter'" -ErrorAction Stop

        if (-not $disk){
            throw "Drive $DriveLetter not found."
        }
    
        $usedPercent = (($disk.Size - $disk.FreeSpace) / $disk.Size) * 100
        return [math]::Round($usedPercent, 2)
    
    }
    catch {
        Write-Log -Message "Unable to retrieve Disk information. Error $($_.Exception.Message)" -Level ERROR
        return $Null
    }
}

function Get-CpuUsage{
    Try {
        $cpu = (Get-CimInstance Win32_Processor -ErrorAction Stop).LoadPercentage
        return $cpu
    }
    Catch {
        Write-Log -Message "Unable to retrieve CPU information. Error: $($_.Exception.Message)" -Level ERROR
        Return $Null
    }
}
function Get-AlertLevel {
    param(
        [double]$Value,
        [double]$WarningThreshold,
        [double]$CriticalThreshold
    )

    if ($value -ge $CriticalThreshold){
        return "Critical"
    }
    elseif ($Value -ge $WarningThreshold) {
        return "Warning"
    }
    else{
        return "Normal"
    }
}

function Update-AlertState {
    param(
        [string]$Metric,
        [string]$NewLevel
    )

    $OldLevel = $AlertState[$Metric]

    if ($NewLevel -ne $OldLevel){
        $AlertState[$Metric] = $NewLevel
        return $true # changed -> alert
    }

    return $false # didn`t change -> don`t alert
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARNING","ERROR")]
        [string]$Level = "INFO"
    )

    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Try{
        Add-Content -Path $LogFile -Value "[$TimeStamp] [$Level] $Message" -ErrorAction Stop
    }
    Catch{
        Write-Host "Unable to write to the log file. $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Send-EmailAlert {
    param(
        [string]$Subject,
        [string]$Body
    )

    $EmailConfig = $Config.Alerts.Email

    try {

        $Credential = [System.Management.Automation.PSCredential]::new($EmailConfig.Username, (ConvertTo-SecureString $EmailConfig.Password -AsPlainText -Force))
        $Parameters = @{
            "SmtpServer" = $EmailConfig.SmtpServer
            "Port" = $EmailConfig.SmtpPort
            "UseSecureConnectionIfavailable" = $true
            "From" = $EmailConfig.From
            "Recipientlist" = $EmailConfig.To
            "Subject" = $Subject
            "TextBody" = $Body
            "Credential" = $Credential
        }

        Send-MailKitMessage @Parameters -ErrorAction Stop

    }
    catch{
        Write-Log -Message "Failed to send email alert. Error: $($_.Exception.Message)" -Level "ERROR"
    }
}

function Send-SlackAlert {
    param (
        [string]$Message
    )
    $SlackConfig = $Config.Alerts.Slack

    Try {
        $Payload = @{
            text = $Message
        } | ConvertTo-Json

        Invoke-RestMethod -Uri $SlackConfig.WebhookUrl -Method Post -Body $Payload -ContentType "application/json" -ErrorAction Stop
    }
    Catch {
        Write-Log -Message "Failed to send Slack alert. Error: $($_.Exception.Message)" -Level "ERROR"
    }
}
function Send-TeamsAlert {
    param(
        [string]$Message
    )

    $TeamsConfig = $Config.Alerts.Teams

    try {
        $Payload = @{
            type = "message"
            attachments = @(
                @{
                    contentType = "application/vnd.microsoft.card.adaptive"
                    content = @{
                        type = "AdaptiveCard"
                        body = @(
                            @{
                                type = "TextBlock"
                                text = $Message
                            }
                        )
                        '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"
                        version = "1.2"
                    }
                }
            )
        } | ConvertTo-Json -Depth 10

        Invoke-RestMethod -Uri $TeamsConfig.WebhookUrl -Method Post -Body $Payload -ContentType "application/json" -ErrorAction Stop
    }
    catch {
        Write-Log -Message "Failed to send Teams alert. Error: $($_.Exception.Message)" -Level "ERROR"
    }
}

function Send-DiscordAlert {
    param (
        [string]$Message
    )
    $DiscordConfig = $Config.Alerts.Discord

    Try {
        $Payload = @{
            username = "Monitor App"
            avatar_url = "https://i.pinimg.com/736x/04/c0/32/04c0324cc13083806e419d6785e50351.jpg"
            embeds = @(
                @{
                    title = "🚨 Alerta de Monitoramento"
                    description = $Message
                    color = 15158332
                }

            )

        } | ConvertTo-Json -Depth 10

        Invoke-RestMethod -Uri $DiscordConfig.WebhookUrl -Method Post -Body $Payload -ContentType "application/json" -ErrorAction Stop
    }
    Catch {
        Write-Log -Message "Failed to send Discord alert. Error: $($_.Exception.Message)" -Level "ERROR"
    }
}

function Send-Alert {
    param(                                              
        [string]$Metric,
        [string]$Level,
        [string]$Value
    )

    $Message = "[$Level] $Metric usage is at $Value%."

    Write-Log -Message "$Message"

    if($Config.Alerts.Email.Enabled){
        Send-EmailAlert -Subject "Monitor App - $Metric $Level" -Body $Message
    }
    if ($Config.Alerts.Slack.Enabled){
        Send-SlackAlert -Message $Message
    }
    if ($Config.Alerts.Teams.Enabled){
        Send-TeamsAlert -Message $Message
    }
    if ($Config.Alerts.Discord.Enabled){
        Send-DiscordAlert -Message $Message
    }


}

while ($true){
    Try {
        #________CPU________
        $cpuUsage = Get-CpuUsage
        if ($null -ne $cpuUsage){
            $level = Get-AlertLevel -Value $cpuUsage -WarningThreshold $Config.Thresholds.Cpu.Warning -CriticalThreshold $Config.Thresholds.Cpu.Critical
            if (Update-AlertState -Metric "Cpu" -NewLevel $level){
                Send-Alert -Metric "CPU" -Level $level -Value "$cpuUsage"                
            }
            Write-Host "CPU: $cpuUsage% [$level]"
        }
        #________Memory________
        $memUsage = Get-MemoryUsage
        if ($null -ne $memUsage){
            $level = Get-AlertLevel -Value $memUsage -WarningThreshold $Config.Thresholds.Memory.Warning -CriticalThreshold $Config.Thresholds.Memory.Critical
            if (Update-AlertState -Metric "Memory" -NewLevel $level){
                Send-Alert -Metric "Memory" -Level $level -Value $memUsage
            }
            Write-Host "Memory: $memUsage% [$level]"
        }
        #________Disk________
        $DiskUsage = Get-DiskUsage -DriveLetter $DriveLetter
        if ($null -ne $DiskUsage){
            $level = Get-AlertLevel -Value $DiskUsage -WarningThreshold $Config.Thresholds.Disk.Warning -CriticalThreshold $Config.Thresholds.Disk.Critical
            if (Update-AlertState -Metric "Disk" -NewLevel $level){
                Send-Alert -Metric "Disk" -Level $level -Value $diskUsage
            }
            Write-Host "Disk: $DiskUsage% [$level]`n-"
        }    
        
    
    }
    Catch{
        Write-log -Message "Unexpected error in main loop. $($_.Exception.Message)" -Level "ERROR"
        Write-host "Unexpected error occurred. Check logs for details." -ForegroundColor Red
    }
    Finally {
        Start-Sleep -Seconds $Config.CheckInterval
    }  
}
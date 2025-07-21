<#
.SYNOPSIS
Система автоматического резервного копирования для Windows

.DESCRIPTION
Этот скрипт выполняет резервное копирование согласно конфигурационному файлу

.PARAMETER Action
Действие: start, stop, status или help

.EXAMPLE
.\backup_system.ps1 start
Запускает систему резервного копирования

.EXAMPLE
.\backup_system.ps1 stop
Останавливает систему резервного копирования
#>

param(
    [string]$Action = "help"
)

# Конфигурационные параметры
$ConfigFile = "$env:ProgramData\backup_system\backup_system.conf"
$LogFile = "$env:ProgramData\backup_system\backup_system.log"
$PidFile = "$env:ProgramData\backup_system\backup_system.pid"
$DefaultBackupRetention = 1

# Функция для вывода справки
function Show-Help {
    @"
Система автоматического резервного копирования для Windows

Использование: backup_system.ps1 {start|stop|status|help}

Команды:
start     - запуск системы бэкапа
stop      - остановка системы бэкапа
status    - проверка статуса работы системы бэкапа
help      - показать эту справку

Формат конфигурационного файла ($ConfigFile):
Каждая строка содержит параметры, разделенные символом '|':
исходная_директория|директория_бэкапов|пароль|расписание|[retention]

Параметры:
исходная_директория - путь к директории для бэкапа
директория_бэкапов  - где хранить резервные копии
пароль              - пароль для шифрования бэкапа
расписание          - когда делать бэкап (форматы:
HH:MM - конкретное время
hourly - каждый час
daily - ежедневно в 00:00
weekly - еженедельно в понедельник в 00:00)
retention           - (опционально) сколько копий хранить (по умолчанию 1)

Примеры строк конфигурации:
C:\Users\user|D:\backups|secret123|daily|3
C:\Websites|D:\backups|qwerty|weekly|5
C:\Config|D:\backups|adminpass|12:00|7
D:\Data|D:\backups|mypass|hourly

Для работы системы требуется:
- 7-Zip (для создания архивов)
- PowerShell 5.1 или новее

Создайте файл $ConfigFile с нужными настройками перед запуском.
"@
}

# Функция логирования
function Write-Log {
    param(
        [string]$Message
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$Timestamp] $Message" | Out-File -FilePath $LogFile -Append
}

# Функция проверки конфигурационного файла
function Test-ConfigFile {
    if (-not (Test-Path $ConfigFile)) {
        Write-Log "Ошибка: конфигурационный файл $ConfigFile не найден"
        return $false
    }

    if ((Get-Content $ConfigFile).Length -eq 0) {
        Write-Log "Ошибка: конфигурационный файл $ConfigFile пуст"
        return $false
    }

    return $true
}

# Функция создания архива
function Create-Backup {
    param(
        [string]$SourceDir,
        [string]$BackupDir,
        [string]$Password,
        [int]$Retention
    )

    if (-not (Test-Path $SourceDir)) {
        Write-Log "Ошибка: исходная директория $SourceDir не существует"
        return $false
    }

    if (-not (Test-Path $BackupDir)) {
        try {
            New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
        } catch {
            Write-Log "Ошибка: не удалось создать директорию для бэкапов $BackupDir"
            return $false
        }
    }

    $Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $BackupName = "backup_$(Split-Path $SourceDir -Leaf)_${Timestamp}.7z"
    $BackupPath = Join-Path $BackupDir $BackupName

    try {
        # Используем 7-Zip для создания архива
        $7zPath = "$env:ProgramFiles\7-Zip\7z.exe"
        if (-not (Test-Path $7zPath)) {
            Write-Log "Ошибка: 7-Zip не установлен или путь неверный"
            return $false
        }

        & $7zPath a -t7z -mx9 -p$Password $BackupPath $SourceDir | Out-File -FilePath $LogFile -Append

        if ($LASTEXITCODE -eq 0) {
            Write-Log "Бэкап успешно создан: $BackupPath"

            # Удаляем старые бэкапы с учетом retention
            $BackupPattern = "backup_$(Split-Path $SourceDir -Leaf)_*.7z"
            $OldBackups = Get-ChildItem -Path $BackupDir -Filter $BackupPattern | Sort-Object LastWriteTime -Descending | Select-Object -Skip $Retention

            foreach ($OldBackup in $OldBackups) {
                Remove-Item $OldBackup.FullName -Force
                Write-Log "Удален старый бэкап: $($OldBackup.FullName)"
            }

            return $true
        } else {
            Write-Log "Ошибка при создании бэкапа $BackupPath (код ошибки: $LASTEXITCODE)"
            return $false
        }
    } catch {
        Write-Log "Ошибка при создании бэкапа: $_"
        return $false
    }
}

# Функция парсинга строки конфига
function Parse-ConfigLine {
    param(
        [string]$Line
    )

    # Пропускаем комментарии и пустые строки
    if ($Line -match "^#" -or [string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }

    $Parts = $Line -split "\|"

    if ($Parts.Count -lt 4) {
        Write-Log "Ошибка: неверный формат строки конфига: $Line"
        return $null
    }

    $SourceDir = $Parts[0].Trim()
    $BackupDir = $Parts[1].Trim()
    $Password = $Parts[2].Trim()
    $Schedule = $Parts[3].Trim()

    if ($Parts.Count -ge 5) {
        $Retention = $Parts[4].Trim()
    } else {
        $Retention = $DefaultBackupRetention
    }

    # Проверяем, что retention - число
    if (-not ($Retention -match "^\d+$")) {
        Write-Log "Ошибка: неправильное значение retention '$Retention' для директории $SourceDir. Используется значение по умолчанию $DefaultBackupRetention"
        $Retention = $DefaultBackupRetention
    }

    return @{
        SourceDir = $SourceDir
        BackupDir = $BackupDir
        Password = $Password
        Schedule = $Schedule
        Retention = [int]$Retention
    }
}

# Функция выполнения бэкапов по расписанию
function Invoke-ScheduledBackups {
    $CurrentTime = Get-Date -Format "HH:mm"
    $CurrentDay = (Get-Date).DayOfWeek

    $ConfigLines = Get-Content $ConfigFile

    foreach ($Line in $ConfigLines) {
        $Config = Parse-ConfigLine $Line
        if (-not $Config) { continue }

        $ShouldBackup = $false

        switch ($Config.Schedule) {
            { $_ -match "^\d{2}:\d{2}$" } {
                if ($CurrentTime -eq $_) {
                    $ShouldBackup = $true
                }
                break
            }
            "hourly" {
                $ShouldBackup = $true
                break
            }
            "daily" {
                if ($CurrentTime -eq "00:00") {
                    $ShouldBackup = $true
                }
                break
            }
            "weekly" {
                if ($CurrentTime -eq "00:00" -and $CurrentDay -eq "Monday") {
                    $ShouldBackup = $true
                }
                break
            }
            default {
                Write-Log "Неизвестное расписание: $($Config.Schedule) для директории $($Config.SourceDir)"
                continue
            }
        }

        if ($ShouldBackup) {
            Create-Backup -SourceDir $Config.SourceDir -BackupDir $Config.BackupDir -Password $Config.Password -Retention $Config.Retention
        }
    }
}

# Основной код
switch ($Action.ToLower()) {
    "start" {
        if (-not (Test-ConfigFile)) {
            Write-Log "Не удалось запустить систему бэкапа из-за ошибок в конфигурационном файле"
            exit 1
        }

        Write-Log "Запуск системы бэкапа"

        # Создаем PID-файл
        $PID = $PID
        $PID | Out-File -FilePath $PidFile

        # Основной цикл
        while ($true) {
            Invoke-ScheduledBackups
            Start-Sleep -Seconds 60
        }
    }
    "stop" {
        if (Test-Path $PidFile) {
            $PID = Get-Content $PidFile
            Stop-Process -Id $PID -Force
            Remove-Item $PidFile -Force
            Write-Log "Система бэкапа остановлена"
        } else {
            Write-Log "Система бэкапа не запущена"
        }
    }
    "status" {
        if (Test-Path $PidFile) {
            $PID = Get-Content $PidFile
            if (Get-Process -Id $PID -ErrorAction SilentlyContinue) {
                Write-Output "Система бэкапа работает (PID: $PID)"
            } else {
                Write-Output "PID файл существует, но процесс не найден"
            }
        } else {
            Write-Output "Система бэкапа не запущена"
        }
    }
    "help" {
        Show-Help
    }
    default {
        Write-Output "Неизвестная команда: $Action"
        Show-Help
        exit 1
    }
}

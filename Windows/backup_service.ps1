<#
.SYNOPSIS
Установка и управление службой резервного копирования

.DESCRIPTION
Этот скрипт позволяет установить, удалить, запустить или остановить службу резервного копирования

.PARAMETER Action
Действие: install, uninstall, start, stop или status

.EXAMPLE
.\backup_service.ps1 install
Устанавливает службу резервного копирования

.EXAMPLE
.\backup_service.ps1 start
Запускает службу резервного копирования
#>

param(
    [string]$Action = "help"
)

$ServiceName = "BackupSystemService"
$ScriptPath = Join-Path $PSScriptRoot "backup_system.ps1"

function Show-Help {
    @"
Управление службой резервного копирования

Использование: backup_service.ps1 {install|uninstall|start|stop|status|help}

Команды:
install   - установить службу
uninstall - удалить службу
start     - запустить службу
stop      - остановить службу
status    - проверить статус службы
help      - показать эту справку

Требования:
- PowerShell 5.1 или новее
- Права администратора для установки/удаления службы
"@
}

function Install-Service {
    if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
        Write-Output "Служба $ServiceName уже установлена"
        return
    }

    $ServiceParams = @{
        Name = $ServiceName
        BinaryPathName = "powershell.exe -ExecutionPolicy Bypass -NoProfile -File `"$ScriptPath`" start"
        DisplayName = "Backup System Service"
        Description = "Служба автоматического резервного копирования"
        StartupType = "Automatic"
    }

    New-Service @ServiceParams | Out-Null

    # Настраиваем восстановление службы
    sc.exe failure $ServiceName reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null

    Write-Output "Служба $ServiceName успешно установлена"
}

function Uninstall-Service {
    if (-not (Get-Service $ServiceName -ErrorAction SilentlyContinue)) {
        Write-Output "Служба $ServiceName не установлена"
        return
    }

    Stop-Service $ServiceName -Force
    Start-Sleep -Seconds 2

    $Service = Get-WmiObject -Class Win32_Service -Filter "Name='$ServiceName'"
    $Service.Delete() | Out-Null

    Write-Output "Служба $ServiceName успешно удалена"
}

switch ($Action.ToLower()) {
    "install" {
        if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Write-Output "ОШИБКА: Для установки службы требуются права администратора"
            exit 1
        }

        Install-Service
    }
    "uninstall" {
        if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Write-Output "ОШИБКА: Для удаления службы требуются права администратора"
            exit 1
        }

        Uninstall-Service
    }
    "start" {
        Start-Service $ServiceName
        Write-Output "Служба $ServiceName запущена"
    }
    "stop" {
        Stop-Service $ServiceName
        Write-Output "Служба $ServiceName остановлена"
    }
    "status" {
        $Service = Get-Service $ServiceName -ErrorAction SilentlyContinue
        if ($Service) {
            Write-Output "Служба $ServiceName: $($Service.Status)"
        } else {
            Write-Output "Служба $ServiceName не установлена"
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

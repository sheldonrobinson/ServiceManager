# Service Manager

A system tray application written in AutoIt to manage local AI services:

- **LlaMA.C++ HTTP Server** (port 11434)
- **AgentGateway** (port 15000)
- **MCPJungle** (port 8080)

## Features

- **System Tray UI** - Runs silently in the system tray
- **Per-Service Controls** - Start, Stop, Open Web UI, Show/Hide window for each service
- **Global Actions** - Start All, Stop All, Show All, Hide All
- **Auto-Start Configuration** - Multiple mutually exclusive modes per service:
  - Windows Service (requires admin)
  - Scheduled Task at logon (requires admin)
  - Startup Folder Shortcut (per-user, no admin)
  - None (disabled)
- **Global Auto-Start on Launch** - Configure which services start automatically when Service Manager launches
- **Hybrid Elevation** - Runs in user mode by default; self-elevates only for Service/Task operations
- **Persistence** - Remembers PIDs and auto-start settings across restarts
- **Single Instance** - Prevents multiple instances from running
- **Hidden Window Start** - Services start hidden; can be shown via tray menu

## Installation Path Detection

The application automatically detects installation paths using the following priority:

1. **Registry (HKLM)** - `HKEY_LOCAL_MACHINE\SOFTWARE\Konnek\<app>\InstallPath`
2. **Registry (HKCU)** - `HKEY_CURRENT_USER\SOFTWARE\Konnek\<app>\InstallPath`
3. **Fallback Paths**:
   - LlamaCPP: `%LOCALAPPDATA%\Konnek\llama`
   - AgentGateway: `%LOCALAPPDATA%\Programs\Konnek\agentgateway`
   - MCPJungle: `%LOCALAPPDATA%\Programs\Konnek\mcpjungle`

## Building

### Prerequisites
- [AutoIt v3.3.16.1+](https://www.autoitscript.com/site/autoit/)

### Compile
```bash
# Using Aut2exe (included with AutoIt)
Aut2exe.exe /in ServiceManager.au3 /out ServiceManager.exe /x64

# Or right-click ServiceManager.au3 → "Compile Script (x64)"
```

### GitHub Actions
The repository includes a workflow (`.github/workflows/build.yml`) that:
- Installs AutoIt via Chocolatey
- Compiles the script on every push
- Uploads the executable as an artifact
- Creates a release on tag pushes

## Usage

1. Run `ServiceManager.exe` - appears in system tray
2. Right-click tray icon to access menu:
   - **Start All / Stop All** - Control all services at once
   - **Show All / Hide All** - Show/hide all service windows
   - **Service submenus** - Individual Start/Stop/UI/Show/Hide per service
   - **Autostart** - Configure per-service auto-start method
   - **Start on ServiceManager Start** - Choose which services launch with Service Manager
   - **Exit** - Stop all services and exit

### Auto-Start on Launch
Under `Autostart → Start on ServiceManager Start`:
- **All** - Start all three services (default)
- **LlamaCPP HTTP Server** only
- **AgentGateway** only
- **MCPJungle** only
- **LlamaCPP + AgentGateway**
- **LlamaCPP + MCPJungle**
- **AgentGateway + MCPJungle**
- **None** - Don't auto-start any service

Setting persisted to: `%APPDATA%\Konnek\servicemanager\autostart_all.dat`

## Configuration Files

| File | Location | Purpose |
|------|----------|---------|
| `service_pids.dat` | Script directory | Tracks running PIDs |
| `autostart.dat` | Script directory | Per-service auto-start mode |
| `autostart_all.dat` | `%APPDATA%\Konnek\servicemanager\` | Global auto-start on launch bitmask |

## Requirements

- Windows 10/11
- AutoIt 3.3.16.1+ for compilation
- Admin rights required for:
  - Windows Service installation
  - Scheduled Task creation
  - Removing Service/Task entries

## License

MIT License
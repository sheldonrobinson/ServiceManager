Create a Service Manager application

# Service Manager
Service Manager should develop using AutoIt Scripting Language, documented at https://www.autoitscript.com/autoit3/docs/.
Service Manager should start in the systray.
Service Manager should have menu items for each application
1. LlaMA.C++ HTTP Server
   - start cmd: %LOCALAPPDATA%\Programs\Konnek\llamacpp\llama-server.exe
   - Web UI  http://localhost:11434/
2. AgentGateway
   - start cmd: %LOCALAPPDATA%\Programs\Konnek\agentgateway\agentgateway.exe
   - Web UI http://localhost:15000/ui
3. MCPJungle
   - start cmd: %LOCALAPPDATA%\Programs\Konnek\mcpjungle\mcpjungle.exe
   - Web UI http://localhost:8080/

Each application should have a submenu with item for
1. Start - start application using start cmd.  Disable if application is running
2. Stop - stop the application, based on PID. Disable if application is NOT running
3. UI - Open the application admin console. Disable if application is NOT running

Add functionality to
1.  Install/Uninstall and enable/disable application service as one of that following
    - system service managed using `services.msc`
    - scheduled task managed using `taskschd.msc`
    - shortcut in Startup menu folder
These are be mutually exclusive.
Only one type of start item should enable to avoid starting multiple times.
The application should be single instance.
That is, we have enabled system service, then we must disabled scheduled task and remove shortcut from Startup menu folder

# Useful References
1. MinimizeToTray
   - https://github.com/sandwichdoge/MinimizeToTray
   - show how to implement minimize to systray
2. RunAsTI
   - https://github.com/jschicht/RunAsTI
   - shows how to run as privileged process

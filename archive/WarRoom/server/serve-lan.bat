@echo off
rem Same as serve.bat but reachable from phones/tablets on your home network or VPN.
rem Prints a private link (with access key) to open on the other device.
call "%~dp0serve.bat" -Lan %*

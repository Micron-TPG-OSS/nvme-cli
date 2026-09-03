@echo off
rem SPDX-License-Identifier: GPL-2.0-or-later
rem
rem Runs the WinPE batch suites one after the other and reports a combined
rem result.  Every option is passed straight through to both suites, so the
rem usual invocation is:
rem
rem   nvme-run-tests.bat --yes --ns nvme0n1 --ctrl nvme0
rem
rem The suites run in order of what they disturb: the nvme-mi suite reads only,
rem the compare suite leaves the namespace intact, the format suite erases it,
rem and the ns management suite may have to delete namespaces to make room for
rem the one it tests with.

setlocal EnableExtensions

set "HERE=%~dp0"
set "FAILED="

echo.
echo ################ nvme-mi send and receive test ################
call "%HERE%nvme-mi-test.bat" %*
if errorlevel 1 set "FAILED=%FAILED% nvme-mi"

echo.
echo ################ compare command test ################
call "%HERE%nvme-compare-test.bat" %*
if errorlevel 1 set "FAILED=%FAILED% compare"

echo.
echo ################ format nvm test ################
call "%HERE%nvme-format-test.bat" %*
if errorlevel 1 set "FAILED=%FAILED% format"

echo.
echo ################ ns management test ################
call "%HERE%nvme-ns-mgmt-test.bat" %*
if errorlevel 1 set "FAILED=%FAILED% ns-mgmt"

echo.
if not defined FAILED (
	echo ALL SUITES PASSED
	exit /b 0
)
echo SUITES WITH FAILURES:%FAILED%
exit /b 1

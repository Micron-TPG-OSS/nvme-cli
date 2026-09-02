@echo off
rem SPDX-License-Identifier: GPL-2.0-or-later
rem
rem Shared helpers for the WinPE nvme-cli batch suites.
rem
rem Entry points are invoked as:  call "%LIB%" <sub> [args]
rem
rem This file deliberately does not use setlocal: the callers depend on the
rem counters, the parsed identify fields and the command results that it
rem leaves behind in the environment.
rem
rem Parsing is done with for /f over the file rather than with findstr, and
rem substring tests use cmd's own case insensitive substitution. A WinPE image
rem carries no guaranteed set of external tools, and findstr is one of the
rem binaries that can be missing, which turned every parse into a failure.
rem
rem Messages passed to log/case/pass/fail/skip must not contain the characters
rem & | < > ( ) ^ or % - cmd.exe eats them before the helper ever sees them.

if "%~1"=="" exit /b 0
if /i "%~1"=="init"     goto :sub_init
if /i "%~1"=="log"      goto :sub_log
if /i "%~1"=="section"  goto :sub_section
if /i "%~1"=="case"     goto :sub_case
if /i "%~1"=="pass"     goto :sub_pass
if /i "%~1"=="fail"     goto :sub_fail
if /i "%~1"=="skip"     goto :sub_skip
if /i "%~1"=="run"      goto :sub_run
if /i "%~1"=="field"    goto :sub_field
if /i "%~1"=="lbaf"     goto :sub_lbaf
if /i "%~1"=="mkpat"    goto :sub_mkpat
if /i "%~1"=="fsize"    goto :sub_fsize
if /i "%~1"=="filecmp"  goto :sub_filecmp
if /i "%~1"=="textfind" goto :sub_textfind
if /i "%~1"=="mistat"   goto :sub_mistat
if /i "%~1"=="mibytes"  goto :sub_mibytes
if /i "%~1"=="winpe"    goto :sub_winpe
if /i "%~1"=="tools"    goto :sub_tools
if /i "%~1"=="summary"  goto :sub_summary
echo nvme-test-lib: unknown subcommand: %~1
exit /b 1

rem ---------------------------------------------------------------- init ----
rem init <suite-name> <log-file> <work-dir>
:sub_init
set "SUITE=%~2"
set "LOG=%~3"
set "WORK=%~4"
set "CASE_N=0"
set "PASS_N=0"
set "FAIL_N=0"
set "SKIP_N=0"
set "INFO_N=0"
set "CASE_NAME="
set "CMDLINE="
set "EXPECT_TEXT="
set "RC="
if not exist "%WORK%" mkdir "%WORK%" >nul 2>&1
if not exist "%WORK%" (
	echo ERROR: cannot create work directory %WORK%
	exit /b 1
)
> "%LOG%" echo ===== %SUITE% =====
>>"%LOG%" echo started: %DATE% %TIME%
>>"%LOG%" echo work dir: %WORK%
echo ===== %SUITE% =====
echo log: %LOG%
exit /b 0

rem ----------------------------------------------------------------- log ----
:sub_log
set "__next=do_log"
goto :build_msg

:do_log
call :emit "%MSG%"
exit /b 0

:sub_section
set "__next=do_section"
goto :build_msg

:do_section
call :emit ""
call :emit "----- %MSG% -----"
exit /b 0

rem ---------------------------------------------------------------- case ----
:sub_case
set "__next=do_case"
goto :build_msg

:do_case
set /a CASE_N+=1
set "CASE_NAME=%MSG%"
call :emit ""
call :emit "[case %CASE_N%] %CASE_NAME%"
exit /b 0

:sub_pass
set "__next=do_pass"
goto :build_msg

:do_pass
call :mark_pass
exit /b 0

:sub_fail
set "__next=do_fail"
goto :build_msg

:do_fail
call :mark_fail "%MSG%"
exit /b 0

:sub_skip
set "__next=do_skip"
goto :build_msg

:do_skip
set /a SKIP_N+=1
call :emit "  SKIP: %MSG%"
exit /b 0

:mark_pass
set /a PASS_N+=1
call :emit "  PASS"
exit /b 0

:mark_fail
set /a FAIL_N+=1
call :emit "  FAIL: %~1"
exit /b 0

:mark_info
set /a INFO_N+=1
call :emit "  INFO: %~1"
exit /b 0

rem ----------------------------------------------------------------- run ----
rem The command to run is taken from CMDLINE, so that quoting is under the
rem caller's control.  EXPECT_TEXT, when set, must appear in the output.
rem
rem run ok    - command must exit 0
rem run fail  - command must exit non-zero
rem run info  - outcome is recorded but never fails the suite
rem
rem Both CMDLINE and EXPECT_TEXT are cleared before returning.
:sub_run
set "EXPECT=%~2"
if not defined CMDLINE goto :run_no_cmdline
set "OUTF=%WORK%\last-out.txt"
rem CMDLINE is echoed directly: it carries quotes that :emit would mangle.
echo   cmd: %CMDLINE%
if defined LOG >>"%LOG%" echo   cmd: %CMDLINE%
if defined LIST_ONLY goto :run_listed
%CMDLINE% > "%OUTF%" 2>&1
set "RC=%ERRORLEVEL%"
call :emit "  rc: %RC%"
>>"%LOG%" echo   --- output ---
type "%OUTF%" >>"%LOG%" 2>nul
>>"%LOG%" echo.
>>"%LOG%" echo   --- end output ---
if /i "%EXPECT%"=="info" goto :run_info
if /i "%EXPECT%"=="ok" goto :run_want_ok
if /i "%EXPECT%"=="fail" goto :run_want_fail
call :mark_fail "internal error: unknown expectation %EXPECT%"
goto :run_done

:run_want_ok
if not "%RC%"=="0" goto :run_bad_rc
goto :run_check_text

:run_want_fail
if "%RC%"=="0" goto :run_unexpected_ok
goto :run_check_text

:run_check_text
if not defined EXPECT_TEXT goto :run_good
call :text_find "%OUTF%" "%EXPECT_TEXT%"
if defined TEXT_FOUND goto :run_good
goto :run_bad_text

:run_good
call :mark_pass
goto :run_done

:run_bad_rc
call :mark_fail "expected success, exit code was %RC%"
call :dump_output
goto :run_done

:run_unexpected_ok
call :mark_fail "expected failure, command succeeded"
call :dump_output
goto :run_done

:run_bad_text
call :mark_fail "output does not contain: %EXPECT_TEXT%"
call :dump_output
goto :run_done

:run_info
call :mark_info "exit code %RC%"
goto :run_done

:run_listed
set "RC=0"
set /a SKIP_N+=1
call :emit "  SKIP: list mode, command not executed"
goto :run_done

:run_no_cmdline
call :mark_fail "internal error: CMDLINE is not set"
goto :run_done

:run_done
set "CMDLINE="
set "EXPECT_TEXT="
exit /b 0

:dump_output
echo   --- output ---
type "%OUTF%" 2>nul
echo   --- end output ---
exit /b 0

rem --------------------------------------------------------------- field ----
rem field <file> <label> <var>
rem
rem Reads a "label     : value" line as printed by nvme id ctrl / id ns and
rem stores the value, e.g. 0x5f, in <var>.  <var> is left unset when the label
rem is absent.
:sub_field
set "__ff=%~2"
set "__fl=%~3"
set "__fv=%~4"
set "%__fv%="
if not exist "%__ff%" exit /b 1
for /f "usebackq tokens=1,2 delims=:" %%a in ("%__ff%") do (
	set "__fk=%%a"
	set "__fx=%%b"
	call :field_try
)
exit /b 0

:field_try
set "__fk=%__fk: =%"
if /i not "%__fk%"=="%__fl%" exit /b 0
set "__fx=%__fx: =%"
if not defined __fx exit /b 0
set "%__fv%=%__fx%"
exit /b 0

rem ---------------------------------------------------------------- lbaf ----
rem lbaf <id-ns-output-file>
rem
rem Parses the "lbaf  N : ms:M lbads:D rp:R (in use)" line and sets
rem LBAF_INUSE, LBAF_MS, LBAF_DS and BLOCK_SIZE.  LBAF_LINES reports how many
rem lbaf lines were seen, which tells a failed parse apart from a namespace
rem that reports no format in use.  Returns 1 when nothing was parsed.
:sub_lbaf
set "LBAF_INUSE="
set "LBAF_MS="
set "LBAF_DS="
set "BLOCK_SIZE="
set "LBAF_LINES=0"
if not exist "%~2" exit /b 1
for /f "usebackq delims=" %%L in ("%~2") do (
	set "__ll=%%L"
	call :lbaf_try
)
if not defined LBAF_DS exit /b 1
set /a "BLOCK_SIZE=1<<LBAF_DS"
exit /b 0

:lbaf_try
if not "%__ll:~0,5%"=="lbaf " exit /b 0
set /a LBAF_LINES+=1
set "__lu=%__ll:in use=%"
if "%__lu%"=="%__ll%" exit /b 0
for /f "tokens=2,4,6 delims=: " %%a in ("%__ll%") do call :lbaf_store "%%a" "%%b" "%%c"
exit /b 0

:lbaf_store
set "LBAF_INUSE=%~1"
set "LBAF_MS=%~2"
set "LBAF_DS=%~3"
exit /b 0

rem --------------------------------------------------------------- mkpat ----
rem mkpat <file> <digits> <size>
rem
rem Writes a file filled with the repeating <digits> pattern.  The base block
rem is 4096 bytes and is doubled until it reaches <size>, so <size> should be
rem 4096 shifted left by some amount.  The size actually produced is stored in
rem PAT_SIZE.
:sub_mkpat
set "__pf=%~2"
set "__pt=%~3"
set /a "__ps=%~4"
set "PAT_SIZE="
if exist "%__pf%" del /f /q "%__pf%" >nul 2>&1
set "__line=%__pt%"
:mkpat_line
if not "%__line:~63,1%"=="" goto :mkpat_line_done
set "__line=%__line%%__pt%"
goto :mkpat_line

:mkpat_line_done
set "__line=%__line:~0,64%"
for /L %%i in (1,1,64) do >>"%__pf%" <nul set /p "=%__line%"

:mkpat_double
for %%A in ("%__pf%") do set "__cur=%%~zA"
if not defined __cur exit /b 1
if %__cur% GEQ %__ps% goto :mkpat_done
copy /b "%__pf%"+"%__pf%" "%__pf%.tmp" >nul 2>&1
move /y "%__pf%.tmp" "%__pf%" >nul 2>&1
goto :mkpat_double

:mkpat_done
set "PAT_SIZE=%__cur%"
exit /b 0

rem --------------------------------------------------------------- fsize ----
rem fsize <file> <var>
:sub_fsize
set "%~3="
for %%A in ("%~2") do set "%~3=%%~zA"
exit /b 0

rem ------------------------------------------------------------- filecmp ----
rem filecmp <file-a> <file-b>
rem
rem Sets CMP_EQ to 1 when the files hold the same bytes, 0 when they differ and
rem -1 when that could not be decided.  CMP_METHOD names the method that
rem decided it, because the last one in the ladder is not exact:
rem
rem   size     - the sizes differ, no tool needed
rem   fc       - byte exact
rem   hash     - certutil MD5, byte exact
rem   prefix   - the first 1023 bytes only, used when the image has neither fc
rem              nor certutil.  Enough to tell the two generated patterns apart
rem              and to see that a formatted block no longer holds one, which is
rem              all the suites ask of it.
:sub_filecmp
set "CMP_EQ=-1"
set "CMP_METHOD=none"
if not exist "%~2" exit /b 1
if not exist "%~3" exit /b 1
for %%A in ("%~2") do set "__sa=%%~zA"
for %%A in ("%~3") do set "__sb=%%~zA"
if not "%__sa%"=="%__sb%" (
	set "CMP_EQ=0"
	set "CMP_METHOD=size"
	exit /b 0
)
fc /b "%~2" "%~3" >"%WORK%\filecmp-out.txt" 2>&1
set "__cmprc=%ERRORLEVEL%"
if "%__cmprc%"=="0" (
	set "CMP_EQ=1"
	set "CMP_METHOD=fc"
	exit /b 0
)
if "%__cmprc%"=="1" (
	set "CMP_EQ=0"
	set "CMP_METHOD=fc"
	exit /b 0
)
if "%HAVE_CERTUTIL%"=="0" goto :filecmp_prefix
call :hashfile "%~2" __h1
call :hashfile "%~3" __h2
if not defined __h1 goto :filecmp_prefix
if not defined __h2 goto :filecmp_prefix
set "CMP_METHOD=hash"
set "CMP_EQ=0"
if /i "%__h1%"=="%__h2%" set "CMP_EQ=1"
exit /b 0

rem set /p reads at most 1023 characters and stops at the first line feed, so
rem both values stay far below the 8191 character limit a single command line
rem has.  Comparing the whole 4096 byte buffers in one if would exceed it.
:filecmp_prefix
set "__pa="
set "__pb="
set /p "__pa="<"%~2"
set /p "__pb="<"%~3"
if not defined __pa if not defined __pb exit /b 0
set "CMP_METHOD=prefix"
set "CMP_EQ=0"
if "%__pa%"=="%__pb%" set "CMP_EQ=1"
exit /b 0

:hashfile
set "%~2="
for /f "usebackq skip=1 delims=" %%h in (`certutil -hashfile "%~1" MD5 2^>nul`) do call :hash_store "%~2" "%%h"
exit /b 0

:hash_store
if defined %~1 exit /b 0
set "__hv=%~2"
set "__hv=%__hv: =%"
if "%__hv:~31,1%"=="" exit /b 0
set "%~1=%__hv%"
exit /b 0

rem ------------------------------------------------------------ text find ----
rem textfind <file> <text>
rem
rem Sets TEXT_FOUND when <text> occurs in <file>. The comparison is case
rem insensitive, like cmd's substring substitution.
:sub_textfind
call :text_find "%~2" "%~3"
exit /b 0

:text_find
set "TEXT_FOUND="
set "__tw=%~2"
if not exist "%~1" exit /b 0
for /f "usebackq delims=" %%L in ("%~1") do (
	set "__tl=%%L"
	call :text_try
)
exit /b 0

:text_try
if defined TEXT_FOUND exit /b 0
call set "__tr=%%__tl:%__tw%=%%"
if not "%__tr%"=="%__tl%" set "TEXT_FOUND=1"
exit /b 0

rem -------------------------------------------------------------- mistat ----
rem mistat <file>
rem
rem Reads the tunneled NVMe-MI status out of the verbose line that nvme-mi
rem send / recv print:
rem
rem   NVMe-MI Receive Command is Success and result: 0x00000000 (status: 0x00, response: 0x000000)
rem
rem Sets MI_RESULT, MI_STATUS and MI_RESPONSE to the three hex values, which
rem are completion queue entry dword 0, its Tunneled Status field, bits 7:0,
rem and its Tunneled NVMe Management Response field, bits 31:8.  Returns 1
rem when the line is absent, which is what a command that failed below the
rem NVMe-MI layer looks like.
:sub_mistat
set "MI_RESULT="
set "MI_STATUS="
set "MI_RESPONSE="
if not exist "%~2" exit /b 1
for /f "usebackq tokens=7,8,10,12 delims=:(), " %%a in ("%~2") do call :mistat_try "%%a" "%%b" "%%c" "%%d"
if not defined MI_STATUS exit /b 1
exit /b 0

:mistat_try
if defined MI_RESULT exit /b 0
if /i not "%~1"=="result" exit /b 0
set "MI_RESULT=%~2"
set "MI_STATUS=%~3"
set "MI_RESPONSE=%~4"
exit /b 0

rem ------------------------------------------------------------- mibytes ----
rem mibytes <file>
rem
rem Reads the first sixteen response data bytes out of the hex dump that
rem nvme-mi recv prints, into MI_B0 to MI_B15 as two digit hex strings.  Only
rem the line at offset 0000 is taken, so a caller that needs a full line must
rem ask for a data length of at least 16 bytes: a shorter dump pads the row
rem with the ASCII column instead of with bytes.
rem
rem A for body is used rather than the usual per line call because a call can
rem only reach nine arguments and a row carries seventeen tokens.
:sub_mibytes
for /L %%i in (0,1,15) do set "MI_B%%i="
if not exist "%~2" exit /b 1
for /f "usebackq tokens=1-17 delims=: " %%a in ("%~2") do (
	if "%%a"=="0000" (
		set "MI_B0=%%b"
		set "MI_B1=%%c"
		set "MI_B2=%%d"
		set "MI_B3=%%e"
		set "MI_B4=%%f"
		set "MI_B5=%%g"
		set "MI_B6=%%h"
		set "MI_B7=%%i"
		set "MI_B8=%%j"
		set "MI_B9=%%k"
		set "MI_B10=%%l"
		set "MI_B11=%%m"
		set "MI_B12=%%n"
		set "MI_B13=%%o"
		set "MI_B14=%%p"
		set "MI_B15=%%q"
	)
)
if not defined MI_B15 exit /b 1
rem The ASCII column lands in MI_B15 when the row held fewer than 16 bytes.
if not "%MI_B15:~2,1%"=="" exit /b 1
exit /b 0

rem --------------------------------------------------------------- winpe ----
rem Sets IS_WINPE to 1 when running under WinPE.  The registry key is the same
rem one libnvme checks to decide whether a command can be issued through
rem IOCTL_STORAGE_PROTOCOL_COMMAND; an image without reg.exe falls back to the
rem WinPE startup script.
:sub_winpe
set "IS_WINPE=0"
set "WINPE_PROBE=reg"
reg query "HKLM\SYSTEM\CurrentControlSet\Control\MiniNT" >nul 2>&1
set "__wrc=%ERRORLEVEL%"
if "%__wrc%"=="0" (
	set "IS_WINPE=1"
	exit /b 0
)
if not "%__wrc%"=="9009" exit /b 0
set "WINPE_PROBE=startnet"
if exist "%SystemRoot%\System32\startnet.cmd" set "IS_WINPE=1"
exit /b 0

rem --------------------------------------------------------------- tools ----
rem Records which optional external tools this image has.  Nothing depends on
rem them any more, but knowing what is missing makes a failing run readable.
:sub_tools
set "HAVE_FC=1"
set "HAVE_CERTUTIL=1"
set "HAVE_FSUTIL=1"
set "HAVE_REG=1"
set "HAVE_FINDSTR=1"
fc /? >nul 2>&1
if errorlevel 9009 set "HAVE_FC=0"
certutil -? >nul 2>&1
if errorlevel 9009 set "HAVE_CERTUTIL=0"
fsutil >nul 2>&1
if errorlevel 9009 set "HAVE_FSUTIL=0"
reg /? >nul 2>&1
if errorlevel 9009 set "HAVE_REG=0"
findstr /? >nul 2>&1
if errorlevel 9009 set "HAVE_FINDSTR=0"
exit /b 0

rem ------------------------------------------------------------- summary ----
:sub_summary
call :emit ""
call :emit "===== %SUITE% summary ====="
call :emit "  cases: %CASE_N%"
call :emit "  pass : %PASS_N%"
call :emit "  fail : %FAIL_N%"
call :emit "  skip : %SKIP_N%"
call :emit "  info : %INFO_N%"
call :emit "  log  : %LOG%"
if not "%FAIL_N%"=="0" exit /b 1
exit /b 0

rem ---------------------------------------------------------------- utils ----
:emit
echo.%~1
if defined LOG >>"%LOG%" echo.%~1
exit /b 0

rem Recovers the message text from the raw argument string.  Going through %*
rem instead of %1 %2 %3 keeps commas, semicolons and runs of spaces, which
rem cmd.exe treats as argument separators.
:build_msg
set "MSG=%*"
set "__pfx=%~1 "
call set "MSG=%%MSG:*%__pfx%=%%"
if "%MSG%"=="%*" set "MSG="
goto :%__next%

@echo off
rem SPDX-License-Identifier: GPL-2.0-or-later
rem
rem Compare command verification for WinPE.
rem
rem On Windows, Compare (NVM opcode 05h) is only reachable under WinPE, where
rem libnvme submits it through IOCTL_STORAGE_PROTOCOL_COMMAND.  Outside WinPE
rem the same command must be refused with "not supported", which this script
rem also checks.
rem
rem WARNING: the test writes to the namespace and destroys the data in the LBA
rem range it uses, starting at --start-block.

setlocal EnableExtensions

set "LIB=%~dp0nvme-test-lib.bat"
if not exist "%LIB%" (
	echo ERROR: cannot find %LIB%
	exit /b 2
)

rem ------------------------------------------------------------- defaults ----
set "NVME=nvme"
set "NS=nvme0n1"
set "CTRL=nvme0"
set "NSID="
set "SLBA=1023"
set "CONFIRM="
set "LIST_ONLY="
set "BIG="
set "ASSUME_PE="
set "TIMEOUT="
set "OUTROOT=%TEMP%"
if not defined OUTROOT set "OUTROOT=%~dp0."

rem ------------------------------------------------------------ arguments ----
:args
if "%~1"=="" goto :args_done
if /i "%~1"=="--help"        goto :usage
if /i "%~1"=="-h"            goto :usage
if /i "%~1"=="/?"            goto :usage
if /i "%~1"=="--yes"         (set "CONFIRM=1" & shift & goto :args)
if /i "%~1"=="--list"        (set "LIST_ONLY=1" & shift & goto :args)
if /i "%~1"=="--big"         (set "BIG=1" & shift & goto :args)
if /i "%~1"=="--assume-winpe" (set "ASSUME_PE=1" & shift & goto :args)
if /i "%~1"=="--nvme"        (set "NVME=%~2" & shift & shift & goto :args)
if /i "%~1"=="--ns"          (set "NS=%~2" & shift & shift & goto :args)
if /i "%~1"=="--ctrl"        (set "CTRL=%~2" & shift & shift & goto :args)
if /i "%~1"=="--start-block" (set "SLBA=%~2" & shift & shift & goto :args)
if /i "%~1"=="--timeout"     (set "TIMEOUT=%~2" & shift & shift & goto :args)
if /i "%~1"=="--out"         (set "OUTROOT=%~2" & shift & shift & goto :args)
rem Options that belong to the format suite, accepted so that run-all.bat can
rem forward one set of arguments to both suites.
if /i "%~1"=="--skip-crypto"  (shift & goto :args)
if /i "%~1"=="--nsid"         (set "NSID=%~2" & shift & shift & goto :args)
if /i "%~1"=="--alt-lbaf"     (shift & shift & goto :args)
if /i "%~1"=="--verify-block" (shift & shift & goto :args)
echo ERROR: unknown option %~1
goto :usage

:args_done
set "WORK=%OUTROOT%\nvme-compare-test"
set "LOGFILE=%WORK%\nvme-compare-test.log"
set "NVMEQ="%NVME%""
set "GLOBAL="
if defined TIMEOUT set "GLOBAL=--timeout=%TIMEOUT%"

if not defined CONFIRM if not defined LIST_ONLY (
	echo.
	echo This test writes to %NS% and destroys the data in the LBA range
	echo starting at block %SLBA%.  Re-run with --yes to proceed, or with
	echo --list to print the commands without running them.
	echo.
	exit /b 2
)

call "%LIB%" init "compare command test" "%LOGFILE%" "%WORK%"
if errorlevel 1 exit /b 2

call "%LIB%" log device: %NS%
call "%LIB%" log nvme binary: %NVME%
call "%LIB%" log start block: %SLBA%

rem ------------------------------------------------------------- preflight ----
call "%LIB%" section preflight

call "%LIB%" winpe
call "%LIB%" log WinPE detected: %IS_WINPE% probed with: %WINPE_PROBE%
if defined ASSUME_PE (
	set "IS_WINPE=1"
	call "%LIB%" log --assume-winpe given, expecting the WinPE behaviour
)

call "%LIB%" tools
call "%LIB%" log tools present: fc=%HAVE_FC% certutil=%HAVE_CERTUTIL% fsutil=%HAVE_FSUTIL% reg=%HAVE_REG% findstr=%HAVE_FINDSTR%

set "IDCTRL=%WORK%\id-ctrl.txt"
set "IDNS=%WORK%\id-ns.txt"

%NVMEQ% version > "%WORK%\version.txt" 2>&1
type "%WORK%\version.txt" >> "%LOGFILE%" 2>nul
%NVMEQ% list > "%WORK%\list.txt" 2>&1
type "%WORK%\list.txt" >> "%LOGFILE%" 2>nul

call "%LIB%" case identify controller
set "CMDLINE=%NVMEQ% id ctrl %NS%"
set "REDIR=%IDCTRL%"
call :run_to_file
if not "%RC%"=="0" if not defined LIST_ONLY goto :no_device

call "%LIB%" case identify namespace
set "CMDLINE=%NVMEQ% id ns %NS%"
set "REDIR=%IDNS%"
call :run_to_file
if not "%RC%"=="0" if not defined LIST_ONLY goto :no_device

call "%LIB%" field "%IDCTRL%" oncs ONCS
call "%LIB%" field "%IDCTRL%" mdts MDTS
call "%LIB%" field "%IDNS%" flbas FLBAS
call "%LIB%" field "%IDNS%" dps DPS
call "%LIB%" lbaf "%IDNS%"
if not errorlevel 1 goto :lbaf_ok
if not defined LIST_ONLY goto :no_lbaf
set "LBAF_INUSE=0"
set "LBAF_MS=0"
set "LBAF_DS=9"
set "BLOCK_SIZE=512"

:lbaf_ok
rem Fall back to values that keep every case in the plan, for a list mode run on
rem a host that has no device.
if not defined ONCS set "ONCS=0x1"
if not defined MDTS set "MDTS=0"
if not defined FLBAS set "FLBAS=0x0"
if not defined DPS set "DPS=0x0"

set /a "ONCS_D=%ONCS%"
set /a "FLBAS_D=%FLBAS%"
set /a "DPS_D=%DPS%"
set /a "CMP_SUP=ONCS_D & 1"
set /a "META_EXT=(FLBAS_D>>4) & 1"
set /a "PI_ON=DPS_D & 7"

if not defined NSID call :parse_nsid
if not defined NSID set "NSID=1"

call "%LIB%" log namespace id: %NSID%
call "%LIB%" log oncs: %ONCS% compare supported: %CMP_SUP%
call "%LIB%" log lbaf in use: %LBAF_INUSE% block size: %BLOCK_SIZE% metadata size: %LBAF_MS%
call "%LIB%" log flbas: %FLBAS% extended metadata: %META_EXT% dps: %DPS%
call "%LIB%" log mdts: %MDTS%

if "%CMP_SUP%"=="0" (
	call "%LIB%" skip ONCS bit 0 is clear, the controller does not support Compare
	goto :done
)
if not "%PI_ON%"=="0" (
	call "%LIB%" skip namespace has protection information enabled, format it with pi=0 first
	goto :done
)
if "%META_EXT%"=="1" (
	call "%LIB%" skip namespace uses extended metadata, format it to an lbaf with ms=0 first
	goto :done
)

rem ------------------------------------------------------- geometry, files ----
set "SZ1=4096"
if %BLOCK_SIZE% GTR 4096 set "SZ1=%BLOCK_SIZE%"
set /a "B1=SZ1/BLOCK_SIZE"
set /a "BC1=B1-1"
set /a "SZ8=SZ1*8"
set /a "B8=B1*8"
set /a "BC8=B8-1"
set /a "R1=SLBA"
set /a "R2=R1+B1+8"
set /a "R3=R2+B8+8"
set /a "R4=R3+B1+8"
set "SZ2M=2097152"

call "%LIB%" log region 1 single block group at lba %R1% size %SZ1%
call "%LIB%" log region 2 multi block group at lba %R2% size %SZ8%
call "%LIB%" log region 3 single block group at lba %R3% size %SZ1%

set "PA1=%WORK%\pat-a-1.bin"
set "PB1=%WORK%\pat-b-1.bin"
set "PA8=%WORK%\pat-a-8.bin"
set "PMIX=%WORK%\pat-a-8-btail.bin"
set "PBIG=%WORK%\pat-a-big.bin"
set "POVER=%WORK%\pat-a-over.bin"
set "RB=%WORK%\readback.bin"

call "%LIB%" case build pattern files
call "%LIB%" mkpat "%PA1%" 15 %SZ1%
if not "%PAT_SIZE%"=="%SZ1%" goto :pattern_failed
call "%LIB%" mkpat "%PB1%" 25 %SZ1%
if not "%PAT_SIZE%"=="%SZ1%" goto :pattern_failed
call "%LIB%" mkpat "%PA8%" 15 %SZ8%
if not "%PAT_SIZE%"=="%SZ8%" goto :pattern_failed
copy /b "%PA1%"+"%PA1%"+"%PA1%"+"%PA1%"+"%PA1%"+"%PA1%"+"%PA1%"+"%PB1%" "%PMIX%" >nul 2>&1
call "%LIB%" fsize "%PMIX%" MIXSZ
if not "%MIXSZ%"=="%SZ8%" goto :pattern_failed
call "%LIB%" pass

rem Separate metadata buffers are only needed when the namespace has metadata
rem that is not transferred at the end of the LBA.
set "METAW="
set "META1=%WORK%\meta-1.bin"
set "META8=%WORK%\meta-8.bin"
if "%LBAF_MS%"=="0" goto :meta_done
set /a "MS1=LBAF_MS*B1"
set /a "MS8=LBAF_MS*B8"
fsutil file createnew "%META1%" %MS1% >nul 2>&1
fsutil file createnew "%META8%" %MS8% >nul 2>&1
call "%LIB%" fsize "%META1%" HAVE_META
if not defined HAVE_META (
	call "%LIB%" skip namespace has metadata but fsutil could not create a metadata buffer
	goto :done
)
call "%LIB%" log using separate metadata buffers of %MS1% and %MS8% bytes

:meta_done

rem ------------------------------------------------------------ non-WinPE ----
if "%IS_WINPE%"=="1" goto :winpe_cases

call "%LIB%" section compare outside WinPE
call "%LIB%" log Windows only routes Compare through IOCTL_STORAGE_PROTOCOL_COMMAND
call "%LIB%" log under WinPE, so the command must be refused here

call "%LIB%" case compare is rejected outside WinPE
call :meta_args %SZ1% "%META1%"
set "CMDLINE=%NVMEQ% compare %NS% --start-block=%R1% --block-count=%BC1% --data-size=%SZ1% --data="%PA1%" %METAARGS% %GLOBAL%"
set "EXPECT_TEXT=supported"
call "%LIB%" run fail
goto :done

rem -------------------------------------------------------------- WinPE -----
:winpe_cases
call "%LIB%" section compare under WinPE

call "%LIB%" case write pattern A to region 1
call :meta_args %SZ1% "%META1%"
set "CMDLINE=%NVMEQ% write %NS% --start-block=%R1% --block-count=%BC1% --data-size=%SZ1% --data="%PA1%" %METAARGS% --force %GLOBAL%"
call "%LIB%" run ok
if not "%RC%"=="0" goto :write_failed

call "%LIB%" case compare region 1 against the pattern that was written
call :meta_args %SZ1% "%META1%"
set "CMDLINE=%NVMEQ% compare %NS% --start-block=%R1% --block-count=%BC1% --data-size=%SZ1% --data="%PA1%" %METAARGS% %GLOBAL%"
call "%LIB%" run ok

call "%LIB%" case compare region 1 against a different pattern reports a miscompare
call :meta_args %SZ1% "%META1%"
set "CMDLINE=%NVMEQ% compare %NS% --start-block=%R1% --block-count=%BC1% --data-size=%SZ1% --data="%PB1%" %METAARGS% %GLOBAL%"
set "EXPECT_TEXT=Compare Failure"
call "%LIB%" run fail

call "%LIB%" case read region 1 back
if exist "%RB%" del /f /q "%RB%" >nul 2>&1
call :meta_args %SZ1% "%META1%"
set "CMDLINE=%NVMEQ% read %NS% --start-block=%R1% --block-count=%BC1% --data-size=%SZ1% --data="%RB%" %METAARGS% %GLOBAL%"
call "%LIB%" run ok
set "READ_RC=%RC%"

call "%LIB%" case read back data matches pattern A
if defined LIST_ONLY goto :rb_skip
if not "%READ_RC%"=="0" goto :rb_skip
call "%LIB%" filecmp "%PA1%" "%RB%"
call "%LIB%" log   byte compare method: %CMP_METHOD%
if "%CMP_EQ%"=="1" goto :rb_pass
if "%CMP_EQ%"=="0" goto :rb_fail
call "%LIB%" skip neither fc nor certutil is available to compare files
goto :rb_done
:rb_pass
call "%LIB%" pass
goto :rb_done
:rb_fail
call "%LIB%" fail read back data differs from the pattern that compare accepted
goto :rb_done
:rb_skip
call "%LIB%" skip read did not run
:rb_done

call "%LIB%" case fill region 2 with pattern A
call :fill "%PA1%" %R2% 8
call :fill_result
if errorlevel 1 goto :fill_failed

call "%LIB%" case multi block compare of region 2 matches
call :meta_args %SZ8% "%META8%"
set "CMDLINE=%NVMEQ% compare %NS% --start-block=%R2% --block-count=%BC8% --data-size=%SZ8% --data="%PA8%" %METAARGS% %GLOBAL%"
call "%LIB%" run ok

call "%LIB%" case multi block compare with a mismatch in the last block fails
call :meta_args %SZ8% "%META8%"
set "CMDLINE=%NVMEQ% compare %NS% --start-block=%R2% --block-count=%BC8% --data-size=%SZ8% --data="%PMIX%" %METAARGS% %GLOBAL%"
set "EXPECT_TEXT=Compare Failure"
call "%LIB%" run fail

call "%LIB%" case write pattern B to region 3
call :meta_args %SZ1% "%META1%"
set "CMDLINE=%NVMEQ% write %NS% --start-block=%R3% --block-count=%BC1% --data-size=%SZ1% --data="%PB1%" %METAARGS% --force %GLOBAL%"
call "%LIB%" run ok

call "%LIB%" case compare uses the requested start block, pattern A fails at region 3
call :meta_args %SZ1% "%META1%"
set "CMDLINE=%NVMEQ% compare %NS% --start-block=%R3% --block-count=%BC1% --data-size=%SZ1% --data="%PA1%" %METAARGS% %GLOBAL%"
set "EXPECT_TEXT=Compare Failure"
call "%LIB%" run fail

call "%LIB%" case compare uses the requested start block, pattern B matches at region 3
call :meta_args %SZ1% "%META1%"
set "CMDLINE=%NVMEQ% compare %NS% --start-block=%R3% --block-count=%BC1% --data-size=%SZ1% --data="%PB1%" %METAARGS% %GLOBAL%"
call "%LIB%" run ok

call "%LIB%" case compare with force unit access and limited retry
call :meta_args %SZ1% "%META1%"
set "CMDLINE=%NVMEQ% compare %NS% --start-block=%R1% --block-count=%BC1% --data-size=%SZ1% --data="%PA1%" %METAARGS% --force-unit-access --limited-retry --latency %GLOBAL%"
call "%LIB%" run ok

call "%LIB%" case dry run compare never reaches the device
call :meta_args %SZ1% "%META1%"
set "CMDLINE=%NVMEQ% compare %NS% --start-block=%R1% --block-count=%BC1% --data-size=%SZ1% --data="%PB1%" %METAARGS% --dry-run %GLOBAL%"
call "%LIB%" run ok

call "%LIB%" case compare on the controller handle %CTRL%
call "%LIB%" log an IO command needs a namespace handle, the outcome is recorded only
set "CMDLINE=%NVMEQ% compare %CTRL% --namespace-id=%NSID% --start-block=%R1% --block-count=%BC1% --data-size=%SZ1% --data="%PA1%" %GLOBAL%"
call "%LIB%" run info

if not defined BIG goto :big_done

rem The largest compare under test is the smaller of MDTS and the 512 page
rem limit libnvme puts on a protocol command, so the case is meaningful on a
rem drive with a small MDTS as well.
call "%LIB%" section large transfers
set "MAXX=0"
if not "%MDTS%"=="0" set /a "MAXX=4096<<MDTS"
call "%LIB%" log mdts limit in bytes, 0 means unlimited: %MAXX%
set "BIGSZ=%SZ2M%"
if not "%MAXX%"=="0" if %MAXX% LSS %SZ2M% set "BIGSZ=%MAXX%"
if %BIGSZ% GEQ %SZ8% goto :big_ok
call "%LIB%" skip the transfer limit is not larger than the multi block case
goto :big_done

:big_ok
set /a "BIGB=BIGSZ/BLOCK_SIZE"
set /a "BIGBC=BIGB-1"
call "%LIB%" log largest compare under test in bytes: %BIGSZ%
call "%LIB%" mkpat "%PBIG%" 15 %BIGSZ%
if not "%PAT_SIZE%"=="%BIGSZ%" goto :pattern_failed
copy /b "%PBIG%"+"%PA1%" "%POVER%" >nul 2>&1

call "%LIB%" case fill the large region with pattern A
set /a "CHUNKS=BIGSZ/SZ1"
call :fill "%PA1%" %R4% %CHUNKS%
call :fill_result
if errorlevel 1 goto :fill_failed

call "%LIB%" case compare the largest allowed transfer
set "CMDLINE=%NVMEQ% compare %NS% --start-block=%R4% --block-count=%BIGBC% --data-size=%BIGSZ% --data="%PBIG%" %GLOBAL%"
call "%LIB%" run ok

call "%LIB%" case compare above the transfer limit is rejected
call "%LIB%" log rejected either by MDTS or by the 512 page protocol command cap
set /a "SZOVER=BIGSZ+SZ1"
set /a "BCOVER=BIGBC+B1"
set "CMDLINE=%NVMEQ% compare %NS% --start-block=%R4% --block-count=%BCOVER% --data-size=%SZOVER% --data="%POVER%" %GLOBAL%"
call "%LIB%" run fail

:big_done

call "%LIB%" case region 1 still holds pattern A after the failed compares
call :meta_args %SZ1% "%META1%"
set "CMDLINE=%NVMEQ% compare %NS% --start-block=%R1% --block-count=%BC1% --data-size=%SZ1% --data="%PA1%" %METAARGS% %GLOBAL%"
call "%LIB%" run ok

goto :done

rem ------------------------------------------------------------ bail outs ----
:no_device
call "%LIB%" log ERROR: %NS% did not answer identify, check the device name
goto :done

:no_lbaf
call "%LIB%" log lbaf lines seen in %IDNS%: %LBAF_LINES%
call "%LIB%" fail could not parse the LBA format in use out of id ns
goto :done

:pattern_failed
call "%LIB%" fail could not build the pattern files in %WORK%
goto :done

:write_failed
call "%LIB%" log ERROR: the namespace did not accept a write, skipping the rest
goto :done

:fill_failed
call "%LIB%" fail a write returned exit code %FILL_RC% while filling the region
goto :done

:done
call "%LIB%" summary
exit /b %ERRORLEVEL%

rem ------------------------------------------------------------- helpers ----
rem Run CMDLINE with its output redirected to REDIR and report the outcome.
rem These are the read-only queries, so they run in list mode as well: the case
rem plan depends on what the drive reports.  A query that fails in list mode is
rem a skip, so that the plan can still be printed on a host without the device.
:run_to_file
%CMDLINE% > "%REDIR%" 2>&1
set "RC=%ERRORLEVEL%"
echo   cmd: %CMDLINE%
>>"%LOGFILE%" echo   cmd: %CMDLINE%
call "%LIB%" log   rc: %RC%
type "%REDIR%" >> "%LOGFILE%" 2>nul
set "CMDLINE="
if "%RC%"=="0" (
	call "%LIB%" pass
	exit /b 0
)
if defined LIST_ONLY (
	call "%LIB%" skip the query failed, the plan falls back to defaults
	exit /b 0
)
call "%LIB%" fail exit code %RC%
exit /b 0

rem Read the namespace id out of the id ns header line.
:parse_nsid
if not exist "%IDNS%" exit /b 0
for /f "usebackq delims=" %%L in ("%IDNS%") do (
	set "__hl=%%L"
	call :nsid_try
)
exit /b 0

:nsid_try
if defined NSID exit /b 0
if not "%__hl:~0,24%"=="NVME Identify Namespace " exit /b 0
for /f "tokens=4 delims=: " %%a in ("%__hl%") do set "NSID=%%a"
exit /b 0

rem meta_args <data-size> <metadata-file>
rem
rem Builds the metadata options for one IO command, or nothing at all when the
rem namespace has no metadata.
:meta_args
set "METAARGS="
if "%LBAF_MS%"=="0" exit /b 0
set /a "__blocks=%~1/BLOCK_SIZE"
set /a "__msize=LBAF_MS*__blocks"
set "METAARGS=--metadata-size=%__msize% --metadata=%~2"
exit /b 0

rem fill <pattern-file> <start-lba> <chunks>
rem
rem Writes the pattern file, which covers B1 blocks, repeatedly so that large
rem regions are filled without asking the Windows SCSI pass-through path for a
rem transfer it may refuse.  The first non-zero exit code is left in FILL_RC.
:fill
set "FILL_RC=0"
if defined LIST_ONLY (
	echo   cmd: %~3 x %NVMEQ% write %NS% --data="%~1" starting at lba %~2
	exit /b 0
)
set "__lba=%~2"
call :meta_args %SZ1% "%META1%"
for /L %%c in (1,1,%~3) do call :fill_one "%~1"
exit /b 0

rem Reports the outcome of the preceding :fill call.  Returns 1 when a write
rem failed so that the caller can stop.
:fill_result
if defined LIST_ONLY (
	call "%LIB%" skip list mode, writes not executed
	exit /b 0
)
if not "%FILL_RC%"=="0" exit /b 1
call "%LIB%" pass
exit /b 0

:fill_one
if not "%FILL_RC%"=="0" exit /b 0
%NVMEQ% write %NS% --start-block=%__lba% --block-count=%BC1% --data-size=%SZ1% --data="%~1" %METAARGS% --force %GLOBAL% > "%WORK%\fill-out.txt" 2>&1
set "FILL_RC=%ERRORLEVEL%"
if not "%FILL_RC%"=="0" type "%WORK%\fill-out.txt" >> "%LOGFILE%" 2>nul
set /a "__lba=__lba+B1"
exit /b 0

:usage
echo.
echo Usage: nvme-compare-test.bat --yes [options]
echo.
echo   --ns DEV            namespace device, default nvme0n1
echo                       accepts nvme0n1 or a raw path such as
echo                       \\.\PhysicalDrive1
echo   --ctrl DEV          controller device, default nvme0, used by the
echo                       controller handle case only
echo   --nsid N            namespace id, default the one id ns reports
echo   --nvme PATH         nvme binary to test, default nvme from PATH
echo   --start-block N     first LBA the test may overwrite, default 1023
echo   --big               also run the 2 MiB and over sized transfer cases
echo   --assume-winpe      expect the WinPE behaviour even when the MiniNT
echo                       registry key is not there
echo   --timeout MS        pass --timeout to every nvme command
echo   --out DIR           parent directory for the log and work files,
echo                       default the TEMP directory
echo   --list              print the commands without touching the device
echo   --yes               required, confirms that data will be overwritten
echo.
echo The test overwrites the LBA range starting at --start-block.
echo Compare is only supported on Windows under WinPE.
echo.
exit /b 2

@echo off
rem SPDX-License-Identifier: GPL-2.0-or-later
rem
rem Format NVM command verification for WinPE.
rem
rem Under WinPE libnvme submits Format NVM (admin opcode 80h) through
rem IOCTL_STORAGE_PROTOCOL_COMMAND, so every SES value and both the controller
rem and the namespace handle are usable.  Outside WinPE the command is mapped
rem onto IOCTL_SCSI_PASS_THROUGH with SANITIZE for SES=1 and onto
rem IOCTL_STORAGE_REINITIALIZE_MEDIA for SES=2, SES=0 is refused and only
rem namespace handles are accepted.  The script adjusts its expectations to the
rem environment it runs in.
rem
rem WARNING: this test formats the namespace repeatedly.  Every byte of user
rem data on the target namespace is destroyed.

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
set "ALTLBAF="
set "VLBA=0"
set "CONFIRM="
set "LIST_ONLY="
set "SKIP_CRYPTO="
set "ASSUME_PE="
set "TIMEOUT="
set "OUTROOT=%TEMP%"
if not defined OUTROOT set "OUTROOT=%~dp0."

rem ------------------------------------------------------------ arguments ----
:args
if "%~1"=="" goto :args_done
if /i "%~1"=="--help"         goto :usage
if /i "%~1"=="-h"             goto :usage
if /i "%~1"=="/?"             goto :usage
if /i "%~1"=="--yes"          (set "CONFIRM=1" & shift & goto :args)
if /i "%~1"=="--list"         (set "LIST_ONLY=1" & shift & goto :args)
if /i "%~1"=="--skip-crypto"  (set "SKIP_CRYPTO=1" & shift & goto :args)
if /i "%~1"=="--assume-winpe" (set "ASSUME_PE=1" & shift & goto :args)
if /i "%~1"=="--nvme"         (set "NVME=%~2" & shift & shift & goto :args)
if /i "%~1"=="--ns"           (set "NS=%~2" & shift & shift & goto :args)
if /i "%~1"=="--ctrl"         (set "CTRL=%~2" & shift & shift & goto :args)
if /i "%~1"=="--nsid"         (set "NSID=%~2" & shift & shift & goto :args)
if /i "%~1"=="--alt-lbaf"     (set "ALTLBAF=%~2" & shift & shift & goto :args)
if /i "%~1"=="--verify-block" (set "VLBA=%~2" & shift & shift & goto :args)
if /i "%~1"=="--timeout"      (set "TIMEOUT=%~2" & shift & shift & goto :args)
if /i "%~1"=="--out"          (set "OUTROOT=%~2" & shift & shift & goto :args)
rem Options that belong to the compare suite, accepted so that run-all.bat can
rem forward one set of arguments to both suites.
if /i "%~1"=="--big"          (shift & goto :args)
if /i "%~1"=="--no-probe"     (shift & goto :args)
if /i "%~1"=="--skip-io"      (shift & goto :args)
if /i "%~1"=="--start-block"  (shift & shift & goto :args)
if /i "%~1"=="--cntlid"       (shift & shift & goto :args)
if /i "%~1"=="--test-nsze"    (shift & shift & goto :args)
if /i "%~1"=="--probe-max"    (shift & shift & goto :args)
echo ERROR: unknown option %~1
goto :usage

:args_done
set "WORK=%OUTROOT%\nvme-format-test"
set "LOGFILE=%WORK%\nvme-format-test.log"
set "NVMEQ="%NVME%""
set "GLOBAL="
if defined TIMEOUT set "GLOBAL=--timeout=%TIMEOUT%"

if not defined CONFIRM if not defined LIST_ONLY (
	echo.
	echo This test formats %NS% several times and destroys all user data on
	echo that namespace.  Re-run with --yes to proceed, or with --list to
	echo print the commands without running them.
	echo.
	exit /b 2
)

call "%LIB%" init "format nvm test" "%LOGFILE%" "%WORK%"
if errorlevel 1 exit /b 2

call "%LIB%" log namespace device: %NS%
call "%LIB%" log controller device: %CTRL%
call "%LIB%" log nvme binary: %NVME%

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
set "PA1=%WORK%\pat-a.bin"
set "RB=%WORK%\readback.bin"

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

call "%LIB%" field "%IDCTRL%" fna FNA
call "%LIB%" field "%IDCTRL%" nn NN
call "%LIB%" field "%IDNS%" nlbaf NLBAF
if not defined FNA set "FNA=0x0"
if not defined NN set "NN=1"
if not defined NLBAF set "NLBAF=0"

set /a "FNA_D=%FNA%"
set /a "FNA_FMT_ALL=FNA_D & 1"
set /a "FNA_SEC_ALL=(FNA_D>>1) & 1"
set /a "FNA_CES=(FNA_D>>2) & 1"
set /a "FNA_NO_BCAST=(FNA_D>>3) & 1"

call "%LIB%" log fna: %FNA%
call "%LIB%" log format applies to all namespaces: %FNA_FMT_ALL%
call "%LIB%" log secure erase applies to all namespaces: %FNA_SEC_ALL%
call "%LIB%" log crypto erase supported: %FNA_CES%
call "%LIB%" log broadcast nsid not supported: %FNA_NO_BCAST%
if "%FNA_FMT_ALL%%FNA_NO_BCAST%"=="11" call "%LIB%" log WARNING: fna says format applies to all namespaces yet rejects nsid ffffffffh, every format will fail

if not defined NSID call :parse_nsid
if not defined NSID set "NSID=1"
call "%LIB%" log namespace id under test: %NSID%

call :parse_lbaf_table
call :refresh_geometry
if errorlevel 1 goto :no_lbaf
set "BASE_LBAF=%LBAF_INUSE%"
set "BASE_MS=%LBAF_MS%"
set "BASE_BS=%BLOCK_SIZE%"
call "%LIB%" log baseline lbaf: %BASE_LBAF% block size: %BASE_BS% metadata size: %BASE_MS%
call "%LIB%" log highest lbaf index reported: %MAXLBAF%
if defined ALTLBAF call "%LIB%" log alternate lbaf requested on the command line
if not defined ALTLBAF call :pick_alt_lbaf
if defined ALTLBAF call "%LIB%" log alternate lbaf for the reformat cases: %ALTLBAF%
if not defined ALTLBAF call "%LIB%" log no second lbaf with ms=0 is available

set "DATA_CHECKS=1"
if not "%BASE_MS%"=="0" set "DATA_CHECKS="
if defined DATA_CHECKS goto :pattern
call "%LIB%" log baseline lbaf has metadata, the data erase checks are skipped
goto :validation

:pattern
call "%LIB%" case build the pattern file
call "%LIB%" mkpat "%PA1%" 15 %SZ1%
if "%PAT_SIZE%"=="%SZ1%" goto :pattern_ok
call "%LIB%" fail could not build the pattern file in %WORK%
set "DATA_CHECKS="
goto :validation

:pattern_ok
call "%LIB%" pass

rem ----------------------------------------------------- option validation ----
:validation
call "%LIB%" section option validation, nothing is sent to the drive

call "%LIB%" case ses above 7 is rejected
set "CMDLINE=%NVMEQ% format %NS% --namespace-id=%NSID% --ses=8 --force %GLOBAL%"
set "EXPECT_TEXT=invalid secure erase settings"
call "%LIB%" run fail

call "%LIB%" case lbaf above 63 is rejected
set "CMDLINE=%NVMEQ% format %NS% --namespace-id=%NSID% --lbaf=64 --ses=0 --force %GLOBAL%"
set "EXPECT_TEXT=invalid lbaf"
call "%LIB%" run fail

call "%LIB%" case pi above 7 is rejected
set "CMDLINE=%NVMEQ% format %NS% --namespace-id=%NSID% --pi=8 --force %GLOBAL%"
set "EXPECT_TEXT=invalid pi"
call "%LIB%" run fail

call "%LIB%" case pil above 1 is rejected
set "CMDLINE=%NVMEQ% format %NS% --namespace-id=%NSID% --pil=2 --force %GLOBAL%"
set "EXPECT_TEXT=invalid pil"
call "%LIB%" run fail

call "%LIB%" case ms above 1 is rejected
set "CMDLINE=%NVMEQ% format %NS% --namespace-id=%NSID% --ms=2 --force %GLOBAL%"
set "EXPECT_TEXT=invalid mset"
call "%LIB%" run fail

call "%LIB%" case lbaf together with block-size is rejected
set "CMDLINE=%NVMEQ% format %NS% --namespace-id=%NSID% --lbaf=%BASE_LBAF% --block-size=%BASE_BS% --force %GLOBAL%"
set "EXPECT_TEXT=only one"
call "%LIB%" run fail

call "%LIB%" case a block size that is not a power of two is rejected
set "CMDLINE=%NVMEQ% format %NS% --namespace-id=%NSID% --block-size=3000 --force %GLOBAL%"
set "EXPECT_TEXT=power of two"
call "%LIB%" run fail

call "%LIB%" case a block size no lbaf provides is rejected
set "CMDLINE=%NVMEQ% format %NS% --namespace-id=%NSID% --block-size=1048576 --force %GLOBAL%"
set "EXPECT_TEXT=not found"
call "%LIB%" run fail

rem SES=1 is used here on purpose: the SES=0 refusal outside WinPE happens
rem before the dry run short circuit, so only SES=1 exercises dry run in both
rem environments.
call "%LIB%" case dry run format never reaches the device
set "CMDLINE=%NVMEQ% format %NS% --namespace-id=%NSID% --lbaf=%BASE_LBAF% --ses=1 --force --dry-run %GLOBAL%"
call "%LIB%" run ok

rem -------------------------------------------------------- drive rejections ----
call "%LIB%" section rejections by the drive, user data is left alone

if %MAXLBAF% GEQ 63 goto :no_spare_lbaf
set /a "BADLBAF=MAXLBAF+1"
call "%LIB%" case an lbaf the namespace does not report is rejected
set "CMDLINE=%NVMEQ% format %NS% --namespace-id=%NSID% --lbaf=%BADLBAF% --ses=0 --force %GLOBAL%"
call "%LIB%" run fail
goto :bad_nsid

:no_spare_lbaf
call "%LIB%" skip the namespace reports all 64 lba formats, no unused index to try

:bad_nsid
if "%FNA_FMT_ALL%"=="1" goto :rejections_done
call "%LIB%" case a namespace id the controller does not have is rejected
set "CMDLINE=%NVMEQ% format %NS% --namespace-id=0xfffffff0 --lbaf=%BASE_LBAF% --ses=0 --force %GLOBAL%"
call "%LIB%" run fail
goto :rejections_done

:rejections_done
if "%FNA_FMT_ALL%"=="1" call "%LIB%" log fna bit 0 is set, the CLI turns every format into a broadcast format

rem ------------------------------------------------------------ formatting ----
call "%LIB%" section formatting

call "%LIB%" case seed the verification block with a pattern
call :seed_pattern

rem SES=0, no secure erase.  Windows outside WinPE has no IOCTL for this.
call "%LIB%" case format with the lbaf in use and ses=0
set "CMDLINE=%NVMEQ% format %NS% --namespace-id=%NSID% --lbaf=%BASE_LBAF% --ses=0 --force %GLOBAL%"
if "%IS_WINPE%"=="1" goto :fmt_ses0_pe
set "EXPECT_TEXT=supported"
call "%LIB%" run fail
goto :after_ses0

:fmt_ses0_pe
call "%LIB%" run ok
if not "%RC%"=="0" goto :after_ses0
call :verify_erased
call "%LIB%" case the lbaf in use is unchanged after the format
call :assert_lbaf %BASE_LBAF%
call "%LIB%" case the namespace takes IO again after the format
call :io_roundtrip

:after_ses0

rem SES=1, user data erase.  Mapped onto SCSI SANITIZE outside WinPE, so it is
rem expected to work in both environments.
call "%LIB%" case seed the verification block again
call :seed_pattern

call "%LIB%" case format with ses=1, user data erase
set "CMDLINE=%NVMEQ% format %NS% --namespace-id=%NSID% --lbaf=%BASE_LBAF% --ses=1 --force %GLOBAL%"
call "%LIB%" run ok
if not "%RC%"=="0" goto :after_ses1
call :verify_erased
call "%LIB%" case the lbaf in use is unchanged after the user data erase
call :assert_lbaf %BASE_LBAF%

:after_ses1

rem SES=2, cryptographic erase.
if defined SKIP_CRYPTO goto :after_ses2
call "%LIB%" case seed the verification block again
call :seed_pattern

call "%LIB%" case format with ses=2, cryptographic erase
set "CMDLINE=%NVMEQ% format %NS% --namespace-id=%NSID% --lbaf=%BASE_LBAF% --ses=2 --force %GLOBAL%"
if "%FNA_CES%"=="1" goto :fmt_ses2_supported
call "%LIB%" log fna bit 2 is clear, the drive has to reject this
call "%LIB%" run fail
goto :after_ses2

:fmt_ses2_supported
call "%LIB%" run ok
if not "%RC%"=="0" goto :after_ses2
call :verify_erased

:after_ses2
if defined SKIP_CRYPTO call "%LIB%" log crypto erase skipped on request

rem Reformat to a different lbaf and back again.  This needs SES=0, so it only
rem runs under WinPE: the SCSI SANITIZE path used for SES=1 elsewhere carries no
rem lba format at all.
if not defined ALTLBAF goto :after_altlbaf
if "%IS_WINPE%"=="1" goto :altlbaf_cases
call "%LIB%" log lba format changes need ses=0, which is only reachable under WinPE
goto :after_altlbaf

:altlbaf_cases

call "%LIB%" case format to lbaf %ALTLBAF%
set "CMDLINE=%NVMEQ% format %NS% --namespace-id=%NSID% --lbaf=%ALTLBAF% --ses=0 --force %GLOBAL%"
call "%LIB%" run ok
if not "%RC%"=="0" goto :after_altlbaf

call "%LIB%" case the namespace reports lbaf %ALTLBAF% in use
call :assert_lbaf %ALTLBAF%

call "%LIB%" case the namespace takes IO in the new lba format
call :refresh_geometry
call :io_roundtrip

call "%LIB%" case format back to lbaf %BASE_LBAF%
set "CMDLINE=%NVMEQ% format %NS% --namespace-id=%NSID% --lbaf=%BASE_LBAF% --ses=0 --force %GLOBAL%"
call "%LIB%" run ok

call "%LIB%" case the namespace reports lbaf %BASE_LBAF% in use again
call :assert_lbaf %BASE_LBAF%
call :refresh_geometry

:after_altlbaf

rem Broadcast namespace id.
call "%LIB%" case format with the broadcast namespace id
set "CMDLINE=%NVMEQ% format %NS% --namespace-id=0xffffffff --lbaf=%BASE_LBAF% --ses=0 --force %GLOBAL%"
if "%FNA_NO_BCAST%"=="1" goto :bcast_unsupported
if not "%IS_WINPE%"=="1" goto :bcast_no_pe
call "%LIB%" run ok
goto :after_bcast

:bcast_unsupported
call "%LIB%" log fna bit 3 is set, the drive does not accept nsid ffffffffh
call "%LIB%" run fail
goto :after_bcast

:bcast_no_pe
set "EXPECT_TEXT=supported"
call "%LIB%" run fail

:after_bcast

rem The controller handle.  Outside WinPE libnvme requires a namespace handle.
call "%LIB%" case format through the controller handle %CTRL%
set "CMDLINE=%NVMEQ% format %CTRL% --namespace-id=%NSID% --lbaf=%BASE_LBAF% --ses=1 --force %GLOBAL%"
if "%IS_WINPE%"=="1" goto :fmt_ctrl_pe
set "EXPECT_TEXT=supported"
call "%LIB%" run fail
goto :after_ctrl

:fmt_ctrl_pe
call "%LIB%" run ok

:after_ctrl

rem ------------------------------------------------------------ final state ----
call "%LIB%" section final state

call "%LIB%" case the namespace still reports the baseline lbaf
call :assert_lbaf %BASE_LBAF%

call "%LIB%" case the namespace takes IO
call :refresh_geometry
call :io_roundtrip

goto :done

rem ------------------------------------------------------------- bail outs ----
:no_device
call "%LIB%" log ERROR: %NS% did not answer identify, check the device name
goto :done

:no_lbaf
call "%LIB%" log lbaf lines seen in %IDNS%: %LBAF_LINES%
call "%LIB%" fail could not parse the LBA format in use out of id ns
goto :done

:done
call "%LIB%" summary
exit /b %ERRORLEVEL%

rem -------------------------------------------------------------- helpers ----
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

rem Re-read id-ns and recompute the block geometry the IO commands use.
:refresh_geometry
if defined LIST_ONLY goto :geom_defaults
%NVMEQ% id ns %NS% > "%IDNS%" 2>&1
if errorlevel 1 exit /b 1
type "%IDNS%" >> "%LOGFILE%" 2>nul
call "%LIB%" lbaf "%IDNS%"
if errorlevel 1 exit /b 1
set "SZ1=4096"
if %BLOCK_SIZE% GTR 4096 set "SZ1=%BLOCK_SIZE%"
set /a "B1=SZ1/BLOCK_SIZE"
set /a "BC1=B1-1"
exit /b 0

:geom_defaults
set "LBAF_INUSE=0"
set "LBAF_MS=0"
set "BLOCK_SIZE=512"
set "SZ1=4096"
set "B1=8"
set "BC1=7"
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

rem Collect the lbaf table: MAXLBAF is the highest index the namespace reports
rem and LBAF_LIST holds "index:ms:lbads" for every entry.
:parse_lbaf_table
set "MAXLBAF=0"
set "LBAF_LIST="
if not exist "%IDNS%" exit /b 0
for /f "usebackq delims=" %%L in ("%IDNS%") do (
	set "__rl=%%L"
	call :lbaf_row_try
)
call "%LIB%" log lbaf table: %LBAF_LIST%
exit /b 0

:lbaf_row_try
if not "%__rl:~0,5%"=="lbaf " exit /b 0
for /f "tokens=2,4,6 delims=: " %%a in ("%__rl%") do call :lbaf_row "%%a" "%%b" "%%c"
exit /b 0

:lbaf_row
set "LBAF_LIST=%LBAF_LIST% %~1:%~2:%~3"
if %~1 GTR %MAXLBAF% set "MAXLBAF=%~1"
exit /b 0

rem Pick the first lbaf that has no metadata, a different index than the
rem baseline and, when possible, a different block size so that the reformat is
rem observable.
:pick_alt_lbaf
if not defined LBAF_LIST exit /b 0
set "ALT_SAME_BS="
for %%e in (%LBAF_LIST%) do call :alt_candidate "%%e"
if not defined ALTLBAF set "ALTLBAF=%ALT_SAME_BS%"
exit /b 0

:alt_candidate
if defined ALTLBAF exit /b 0
for /f "tokens=1,2,3 delims=:" %%i in ("%~1") do set "__ci=%%i" & set "__cms=%%j" & set "__cds=%%k"
if not "%__cms%"=="0" exit /b 0
if "%__ci%"=="%BASE_LBAF%" exit /b 0
set /a "__cbs=1<<__cds"
if %__cbs% LSS 512 exit /b 0
if "%__cbs%"=="%BASE_BS%" goto :alt_same_bs
set "ALTLBAF=%__ci%"
exit /b 0

:alt_same_bs
if not defined ALT_SAME_BS set "ALT_SAME_BS=%__ci%"
exit /b 0

rem Write the pattern to the verification block.  Failures downgrade the data
rem erase checks instead of failing the suite: the point of the suite is the
rem format command.
:seed_pattern
if not defined DATA_CHECKS (
	call "%LIB%" skip data erase checks are disabled
	exit /b 0
)
set "CMDLINE=%NVMEQ% write %NS% --start-block=%VLBA% --block-count=%BC1% --data-size=%SZ1% --data="%PA1%" --force %GLOBAL%"
call "%LIB%" run ok
exit /b 0

rem Verify that the pattern is gone from the verification block.  A read that
rem fails is reported but not counted as a failure: a deallocated block may be
rem unreadable depending on DLFEAT.
:verify_erased
call "%LIB%" case the pattern is gone from block %VLBA%
if not defined DATA_CHECKS (
	call "%LIB%" skip data erase checks are disabled
	exit /b 0
)
if defined LIST_ONLY (
	call "%LIB%" skip list mode, read not executed
	exit /b 0
)
if exist "%RB%" del /f /q "%RB%" >nul 2>&1
%NVMEQ% read %NS% --start-block=%VLBA% --block-count=%BC1% --data-size=%SZ1% --data="%RB%" %GLOBAL% > "%WORK%\verify-out.txt" 2>&1
set "VRC=%ERRORLEVEL%"
type "%WORK%\verify-out.txt" >> "%LOGFILE%" 2>nul
if "%VRC%"=="0" goto :verify_cmp
call "%LIB%" skip the read returned exit code %VRC%, the block is not readable after the format
exit /b 0

:verify_cmp
call "%LIB%" filecmp "%PA1%" "%RB%"
call "%LIB%" log   byte compare method: %CMP_METHOD%
if "%CMP_EQ%"=="0" goto :verify_pass
if "%CMP_EQ%"=="1" goto :verify_fail
call "%LIB%" skip neither fc nor certutil is available to compare files
exit /b 0

:verify_pass
call "%LIB%" pass
exit /b 0

:verify_fail
call "%LIB%" fail the pattern survived the format
exit /b 0

rem assert_lbaf <expected index>
:assert_lbaf
if defined LIST_ONLY (
	call "%LIB%" skip list mode, id-ns not executed
	exit /b 0
)
%NVMEQ% id ns %NS% > "%IDNS%" 2>&1
set "ARC=%ERRORLEVEL%"
type "%IDNS%" >> "%LOGFILE%" 2>nul
if not "%ARC%"=="0" (
	call "%LIB%" fail id-ns returned exit code %ARC% after the format
	exit /b 0
)
call "%LIB%" lbaf "%IDNS%"
if errorlevel 1 (
	call "%LIB%" fail could not read the lbaf in use out of id-ns
	exit /b 0
)
call "%LIB%" log lbaf in use: %LBAF_INUSE% block size: %BLOCK_SIZE%
if "%LBAF_INUSE%"=="%~1" (
	call "%LIB%" pass
) else (
	call "%LIB%" fail expected lbaf %~1, the namespace reports %LBAF_INUSE%
)
exit /b 0

rem Write the pattern and read it back to prove the namespace is usable.
:io_roundtrip
if not defined DATA_CHECKS (
	call "%LIB%" skip data checks are disabled
	exit /b 0
)
if defined LIST_ONLY (
	call "%LIB%" skip list mode, IO not executed
	exit /b 0
)
%NVMEQ% write %NS% --start-block=%VLBA% --block-count=%BC1% --data-size=%SZ1% --data="%PA1%" --force %GLOBAL% > "%WORK%\rt-out.txt" 2>&1
set "WRC=%ERRORLEVEL%"
type "%WORK%\rt-out.txt" >> "%LOGFILE%" 2>nul
if not "%WRC%"=="0" (
	call "%LIB%" fail write returned exit code %WRC%
	exit /b 0
)
if exist "%RB%" del /f /q "%RB%" >nul 2>&1
%NVMEQ% read %NS% --start-block=%VLBA% --block-count=%BC1% --data-size=%SZ1% --data="%RB%" %GLOBAL% > "%WORK%\rt-out.txt" 2>&1
set "RRC=%ERRORLEVEL%"
type "%WORK%\rt-out.txt" >> "%LOGFILE%" 2>nul
if not "%RRC%"=="0" (
	call "%LIB%" fail read returned exit code %RRC%
	exit /b 0
)
call "%LIB%" filecmp "%PA1%" "%RB%"
call "%LIB%" log   byte compare method: %CMP_METHOD%
if "%CMP_EQ%"=="1" (
	call "%LIB%" pass
	exit /b 0
)
if "%CMP_EQ%"=="0" (
	call "%LIB%" fail the data read back does not match the data written
	exit /b 0
)
call "%LIB%" skip neither fc nor certutil is available to compare files
exit /b 0

:usage
echo.
echo Usage: nvme-format-test.bat --yes [options]
echo.
echo   --ns DEV            namespace device, default nvme0n1
echo                       accepts nvme0n1 or a raw path such as
echo                       \\.\PhysicalDrive1
echo   --ctrl DEV          controller device, default nvme0
echo   --nsid N            namespace id to format, default the one id-ns
echo                       reports for --ns
echo   --alt-lbaf N        lba format to use for the reformat cases, default
echo                       the first other format with ms=0
echo   --verify-block N    LBA used for the data erase checks, default 0
echo   --skip-crypto       do not run the ses=2 cryptographic erase case
echo   --assume-winpe      expect the WinPE behaviour even when the MiniNT
echo                       registry key is not there
echo   --nvme PATH         nvme binary to test, default nvme from PATH
echo   --timeout MS        pass --timeout to every nvme command
echo   --out DIR           parent directory for the log and work files,
echo                       default the TEMP directory
echo   --list              print the commands without touching the device
echo   --yes               required, confirms that the namespace is formatted
echo.
echo Every user data byte on the target namespace is destroyed.
echo.
exit /b 2

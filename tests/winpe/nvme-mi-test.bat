@echo off
rem SPDX-License-Identifier: GPL-2.0-or-later
rem
rem NVMe-MI Send and NVMe-MI Receive verification for WinPE.
rem
rem NVMe-MI Send (admin opcode 1Dh) and NVMe-MI Receive (1Eh) carry the NVMe-MI
rem in-band tunneling mechanism over the admin queue, so no out-of-band MCTP
rem transport is involved.  On Windows both are only reachable under WinPE,
rem where libnvme submits them through IOCTL_STORAGE_PROTOCOL_COMMAND; outside
rem WinPE the same commands must be refused with "not supported", which this
rem script also checks.
rem
rem Nothing here changes the device.  Every NVMe-MI Command that is tunneled
rem via NVMe-MI Receive is a read, and the two tunneled via NVMe-MI Send are
rem encoded so that they select no work: a reserved opcode, a message type that
rem is prohibited in band, a VPD Write of zero bytes, and a Configuration Set
rem whose clear mask is empty.  No --yes is required.
rem
rem Field layouts follow NVM Express Management Interface Specification 1.2c,
rem section 4.3 and figures 59, 61, 66, 75, 78 to 81, 90 to 94 and 100.

setlocal EnableExtensions

set "LIB=%~dp0nvme-test-lib.bat"
if not exist "%LIB%" (
	echo ERROR: cannot find %LIB%
	exit /b 2
)

rem ------------------------------------------------------------- defaults ----
set "NVME=nvme"
set "CTRL=nvme0"
set "NS=nvme0n1"
set "LIST_ONLY="
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
if /i "%~1"=="--list"         (set "LIST_ONLY=1" & shift & goto :args)
if /i "%~1"=="--assume-winpe" (set "ASSUME_PE=1" & shift & goto :args)
if /i "%~1"=="--nvme"         (set "NVME=%~2" & shift & shift & goto :args)
if /i "%~1"=="--ctrl"         (set "CTRL=%~2" & shift & shift & goto :args)
if /i "%~1"=="--ns"           (set "NS=%~2" & shift & shift & goto :args)
if /i "%~1"=="--timeout"      (set "TIMEOUT=%~2" & shift & shift & goto :args)
if /i "%~1"=="--out"          (set "OUTROOT=%~2" & shift & shift & goto :args)
rem Options that belong to the other suites, accepted so that
rem nvme-run-tests.bat can forward one set of arguments to all of them.  This
rem suite reads only, so --yes carries no meaning here.
if /i "%~1"=="--yes"          (shift & goto :args)
if /i "%~1"=="--big"          (shift & goto :args)
if /i "%~1"=="--skip-crypto"  (shift & goto :args)
if /i "%~1"=="--nsid"         (shift & shift & goto :args)
if /i "%~1"=="--start-block"  (shift & shift & goto :args)
if /i "%~1"=="--alt-lbaf"     (shift & shift & goto :args)
if /i "%~1"=="--verify-block" (shift & shift & goto :args)
echo ERROR: unknown option %~1
goto :usage

:args_done
set "WORK=%OUTROOT%\nvme-mi-test"
set "LOGFILE=%WORK%\nvme-mi-test.log"
set "NVMEQ="%NVME%""
set "GLOBAL="
if defined TIMEOUT set "GLOBAL=--timeout=%TIMEOUT%"
set "OUTF=%WORK%\last-out.txt"

rem NVMe-MI Send and Receive are admin commands, so the controller handle is
rem the natural target.  The namespace identifier of a tunneled command is not
rem used and should be cleared to 0h, so --namespace-id is never passed.
set "DEV=%CTRL%"

call "%LIB%" init "nvme-mi send and receive test" "%LOGFILE%" "%WORK%"
if errorlevel 1 exit /b 2

call "%LIB%" log device: %DEV%
call "%LIB%" log nvme binary: %NVME%
call "%LIB%" log this suite does not change the device

rem ------------------------------------------------------------ preflight ----
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

%NVMEQ% version > "%WORK%\version.txt" 2>&1
type "%WORK%\version.txt" >> "%LOGFILE%" 2>nul
%NVMEQ% list > "%WORK%\list.txt" 2>&1
type "%WORK%\list.txt" >> "%LOGFILE%" 2>nul

call "%LIB%" case identify controller
set "CMDLINE=%NVMEQ% id ctrl %DEV%"
set "REDIR=%IDCTRL%"
call :run_to_file
if not "%RC%"=="0" if not defined LIST_ONLY goto :no_device

call "%LIB%" field "%IDCTRL%" oacs OACS
call "%LIB%" field "%IDCTRL%" vwci VWCI
if not defined OACS set "OACS=0x40"
set /a "OACS_D=%OACS%"
set /a "MI_SUP=(OACS_D>>6)&1"

call "%LIB%" log oacs: %OACS%
call "%LIB%" log oacs bit 6, NVMe-MI Send and Receive supported: %MI_SUP%
if defined VWCI call "%LIB%" log vwci: %VWCI%

rem OACS bit 6 clear means the controller does not implement the two admin
rem commands at all, so the only thing left to check is that it says so.
if "%MI_SUP%"=="1" goto :mi_supported

call "%LIB%" section NVMe-MI Send and Receive are not supported
call "%LIB%" log the controller reports oacs bit 6 clear

call "%LIB%" case NVMe-MI Receive is rejected when oacs bit 6 is clear
set "CMDLINE=%NVMEQ% nvme-mi recv %DEV% -v -O 5 -m 1 -0 0 -1 0 %GLOBAL%"
call "%LIB%" run fail
goto :done

:mi_supported
if "%IS_WINPE%"=="1" goto :winpe_cases

rem ------------------------------------------------------------ non-WinPE ----
call "%LIB%" section NVMe-MI Send and Receive outside WinPE
call "%LIB%" log Windows only routes admin opcodes 1Dh and 1Eh through
call "%LIB%" log IOCTL_STORAGE_PROTOCOL_COMMAND under WinPE, so both commands
call "%LIB%" log must be refused here even though the controller supports them

call "%LIB%" case NVMe-MI Receive is rejected outside WinPE
set "CMDLINE=%NVMEQ% nvme-mi recv %DEV% -v -O 5 -m 1 -0 0 -1 0 %GLOBAL%"
set "EXPECT_TEXT=supported"
call "%LIB%" run fail

call "%LIB%" case NVMe-MI Send is rejected outside WinPE
set "CMDLINE=%NVMEQ% nvme-mi send %DEV% -v -O 6 -m 1 -0 0 -1 0 %GLOBAL%"
set "EXPECT_TEXT=supported"
call "%LIB%" run fail
goto :done

rem --------------------------------------------------------------- WinPE ----
:winpe_cases
call "%LIB%" section argument handling

call "%LIB%" case NVMe-MI Receive without an opcode is rejected by nvme-cli
set "CMDLINE=%NVMEQ% nvme-mi recv %DEV% -v -m 1 -0 0 -1 0 %GLOBAL%"
set "EXPECT_TEXT=opcode parameter required"
call "%LIB%" run fail

rem A dry run stops in libnvme before DeviceIoControl, so these two cases check
rem the command that would have been submitted and nothing else.  Command dword
rem 10 holds the NVMe-MI message header: MCTP message type 4h in bits 7:0 and
rem the NVMe-MI message type in bits 14:11.
call "%LIB%" section message header encoding

call "%LIB%" case dry run encodes message type 1h, an NVMe-MI Command
set "CMDLINE=%NVMEQ% nvme-mi recv %DEV% -v -v -O 5 -m 1 -0 0 -1 0 --dry-run %GLOBAL%"
set "EXPECT_TEXT=00000804"
call "%LIB%" run ok

call "%LIB%" case dry run encodes message type 4h, a PCIe Command
set "CMDLINE=%NVMEQ% nvme-mi recv %DEV% -v -v -O 0 -m 4 -0 0 -1 0 --dry-run %GLOBAL%"
set "EXPECT_TEXT=00002004"
call "%LIB%" run ok

rem ---------------------------------------------------------------- reads ----
rem Figure 61 makes three NVMe-MI Commands mandatory in band for an NVMe
rem Storage Device, all of them tunneled via NVMe-MI Receive.
call "%LIB%" section mandatory in band reads

rem A VPD Read of length 0 is explicitly valid and must answer Success with no
rem response data, which makes it the cheapest probe that touches nothing.
call "%LIB%" case NVMe-MI Receive VPD Read with a zero data length
set "CMDLINE=%NVMEQ% nvme-mi recv %DEV% -v -O 5 -m 1 -0 0 -1 0 -l 16 %GLOBAL%"
call "%LIB%" run ok
call :status_case "0x00" "VPD Read of zero bytes reports Success"

call "%LIB%" case NVMe-MI Receive NVM Subsystem Health Status Poll
set "CMDLINE=%NVMEQ% nvme-mi recv %DEV% -v -O 1 -m 1 -0 0 -1 0 -l 16 %GLOBAL%"
call "%LIB%" run ok
call :status_case "0x00" "NVM Subsystem Health Status Poll reports Success"
call :nshds_case

call "%LIB%" case NVMe-MI Receive Controller Health Status Poll
set "CMDLINE=%NVMEQ% nvme-mi recv %DEV% -v -O 2 -m 1 -0 0x81000000 -1 0 -l 16 %GLOBAL%"
call "%LIB%" run ok
call :status_case "0x00" "Controller Health Status Poll reports Success"
call :chds_case

call :temp_case

rem -------------------------------------------------------------- optional ----
rem The optionally supported command list says which of the optional in band
rem commands the drive claims.  Until it has been read the send cases below
rem cannot predict a status, so they start out accepting any.
set "WANT_03=any"
set "WANT_04=any"
set "WANT_06=any"

call "%LIB%" section optional in band reads

call "%LIB%" case NVMe-MI Receive Read NVMe-MI Data Structure, subsystem information
set "CMDLINE=%NVMEQ% nvme-mi recv %DEV% -v -O 0 -m 1 -0 0x00000000 -1 0 -l 32 %GLOBAL%"
call "%LIB%" run ok
call :status_case "any" "the subsystem information read returns a device status"
call :ssinfo_case

call "%LIB%" case NVMe-MI Receive Read NVMe-MI Data Structure, optionally supported command list
set "CMDLINE=%NVMEQ% nvme-mi recv %DEV% -v -O 0 -m 1 -0 0x04000000 -1 0 -l 4096 %GLOBAL%"
call "%LIB%" run ok
call :status_case "any" "the command list read returns a device status"
call :osclist_case

rem Configuration Identifier 02h is the only one that is not prohibited in
rem band, and a Responder that implements Configuration Get shall complete it
rem with Success.
call "%LIB%" case NVMe-MI Receive Configuration Get for Health Status Change
set "CMDLINE=%NVMEQ% nvme-mi recv %DEV% -v -O 4 -m 1 -0 0x02 -1 0 -l 16 %GLOBAL%"
call "%LIB%" run ok
call :status_case "%WANT_04%" "Configuration Get reports the status its command list implies"

rem ---------------------------------------------------------------- sends ----
rem Every NVMe-MI Command tunneled via NVMe-MI Send writes something, so the
rem sends below are chosen to select no work.  They still exercise the whole
rem data out path: opcode 1Dh declares a host to controller transfer, and a
rem request with no request data is the case that needs the zero length data
rem out buffer that submit_storage_protocol_command pads.
call "%LIB%" section sends that select no work

call "%LIB%" case NVMe-MI Send with a reserved NVMe-MI opcode
call "%LIB%" log opcodes 0Dh to BFh are reserved, so no device may implement one
set "CMDLINE=%NVMEQ% nvme-mi send %DEV% -v -O 0x20 -m 1 -0 0 -1 0 %GLOBAL%"
call "%LIB%" run ok
if not "%RC%"=="0" call "%LIB%" log a non zero exit code here means the request never reached the device
if not "%RC%"=="0" call "%LIB%" log check the zero length data out padding in submit_storage_protocol_command
call :status_case "nonzero" "the device rejects the reserved opcode itself"

call "%LIB%" case NVMe-MI Send with a message type prohibited in band
call "%LIB%" log message types 0h, 2h and 4h are all prohibited in band
set "CMDLINE=%NVMEQ% nvme-mi send %DEV% -v -O 0 -m 4 -0 0 -1 0 %GLOBAL%"
call "%LIB%" run ok
call :status_case "nonzero" "the device rejects the prohibited message type"

call "%LIB%" case NVMe-MI Send VPD Write with a zero data length
call "%LIB%" log a VPD Write of length 0 with no data writes nothing
set "CMDLINE=%NVMEQ% nvme-mi send %DEV% -v -O 6 -m 1 -0 0 -1 0 %GLOBAL%"
call "%LIB%" run ok
call :status_case "%WANT_06%" "VPD Write reports the status its command list implies"
if defined VWCI call :vwci_case

call "%LIB%" case NVMe-MI Send Configuration Set with an empty clear mask
call "%LIB%" log dword 1 selects which composite controller status bits to clear
set "CMDLINE=%NVMEQ% nvme-mi send %DEV% -v -O 3 -m 1 -0 0x02 -1 0 %GLOBAL%"
call "%LIB%" run ok
call :status_case "%WANT_03%" "Configuration Set reports the status its command list implies"

rem ------------------------------------------------------------ dispatching ----
call "%LIB%" section command dispatch

call "%LIB%" case the deprecated nvme-mi-recv alias still forwards
set "CMDLINE=%NVMEQ% nvme-mi-recv %DEV% -v -O 5 -m 1 -0 0 -1 0 -l 16 %GLOBAL%"
set "EXPECT_TEXT=deprecated"
call "%LIB%" run ok

call "%LIB%" case the deprecated nvme-mi-send alias still forwards
set "CMDLINE=%NVMEQ% nvme-mi-send %DEV% -v -O 0x20 -m 1 -0 0 -1 0 %GLOBAL%"
set "EXPECT_TEXT=deprecated"
call "%LIB%" run ok

call "%LIB%" case NVMe-MI Receive on the namespace handle %NS%
call "%LIB%" log an admin command reaches the same controller either way, the outcome is recorded only
set "CMDLINE=%NVMEQ% nvme-mi recv %NS% -v -O 5 -m 1 -0 0 -1 0 -l 16 %GLOBAL%"
call "%LIB%" run info

goto :done

rem ------------------------------------------------------------ bail outs ----
:no_device
call "%LIB%" log ERROR: %DEV% did not answer identify, check the device name
goto :done

:done
call "%LIB%" summary
exit /b %ERRORLEVEL%

rem ------------------------------------------------------------- helpers ----
rem Run CMDLINE with its output redirected to REDIR and report the outcome.
rem This is the read-only query the case plan depends on, so it runs in list
rem mode as well and a failure there is a skip.
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

rem status_case <expected> <description>
rem
rem Checks the tunneled NVMe-MI status of the command the preceding run
rem executed.  <expected> is a two digit hex status, "nonzero" for a status
rem that must report an error, or "any" when only the presence of a device
rem generated status matters.
rem
rem This is a case of its own because the two assertions are different: the
rem admin command completing and the tunneled command succeeding.  A tunneled
rem NVMe-MI error is reported as NVMe Successful Completion with the error in
rem completion queue entry dword 0, so nvme-cli exits 0 either way.
:status_case
set "__src=%RC%"
call "%LIB%" case %~2
if defined LIST_ONLY goto :sc_skip_list
if not "%__src%"=="0" goto :sc_skip_rc
call "%LIB%" mistat "%OUTF%"
if not defined MI_STATUS goto :sc_noline
call "%LIB%" log   result %MI_RESULT% tunneled status %MI_STATUS% tunneled response %MI_RESPONSE%
if /i "%~1"=="any" goto :sc_pass
if /i "%~1"=="nonzero" goto :sc_nonzero
if /i "%MI_STATUS%"=="%~1" goto :sc_pass
call "%LIB%" fail expected tunneled status %~1 and the device returned %MI_STATUS%
exit /b 0

:sc_nonzero
set /a "__ss=%MI_STATUS%"
if not "%__ss%"=="0" goto :sc_pass
call "%LIB%" fail the device accepted a request it must reject
exit /b 0

:sc_pass
call "%LIB%" pass
exit /b 0

:sc_noline
call "%LIB%" fail no tunneled status was printed, the command did not reach the NVMe-MI layer
exit /b 0

:sc_skip_rc
call "%LIB%" skip the command exited %__src%, there is no tunneled status to read
exit /b 0

:sc_skip_list
call "%LIB%" skip list mode, the command was not executed
exit /b 0

rem Decodes the NVM Subsystem Health Data Structure of the preceding poll.
rem Byte 0 is the subsystem status, byte 1 the bit inverted SMART critical
rem warning field, byte 2 the temperature in degrees Celsius, byte 3 the
rem percentage of drive life used and bytes 5:4 the composite controller
rem status.
:nshds_case
set "NSHDS_CTEMP="
call "%LIB%" case the NVM Subsystem Health Data Structure decodes
if defined LIST_ONLY goto :sc_skip_list
if not "%RC%"=="0" goto :nshds_skip
call "%LIB%" mibytes "%OUTF%"
if not defined MI_B15 goto :nshds_nodata
set /a "__nss=0x%MI_B0%"
set /a "__df=(__nss>>5)&1"
set /a "__rnr=(__nss>>4)&1"
set /a "__p0=(__nss>>3)&1"
set /a "__p1=(__nss>>2)&1"
set /a "__sw=0x%MI_B1%"
set /a "__ct=0x%MI_B2%"
set /a "__pdlu=0x%MI_B3%"
set /a "__ccs=(0x%MI_B5%<<8)|0x%MI_B4%"
call "%LIB%" log   drive functional %__df% reset not required %__rnr%
call "%LIB%" log   port 0 pcie link active %__p0% port 1 pcie link active %__p1%
call "%LIB%" log   percentage drive life used %__pdlu%
call "%LIB%" log   composite controller status %__ccs%
if not "%__sw%"=="255" call "%LIB%" log   NOTE a SMART critical warning is set, this field is bit inverted so 255 means none
if %__ct% LEQ 126 set "NSHDS_CTEMP=%__ct%"
if defined NSHDS_CTEMP call "%LIB%" log   composite temperature %NSHDS_CTEMP% degrees Celsius
if not defined NSHDS_CTEMP call "%LIB%" log   composite temperature is not reported as a plain Celsius value: %__ct%
if "%__df%"=="1" goto :sc_pass
call "%LIB%" fail the subsystem reports that it is not functional
exit /b 0

:nshds_nodata
call "%LIB%" fail no 16 byte response data row was printed
exit /b 0

:nshds_skip
call "%LIB%" skip the poll did not run
exit /b 0

rem Decodes the Controller Health Data Structure of the preceding poll.  The
rem number of entries is in the tunneled response, bits 23:16.
:chds_case
set "CHDS_CTEMP="
call "%LIB%" case the Controller Health Data Structure decodes and one entry is returned
if defined LIST_ONLY goto :sc_skip_list
if not "%RC%"=="0" goto :nshds_skip
call "%LIB%" mistat "%OUTF%"
call "%LIB%" mibytes "%OUTF%"
if not defined MI_B15 goto :nshds_nodata
if not defined MI_RESPONSE goto :nshds_nodata
set /a "__rent=(%MI_RESPONSE%>>16)&255"
set /a "__ctlid=(0x%MI_B1%<<8)|0x%MI_B0%"
set /a "__csts=(0x%MI_B3%<<8)|0x%MI_B2%"
set /a "__rdy=__csts&1"
set /a "__cfs=(__csts>>1)&1"
set /a "__shst=(__csts>>2)&3"
set /a "__ctk=(0x%MI_B5%<<8)|0x%MI_B4%"
set /a "__pdlu=0x%MI_B6%"
set /a "__spare=0x%MI_B7%"
set /a "__cwarn=0x%MI_B8%"
call "%LIB%" log   response entries %__rent% controller id %__ctlid%
call "%LIB%" log   ready %__rdy% controller fatal status %__cfs% shutdown status %__shst%
call "%LIB%" log   percentage used %__pdlu% available spare %__spare% critical warning %__cwarn%
if %__ctk% GEQ 200 set /a "CHDS_CTEMP=__ctk-273"
if defined CHDS_CTEMP call "%LIB%" log   composite temperature %__ctk% Kelvin, %CHDS_CTEMP% degrees Celsius
if not defined CHDS_CTEMP call "%LIB%" log   composite temperature is not a plausible Kelvin value: %__ctk%
if "%__cfs%"=="1" goto :chds_fatal
if %__rent% GEQ 1 goto :sc_pass
call "%LIB%" fail the poll reported no entries although report all was requested
exit /b 0

:chds_fatal
call "%LIB%" fail the controller reports fatal status, the rest of the run cannot be trusted
exit /b 0

rem Cross checks the two temperatures.  One is reported in Celsius by the
rem subsystem poll and the other in Kelvin by the controller poll, so agreement
rem means both response data transfers landed at the right offset and in the
rem right byte order.
:temp_case
call "%LIB%" case the two health polls agree on the composite temperature
if defined LIST_ONLY goto :sc_skip_list
if not defined NSHDS_CTEMP goto :temp_skip
if not defined CHDS_CTEMP goto :temp_skip
set /a "__d=NSHDS_CTEMP-CHDS_CTEMP"
if %__d% LSS 0 set /a "__d=0-__d"
call "%LIB%" log   subsystem %NSHDS_CTEMP% C controller %CHDS_CTEMP% C difference %__d% C
if %__d% LEQ 5 goto :sc_pass
call "%LIB%" fail the two temperatures disagree by more than 5 degrees
exit /b 0

:temp_skip
call "%LIB%" skip one of the two polls did not report a usable temperature
exit /b 0

rem Decodes the NVM Subsystem Information data structure.  Byte 0 is the number
rem of ports, 0's based, and bytes 1 and 2 are the NVMe-MI version, which the
rem specification fixes at major 1.
:ssinfo_case
call "%LIB%" case the reported NVMe-MI major version is 1
if defined LIST_ONLY goto :sc_skip_list
if not "%RC%"=="0" goto :ssinfo_skip
call "%LIB%" mistat "%OUTF%"
if not "%MI_STATUS%"=="0x00" goto :ssinfo_unsup
call "%LIB%" mibytes "%OUTF%"
if not defined MI_B15 goto :nshds_nodata
set /a "__nump=0x%MI_B0%+1"
set /a "__mjr=0x%MI_B1%"
set /a "__mnr=0x%MI_B2%"
call "%LIB%" log   ports %__nump% NVMe-MI version %__mjr%.%__mnr%
if "%__mjr%"=="1" goto :sc_pass
call "%LIB%" fail the major version must be 1 and the device reported %__mjr%
exit /b 0

:ssinfo_unsup
call "%LIB%" skip the device does not support this data structure in band, status %MI_STATUS%
exit /b 0

:ssinfo_skip
call "%LIB%" skip the read did not run
exit /b 0

rem Decodes the Optionally Supported Command List: bytes 1:0 are the number of
rem commands and each following pair is a command type, whose bits 6:3 hold the
rem message type, and an opcode.  OSC_LIST collects the opcodes of the entries
rem that are NVMe-MI Commands, so that the send cases below can tell an
rem unsupported optional command apart from a broken one.  Only the first row
rem of the dump is read, which covers seven entries.
:osclist_case
set "OSC_LIST="
set "OSC_SEEN=0"
call "%LIB%" case the optionally supported command list decodes
if defined LIST_ONLY goto :sc_skip_list
if not "%RC%"=="0" goto :osc_skip
call "%LIB%" mistat "%OUTF%"
if not "%MI_STATUS%"=="0x00" goto :osc_unsup
call "%LIB%" mibytes "%OUTF%"
if not defined MI_B15 goto :nshds_nodata
set /a "OSC_NUM=(0x%MI_B1%<<8)|0x%MI_B0%"
call "%LIB%" log   commands in the list: %OSC_NUM%
set "OSC_LIST= "
call :osc_one "%MI_B2%" "%MI_B3%"
call :osc_one "%MI_B4%" "%MI_B5%"
call :osc_one "%MI_B6%" "%MI_B7%"
call :osc_one "%MI_B8%" "%MI_B9%"
call :osc_one "%MI_B10%" "%MI_B11%"
call :osc_one "%MI_B12%" "%MI_B13%"
call :osc_one "%MI_B14%" "%MI_B15%"
if %OSC_NUM% GTR 7 call "%LIB%" log   only the first 7 entries were decoded
rem Turn the list into the tunneled status each optional send should report:
rem Success when the drive claims the opcode, Invalid Command Opcode when it
rem published a list without it.  The opcode reaches the substitution as a
rem literal, because cmd pairs the per cent signs before it would expand an
rem argument reference inside one.
set "WANT_03=0x03"
set "WANT_04=0x03"
set "WANT_06=0x03"
call set "__oe=%%OSC_LIST: 03 =%%"
if not "%__oe%"=="%OSC_LIST%" set "WANT_03=0x00"
call set "__oe=%%OSC_LIST: 04 =%%"
if not "%__oe%"=="%OSC_LIST%" set "WANT_04=0x00"
call set "__oe=%%OSC_LIST: 06 =%%"
if not "%__oe%"=="%OSC_LIST%" set "WANT_06=0x00"
call "%LIB%" log   expected send statuses: Configuration Set %WANT_03% Configuration Get %WANT_04% VPD Write %WANT_06%
goto :sc_pass

:osc_unsup
call "%LIB%" skip the device does not support this data structure in band, status %MI_STATUS%
exit /b 0

:osc_skip
call "%LIB%" skip the read did not run
exit /b 0

rem osc_one <type-byte> <opcode-byte>
:osc_one
if %OSC_SEEN% GEQ %OSC_NUM% exit /b 0
set /a "OSC_SEEN+=1"
set /a "__ot=0x%~1"
set /a "__om=(__ot>>3)&15"
call :mi_opname "%~2"
call "%LIB%" log   entry %OSC_SEEN% message type %__om% opcode 0x%~2 %MI_OPNAME%
if not "%__om%"=="1" exit /b 0
set "OSC_LIST=%OSC_LIST%%~2 "
exit /b 0

rem The VPD write cycle budget must not move: a VPD Write of length 0 writes
rem nothing, and the specification only recommends that the VPD survive eight
rem updates.
:vwci_case
call "%LIB%" case the VPD write cycle count did not move
if defined LIST_ONLY goto :sc_skip_list
set "IDCTRL2=%WORK%\id-ctrl-after.txt"
%NVMEQ% id ctrl %DEV% > "%IDCTRL2%" 2>&1
if errorlevel 1 goto :vwci_skip
call "%LIB%" field "%IDCTRL2%" vwci VWCI2
if not defined VWCI2 goto :vwci_skip
call "%LIB%" log   vwci before %VWCI% after %VWCI2%
if /i "%VWCI%"=="%VWCI2%" goto :sc_pass
call "%LIB%" fail a zero length VPD Write consumed a write cycle
exit /b 0

:vwci_skip
call "%LIB%" skip could not read vwci back
exit /b 0

rem mi_opname <opcode-byte>
:mi_opname
set "MI_OPNAME=vendor specific or reserved"
if /i "%~1"=="00" set "MI_OPNAME=Read NVMe-MI Data Structure"
if /i "%~1"=="01" set "MI_OPNAME=NVM Subsystem Health Status Poll"
if /i "%~1"=="02" set "MI_OPNAME=Controller Health Status Poll"
if /i "%~1"=="03" set "MI_OPNAME=Configuration Set"
if /i "%~1"=="04" set "MI_OPNAME=Configuration Get"
if /i "%~1"=="05" set "MI_OPNAME=VPD Read"
if /i "%~1"=="06" set "MI_OPNAME=VPD Write"
if /i "%~1"=="07" set "MI_OPNAME=Reset"
if /i "%~1"=="08" set "MI_OPNAME=SES Receive"
if /i "%~1"=="09" set "MI_OPNAME=SES Send"
if /i "%~1"=="0a" set "MI_OPNAME=Management Endpoint Buffer Read"
if /i "%~1"=="0b" set "MI_OPNAME=Management Endpoint Buffer Write"
if /i "%~1"=="0c" set "MI_OPNAME=Shutdown"
exit /b 0

:usage
echo.
echo Usage: nvme-mi-test.bat [options]
echo.
echo   --ctrl DEV          controller device, default nvme0, the target of
echo                       every NVMe-MI Send and Receive
echo                       accepts nvme0 or a raw path such as
echo                       \\.\PhysicalDrive1
echo   --ns DEV            namespace device, default nvme0n1, used by the
echo                       namespace handle case only
echo   --nvme PATH         nvme binary to test, default nvme from PATH
echo   --assume-winpe      expect the WinPE behaviour even when the MiniNT
echo                       registry key is not there
echo   --timeout MS        pass --timeout to every nvme command
echo   --out DIR           parent directory for the log and work files,
echo                       default the TEMP directory
echo   --list              print the commands without touching the device
echo.
echo The suite reads only and needs no confirmation.  NVMe-MI Send and
echo NVMe-MI Receive are only supported on Windows under WinPE.
echo.
exit /b 2

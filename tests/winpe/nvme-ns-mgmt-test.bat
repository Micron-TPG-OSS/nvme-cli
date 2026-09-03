@echo off
rem SPDX-License-Identifier: GPL-2.0-or-later
rem
rem Namespace Management and Namespace Attachment verification for WinPE.
rem
rem Under WinPE libnvme submits Namespace Management (admin opcode 0Dh) and
rem Namespace Attachment (15h) through IOCTL_STORAGE_PROTOCOL_COMMAND, so ns
rem create, delete, attach and detach are all usable.  Outside WinPE both
rem opcodes are refused with "not supported" before anything reaches the drive.
rem The script adjusts its expectations to the environment it runs in.
rem
rem The namespace layout is recorded before the first change and put back at the
rem end.  Only the layout is restored, never the data: every namespace the
rem script has to delete loses its contents for good.  It deletes as few as it
rem can, so a drive with unallocated capacity keeps all of its namespaces.
rem
rem WARNING: on a drive whose capacity is fully allocated this test deletes
rem namespaces, and it may have to delete all of them.

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
set "CNTLID="
set "TESTNSZE=0x10000"
set "PROBEMAX=64"
set "NOPROBE="
set "SKIPIO="
set "CONFIRM="
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
if /i "%~1"=="--yes"          (set "CONFIRM=1" & shift & goto :args)
if /i "%~1"=="--list"         (set "LIST_ONLY=1" & shift & goto :args)
if /i "%~1"=="--no-probe"     (set "NOPROBE=1" & shift & goto :args)
if /i "%~1"=="--skip-io"      (set "SKIPIO=1" & shift & goto :args)
if /i "%~1"=="--assume-winpe" (set "ASSUME_PE=1" & shift & goto :args)
if /i "%~1"=="--nvme"         (set "NVME=%~2" & shift & shift & goto :args)
if /i "%~1"=="--ns"           (set "NS=%~2" & shift & shift & goto :args)
if /i "%~1"=="--ctrl"         (set "CTRL=%~2" & shift & shift & goto :args)
if /i "%~1"=="--nsid"         (set "NSID=%~2" & shift & shift & goto :args)
if /i "%~1"=="--cntlid"       (set "CNTLID=%~2" & shift & shift & goto :args)
if /i "%~1"=="--test-nsze"    (set "TESTNSZE=%~2" & shift & shift & goto :args)
if /i "%~1"=="--probe-max"    (set "PROBEMAX=%~2" & shift & shift & goto :args)
if /i "%~1"=="--timeout"      (set "TIMEOUT=%~2" & shift & shift & goto :args)
if /i "%~1"=="--out"          (set "OUTROOT=%~2" & shift & shift & goto :args)
rem Options that belong to the other suites, accepted so that nvme-run-tests.bat
rem can forward one set of arguments to all of them.
if /i "%~1"=="--big"          (shift & goto :args)
if /i "%~1"=="--skip-crypto"  (shift & goto :args)
if /i "%~1"=="--start-block"  (shift & shift & goto :args)
if /i "%~1"=="--alt-lbaf"     (shift & shift & goto :args)
if /i "%~1"=="--verify-block" (shift & shift & goto :args)
echo ERROR: unknown option %~1
goto :usage

:args_done
set "WORK=%OUTROOT%\nvme-ns-mgmt-test"
set "LOGFILE=%WORK%\nvme-ns-mgmt-test.log"
set "NVMEQ="%NVME%""
set "GLOBAL="
if defined TIMEOUT set "GLOBAL=--timeout=%TIMEOUT%"

if not defined CONFIRM if not defined LIST_ONLY (
	echo.
	echo This test creates and deletes namespaces on %CTRL%.  On a drive whose
	echo capacity is fully allocated it has to delete existing namespaces to
	echo make room, and it may have to delete all of them.  The layout is
	echo recorded and restored at the end, the data in a deleted namespace is
	echo not.  Re-run with --yes to proceed, or with --list to print the
	echo commands without running them.
	echo.
	exit /b 2
)

call "%LIB%" init "ns management test" "%LOGFILE%" "%WORK%"
if errorlevel 1 exit /b 2

call "%LIB%" log namespace device: %NS%
call "%LIB%" log controller device: %CTRL%
call "%LIB%" log nvme binary: %NVME%
call "%LIB%" log test namespace size in blocks: %TESTNSZE%

set "IDCTRL=%WORK%\id-ctrl.txt"
set "IDNS=%WORK%\id-ns.txt"
set "NSLF=%WORK%\ns-list.txt"
set "NSLFALL=%WORK%\ns-list-all.txt"
set "TMPNS=%WORK%\id-ns-nsid.txt"
set "RESTOREF=%WORK%\ns-restore.txt"
set "LASTOUT=%WORK%\last-out.txt"
set "PA1=%WORK%\pat-a.bin"
set "RB=%WORK%\readback.bin"

rem How many one second tries a wait for Windows gets, both for the controller
rem handle to come back after an attach or a detach and for the namespace list to
rem catch up with the command that changed it.
set "SETTLE_TRIES=10"

set "MODE="
set "DESTROYED="
set "HAVE_TESTNS="
set "RESTORE_BAD="
set "NEWNSID="
set "REC_LIST="
set "REC_MAX=0"
set "REC_COUNT=0"
set "FREED_LIST="
set "ACTIVE_LIST="
set "ALLOC_LIST="
set "CAND_LIST="
set "ALLOC_OK="
set "FORCE_OK="
set "FORCE_TRIED="
set "TRIED_BCAST="
set "TRIED_FALLBACK="
set "CREATE_HEX="

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

%NVMEQ% version > "%WORK%\version.txt" 2>&1
type "%WORK%\version.txt" >> "%LOGFILE%" 2>nul
%NVMEQ% list > "%WORK%\list.txt" 2>&1
type "%WORK%\list.txt" >> "%LOGFILE%" 2>nul

call "%LIB%" case identify controller
set "CMDLINE=%NVMEQ% id ctrl %CTRL%"
set "REDIR=%IDCTRL%"
call :run_to_file
if not "%RC%"=="0" if not defined LIST_ONLY goto :no_device

rem A drive whose namespaces have all been deleted is a legal starting state, so
rem a namespace handle that does not answer is recorded and not a failure.
call "%LIB%" case identify namespace
set "CMDLINE=%NVMEQ% id ns %NS%"
set "REDIR=%IDNS%"
set "MODE=info"
call :run_to_file
set "NS_PRESENT="
if "%RC%"=="0" set "NS_PRESENT=1"
if not defined NS_PRESENT call "%LIB%" log %NS% does not answer identify, the drive may have no namespace at all

call "%LIB%" field "%IDCTRL%" oacs OACS
call "%LIB%" field "%IDCTRL%" nn NN
call "%LIB%" field "%IDCTRL%" cntlid IDCNTLID
call "%LIB%" field "%IDCTRL%" tnvmcap TNVMCAP
call "%LIB%" field "%IDCTRL%" unvmcap UNVMCAP
rem In list mode the identify queries are allowed to fail, and the case plan is
rem the point of the run, so assume the two OACS bits are set.  On a real run an
rem unreadable OACS means the suite stops before it changes anything.
if not defined OACS if defined LIST_ONLY set "OACS=0x18"
if not defined OACS set "OACS=0x0"
if not defined NN set "NN=1"
if not defined CNTLID set "CNTLID=%IDCNTLID%"
if not defined CNTLID set "CNTLID=0"

set /a "OACS_D=%OACS%"
set /a "NSMGMT=(OACS_D>>3) & 1"
set /a "NSATT=(OACS_D>>4) & 1"

call "%LIB%" log oacs: %OACS%
call "%LIB%" log namespace management supported: %NSMGMT%
call "%LIB%" log namespace attachment supported: %NSATT%
call "%LIB%" log controller id: %CNTLID%
call "%LIB%" log maximum number of namespaces: %NN%
call "%LIB%" log total nvm capacity: %TNVMCAP%
call "%LIB%" log unallocated nvm capacity: %UNVMCAP%

call :parse_primary_nsid
if not defined PRIMARY_NSID set "PRIMARY_NSID=%NSID%"
if not defined PRIMARY_NSID set "PRIMARY_NSID=1"
call "%LIB%" log primary namespace id: %PRIMARY_NSID%

call "%LIB%" lbaf "%IDNS%"
if errorlevel 1 call :geom_defaults
call "%LIB%" log baseline lbaf: %LBAF_INUSE% block size: %BLOCK_SIZE% metadata size: %LBAF_MS%

rem Every create passes the flbas field the primary namespace reports rather
rem than the lba format index: the field also carries the extended metadata bit
rem and the high bits of the index, so it is what reproduces the same format.
call "%LIB%" field "%IDNS%" flbas BASE_FLBAS
if not defined BASE_FLBAS set "BASE_FLBAS=0x0"
call "%LIB%" log flbas in use: %BASE_FLBAS%

set "SZ1=4096"
if %BLOCK_SIZE% GTR 4096 set "SZ1=%BLOCK_SIZE%"
set /a "B1=SZ1/BLOCK_SIZE"
set /a "BC1=B1-1"

rem ------------------------------------------------------ option validation ----
call "%LIB%" section option validation, nothing is sent to the drive

call "%LIB%" case attach without a namespace id is rejected
set "CMDLINE=%NVMEQ% ns attach %CTRL% --controllers=%CNTLID% %GLOBAL%"
set "EXPECT_TEXT=namespace-id parameter required"
call "%LIB%" run fail

call "%LIB%" case detach without a namespace id is rejected
set "CMDLINE=%NVMEQ% ns detach %CTRL% --controllers=%CNTLID% %GLOBAL%"
set "EXPECT_TEXT=namespace-id parameter required"
call "%LIB%" run fail

call "%LIB%" case attach on a namespace handle is rejected
set "CMDLINE=%NVMEQ% ns attach %NS% --namespace-id=%PRIMARY_NSID% --controllers=%CNTLID% %GLOBAL%"
set "EXPECT_TEXT=a namespace device opened"
call "%LIB%" run fail

call "%LIB%" case detach on a namespace handle is rejected
set "CMDLINE=%NVMEQ% ns detach %NS% --namespace-id=%PRIMARY_NSID% --controllers=%CNTLID% %GLOBAL%"
set "EXPECT_TEXT=a namespace device opened"
call "%LIB%" run fail

call "%LIB%" case a controller id list that does not parse is rejected
set "CMDLINE=%NVMEQ% ns attach %CTRL% --namespace-id=%PRIMARY_NSID% --controllers=70000 %GLOBAL%"
set "EXPECT_TEXT=controller id list is malformed"
call "%LIB%" run fail

call "%LIB%" case flbas together with block-size is rejected
set "CMDLINE=%NVMEQ% ns create %CTRL% --nsze=%TESTNSZE% --ncap=%TESTNSZE% --flbas=%BASE_FLBAS% --block-size=%BLOCK_SIZE% %GLOBAL%"
set "EXPECT_TEXT=please specify only one"
call "%LIB%" run fail

call "%LIB%" case a block size that is not a power of two is rejected
set "CMDLINE=%NVMEQ% ns create %CTRL% --nsze=%TESTNSZE% --ncap=%TESTNSZE% --block-size=3000 %GLOBAL%"
set "EXPECT_TEXT=power of two"
call "%LIB%" run fail

call "%LIB%" case create without flbas or block-size is rejected
set "CMDLINE=%NVMEQ% ns create %CTRL% --nsze=%TESTNSZE% --ncap=%TESTNSZE% %GLOBAL%"
set "EXPECT_TEXT=not found"
call "%LIB%" run fail

call "%LIB%" case a zoned namespace option on a non zoned namespace is rejected
set "CMDLINE=%NVMEQ% ns create %CTRL% --nsze=%TESTNSZE% --ncap=%TESTNSZE% --flbas=%BASE_FLBAS% --azr %GLOBAL%"
set "EXPECT_TEXT=Invalid ZNS argument"
call "%LIB%" run fail

call "%LIB%" case a placement handle count without the handles is rejected
set "CMDLINE=%NVMEQ% ns create %CTRL% --nsze=%TESTNSZE% --ncap=%TESTNSZE% --flbas=%BASE_FLBAS% --nphndls=2 %GLOBAL%"
set "EXPECT_TEXT=Invalid Placement handle list"
call "%LIB%" run fail

rem ------------------------------------------------------- support and env ----
if "%NSMGMT%%NSATT%"=="11" goto :env_check

call "%LIB%" section the controller does not support namespace management
call "%LIB%" log oacs bit 3, namespace management: %NSMGMT%
call "%LIB%" log oacs bit 4, namespace attachment: %NSATT%
call "%LIB%" log every namespace management command has to be refused

call "%LIB%" case create is refused
set "CMDLINE=%NVMEQ% ns create %CTRL% --nsze=%TESTNSZE% --ncap=%TESTNSZE% --flbas=%BASE_FLBAS% --verbose %GLOBAL%"
set "EXPECT_TEXT=not supported"
call "%LIB%" run fail
call :refuse_cases
goto :done

:env_check
if "%IS_WINPE%"=="1" goto :record

call "%LIB%" section outside WinPE namespace management is refused
call "%LIB%" log libnvme returns ENOTSUP before the command is submitted, so the drive is never reached

call "%LIB%" case create is refused
set "CMDLINE=%NVMEQ% ns create %CTRL% --nsze=%TESTNSZE% --ncap=%TESTNSZE% --flbas=%BASE_FLBAS% --verbose %GLOBAL%"
set "EXPECT_TEXT=not supported"
call "%LIB%" run fail
call :refuse_cases

call "%LIB%" case a dry run create is refused as well
set "CMDLINE=%NVMEQ% ns create %CTRL% --nsze=%TESTNSZE% --ncap=%TESTNSZE% --flbas=%BASE_FLBAS% --dry-run %GLOBAL%"
set "EXPECT_TEXT=not supported"
call "%LIB%" run fail

call "%LIB%" case a dry run delete is refused as well
set "CMDLINE=%NVMEQ% ns delete %CTRL% --namespace-id=0xfffffff0 --dry-run %GLOBAL%"
set "EXPECT_TEXT=not supported"
call "%LIB%" run fail

call "%LIB%" log the ENOTSUP check precedes the dry run short circuit, so --dry-run cannot exit zero here
goto :done

rem ---------------------------------------------------------------- record ----
:record
call "%LIB%" section record the original namespace layout

call "%LIB%" case read the active namespace list
set "CMDLINE=%NVMEQ% id ns-list %CTRL% %GLOBAL%"
set "REDIR=%NSLF%"
call :run_to_file
if not "%RC%"=="0" if not defined LIST_ONLY goto :no_inventory
call :parse_ns_list "%NSLF%"
set "ACTIVE_LIST=%PLIST%"
call "%LIB%" log active namespaces:%ACTIVE_LIST%
call "%LIB%" log namespaces in the active list: %PCOUNT%

call "%LIB%" case read the allocated namespace list
set "CMDLINE=%NVMEQ% id ns-list %CTRL% --all %GLOBAL%"
set "REDIR=%NSLFALL%"
set "MODE=info"
call :run_to_file
if not "%RC%"=="0" goto :no_alloc_list
call :parse_ns_list "%NSLFALL%"
set "ALLOC_LIST=%PLIST%"
set "ALLOC_OK=1"
call "%LIB%" log allocated namespaces:%ALLOC_LIST%
goto :probe_force

:no_alloc_list
call "%LIB%" log the allocated namespace list, identify CNS 10h, is not available on this host

rem An active namespace is the reference for the probe: CNS 11h has to report the
rem same namespace CNS 00h does.
:probe_force
call "%LIB%" case identify allocated namespace, CNS 11h, is available
if not defined ACTIVE_LIST goto :force_no_reference
for %%n in (%ACTIVE_LIST%) do call :force_probe %%n
if defined FORCE_OK goto :force_yes
call "%LIB%" skip CNS 11h is not available, an unattached namespace cannot be read without attaching it
goto :record_active

:force_no_reference
call "%LIB%" skip the drive has no active namespace to test CNS 11h with
goto :record_active

:force_yes
call "%LIB%" pass

:record_active
if defined LIST_ONLY call "%LIB%" log list mode, the configuration of each namespace is not read
for %%n in (%ACTIVE_LIST%) do call :record_active_one %%n

call :build_cand_list
if not defined CAND_LIST goto :inactive_none
if defined FORCE_OK goto :inactive_force
if defined NOPROBE goto :inactive_noprobe
goto :inactive_attach

:inactive_force
call "%LIB%" log reading the namespaces that are allocated but not attached with CNS 11h
for %%n in (%CAND_LIST%) do call :inactive_force_one %%n
goto :inactive_done

:inactive_attach
call "%LIB%" log without CNS 11h the configuration of an unattached namespace cannot be read
call "%LIB%" log so every candidate namespace id is probed with attach and detached again
call "%LIB%" log candidate namespace ids:%CAND_LIST%
for %%n in (%CAND_LIST%) do call :inactive_attach_one %%n
goto :inactive_done

:inactive_noprobe
call "%LIB%" log WARNING: --no-probe was given and the allocated namespace list is not available
call "%LIB%" log WARNING: a namespace that is allocated but not attached cannot be seen, and would not be restored
goto :inactive_done

:inactive_none
call "%LIB%" log every namespace id the drive could hold is either active or outside the probe range

:inactive_done
call :build_rec_list
call "%LIB%" log recorded namespaces:%REC_LIST%
call "%LIB%" log recorded namespace count: %REC_COUNT%
call :check_contiguous
call :write_restore_file
call "%LIB%" log restore commands written to %RESTOREF%
type "%RESTOREF%" 2>nul
type "%RESTOREF%" >> "%LOGFILE%" 2>nul

rem --------------------------------------------------------------- dry run ----
call "%LIB%" section dry run, nothing is submitted to the drive

call "%LIB%" case a dry run create reaches no drive
set "CMDLINE=%NVMEQ% ns create %CTRL% --nsze=%TESTNSZE% --ncap=%TESTNSZE% --flbas=%BASE_FLBAS% --dry-run %GLOBAL%"
call "%LIB%" run ok

call "%LIB%" case a dry run delete reaches no drive
set "CMDLINE=%NVMEQ% ns delete %CTRL% --namespace-id=%PRIMARY_NSID% --dry-run %GLOBAL%"
call "%LIB%" run ok

call "%LIB%" case a dry run attach reaches no drive
set "CMDLINE=%NVMEQ% ns attach %CTRL% --namespace-id=%PRIMARY_NSID% --controllers=%CNTLID% --dry-run %GLOBAL%"
call "%LIB%" run ok

call "%LIB%" case a dry run detach reaches no drive
set "CMDLINE=%NVMEQ% ns detach %CTRL% --namespace-id=%PRIMARY_NSID% --controllers=%CNTLID% --dry-run %GLOBAL%"
call "%LIB%" run ok

if not defined NS_PRESENT goto :dry_run_ish
call "%LIB%" case a dry run delete on the namespace handle looks the namespace id up
set "CMDLINE=%NVMEQ% ns delete %NS% --dry-run --verbose %GLOBAL%"
call "%LIB%" run ok

:dry_run_ish
call "%LIB%" case ignore shutdown is rejected outside NVMe-MI
set "CMDLINE=%NVMEQ% ns delete %CTRL% --namespace-id=%PRIMARY_NSID% --ish --dry-run %GLOBAL%"
set "EXPECT_TEXT=only for NVMe-MI"
call "%LIB%" run ok

call "%LIB%" case the active namespace list is unchanged after the dry runs
call :assert_active_list

rem ------------------------------------------------- test namespace capacity ----
call "%LIB%" section create the test namespace

call "%LIB%" case a namespace larger than the drive is rejected
set "CMDLINE=%NVMEQ% ns create %CTRL% --nsze=0x7fffffffffff --ncap=0x7fffffffffff --flbas=%BASE_FLBAS% --verbose %GLOBAL%"
call "%LIB%" run fail
if defined LIST_ONLY goto :acquire_start
if not "%RC%"=="0" goto :acquire_start

rem A drive that accepts this has taken the whole capacity and nothing after it
rem could work, so undo it before going on.
set "OVERNSID="
call "%LIB%" field "%LASTOUT%" nsid OVERNSID
if not defined OVERNSID goto :acquire_start
call "%LIB%" log the drive created it, deleting namespace %OVERNSID% again
call "%LIB%" case delete the namespace the drive should not have created
set "DESTROYED=1"
set "CMDLINE=%NVMEQ% ns delete %CTRL% --namespace-id=%OVERNSID% --verbose %GLOBAL%"
call "%LIB%" run ok

:acquire_start
set "CREATE_NSZE=%TESTNSZE%"

:acquire_try
call :hexnorm "%CREATE_NSZE%" CREATE_HEX
if /i not "%CREATE_NSZE:~0,2%"=="0x" set "CREATE_HEX="
call "%LIB%" case create a namespace of %CREATE_NSZE% blocks
set "CMDLINE=%NVMEQ% ns create %CTRL% --nsze=%CREATE_NSZE% --ncap=%CREATE_NSZE% --flbas=%BASE_FLBAS% --verbose %GLOBAL%"
call "%LIB%" run info
if "%RC%"=="0" goto :acquire_ok
call "%LIB%" log the create failed, freeing the highest allocated namespace and trying again
call :free_highest
if errorlevel 1 goto :acquire_last_resort
goto :acquire_try

:acquire_last_resort
if defined FREE_FAILED goto :acquire_fallback_size
if defined TRIED_BCAST goto :acquire_fallback_size
set "TRIED_BCAST=1"
call "%LIB%" log no recorded namespace is left to free, deleting every namespace the drive has
call "%LIB%" case delete every namespace with the broadcast namespace id
set "DESTROYED=1"
set "CMDLINE=%NVMEQ% ns delete %CTRL% --namespace-id=0xffffffff --verbose %GLOBAL%"
call "%LIB%" run ok
for %%n in (%REC_LIST%) do call :mark_freed %%n
goto :acquire_try

:acquire_fallback_size
if defined TRIED_FALLBACK goto :acquire_failed
set "TRIED_FALLBACK=1"
call :getns %PRIMARY_NSID% NSZE PNSZE
if not defined PNSZE goto :acquire_failed
if "%PNSZE%"=="%CREATE_NSZE%" goto :acquire_failed
call "%LIB%" log trying again with the size the primary namespace had: %PNSZE%
set "CREATE_NSZE=%PNSZE%"
goto :acquire_try

:acquire_failed
call "%LIB%" case a test namespace could be created
call "%LIB%" fail the controller refused every create, the log holds the status of each one
goto :restore

:acquire_ok
call "%LIB%" case the create reported the new namespace id
if defined LIST_ONLY goto :acquire_listed
call "%LIB%" field "%LASTOUT%" nsid NEWNSID
if not defined NEWNSID goto :no_new_nsid
if "%NEWNSID%"=="0" goto :no_new_nsid
set "HAVE_TESTNS=1"
set "DESTROYED=1"
call "%LIB%" log test namespace id: %NEWNSID%
call "%LIB%" pass

call "%LIB%" case the new namespace does not collide with a surviving namespace
call :is_surviving %NEWNSID%
if defined SURVIVING goto :nsid_clash
call "%LIB%" pass
goto :matrix

rem The namespace id the controller would assign is not known without running
rem the create, so the plan uses the first one.
:acquire_listed
set "NEWNSID=1"
call "%LIB%" skip list mode, the namespace id the controller would return is not known

call "%LIB%" case the new namespace does not collide with a surviving namespace
call "%LIB%" skip list mode, no namespace was created

:matrix

rem ---------------------------------------------------------------- matrix ----
call "%LIB%" section create attach detach delete on namespace %NEWNSID%

call "%LIB%" case create leaves the namespace unattached
call :assert_ns_inactive %NEWNSID%

call "%LIB%" case identify allocated namespace reports the new namespace
if not defined FORCE_OK goto :no_force_size
if defined LIST_ONLY goto :no_force_size
call :read_ns %NEWNSID% --force
if not defined R_OK goto :force_size_bad
call :assert_sizes
goto :attach_cases

:force_size_bad
call "%LIB%" fail identify allocated namespace failed for the namespace that was just created
goto :attach_cases

:no_force_size
call "%LIB%" skip CNS 11h is not available, the size is checked after the attach instead

:attach_cases
call "%LIB%" case attach the namespace to controller %CNTLID%
set "CMDLINE=%NVMEQ% ns attach %CTRL% --namespace-id=%NEWNSID% --controllers=%CNTLID% --verbose %GLOBAL%"
call "%LIB%" run ok
if not "%RC%"=="0" goto :matrix_bail
call :settle

call "%LIB%" case the attached namespace reports the size it was created with
call :assert_ns_active %NEWNSID%

call "%LIB%" case the controller list for the namespace
set "CMDLINE=%NVMEQ% id ctrl-list %CTRL% --namespace-id=%NEWNSID% %GLOBAL%"
call "%LIB%" run info

call "%LIB%" case attaching an already attached namespace
set "CMDLINE=%NVMEQ% ns attach %CTRL% --namespace-id=%NEWNSID% --controllers=%CNTLID% --verbose %GLOBAL%"
call "%LIB%" run info
call "%LIB%" log the specification asks for Namespace Already Attached here, drives differ, so this is recorded only

call :io_section

call "%LIB%" case detach the namespace from controller %CNTLID%
set "CMDLINE=%NVMEQ% ns detach %CTRL% --namespace-id=%NEWNSID% --controllers=%CNTLID% --verbose %GLOBAL%"
call "%LIB%" run ok
call :settle

call "%LIB%" case the detached namespace is no longer active
call :assert_ns_inactive %NEWNSID%

call "%LIB%" case detaching an already detached namespace
set "CMDLINE=%NVMEQ% ns detach %CTRL% --namespace-id=%NEWNSID% --controllers=%CNTLID% --verbose %GLOBAL%"
call "%LIB%" run info
call "%LIB%" log the specification asks for Namespace Not Attached here, drives differ, so this is recorded only

rem No --controllers, so nvme-cli fills the list from the cntlid that identify
rem controller reports.  The attach also proves the namespace is still
rem allocated, which is what makes the rejected attach after the delete below
rem mean something.
call "%LIB%" case attach again with the controller list taken from identify controller
set "CMDLINE=%NVMEQ% ns attach %CTRL% --namespace-id=%NEWNSID% --verbose %GLOBAL%"
call "%LIB%" run ok
call :settle

call "%LIB%" case the namespace is active again
call :assert_ns_active %NEWNSID%

call "%LIB%" case detach before the delete
set "CMDLINE=%NVMEQ% ns detach %CTRL% --namespace-id=%NEWNSID% --controllers=%CNTLID% --verbose %GLOBAL%"
call "%LIB%" run ok
call :settle

call "%LIB%" case attach a controller id the subsystem does not have
set "CMDLINE=%NVMEQ% ns attach %CTRL% --namespace-id=%NEWNSID% --controllers=65534 --verbose %GLOBAL%"
call "%LIB%" run fail

rem Delete carries no data, which is the case that needs the zero length
rem data-out padding in submit_storage_protocol_command().
call "%LIB%" case delete the namespace
set "CMDLINE=%NVMEQ% ns delete %CTRL% --namespace-id=%NEWNSID% --verbose %GLOBAL%"
call "%LIB%" run ok
if "%RC%"=="0" set "HAVE_TESTNS="

call "%LIB%" case deleting the same namespace again is rejected
set "CMDLINE=%NVMEQ% ns delete %CTRL% --namespace-id=%NEWNSID% --verbose %GLOBAL%"
call "%LIB%" run fail

rem The same attach succeeded above while the namespace was merely detached, so
rem a rejection here is what tells a deleted namespace from a detached one.
rem Identify answers success with a zero filled structure for both, and the
rem allocated namespace list is not available on Windows.
call "%LIB%" case attaching the deleted namespace is rejected
set "CMDLINE=%NVMEQ% ns attach %CTRL% --namespace-id=%NEWNSID% --controllers=%CNTLID% --verbose %GLOBAL%"
call "%LIB%" run fail

rem Only when the drive holds nothing this run wants to keep, so that the
rem broadcast delete cannot destroy a namespace the suite deliberately preserved.
call "%LIB%" case delete every namespace with the broadcast namespace id
if defined TRIED_BCAST goto :bcast_covered
call :count_survivors
if %SURV_COUNT% GTR 0 goto :bcast_skip
set "CMDLINE=%NVMEQ% ns delete %CTRL% --namespace-id=0xffffffff --verbose %GLOBAL%"
call "%LIB%" run info
goto :restore

:bcast_skip
call "%LIB%" skip the drive still holds %SURV_COUNT% namespaces this run kept, a broadcast delete would destroy them
goto :restore

:bcast_covered
call "%LIB%" skip a broadcast delete already ran while capacity was being freed
goto :restore

:matrix_bail
call "%LIB%" log the attach failed, the remaining cases are skipped
goto :restore

rem --------------------------------------------------------------- restore ----
:restore
call "%LIB%" section restore the original namespace layout
if defined LIST_ONLY goto :restore_listed
if defined HAVE_TESTNS goto :restore_testns
if defined DESTROYED goto :restore_recreate
call "%LIB%" log nothing was deleted, the original layout is untouched
goto :restore_verify

:restore_testns
call "%LIB%" case detach the test namespace
set "CMDLINE=%NVMEQ% ns detach %CTRL% --namespace-id=%NEWNSID% --controllers=%CNTLID% %GLOBAL%"
call "%LIB%" run info
call :settle
call "%LIB%" case delete the test namespace
set "CMDLINE=%NVMEQ% ns delete %CTRL% --namespace-id=%NEWNSID% --verbose %GLOBAL%"
call "%LIB%" run ok
if "%RC%"=="0" set "HAVE_TESTNS="
if defined HAVE_TESTNS set "RESTORE_BAD=1"

:restore_recreate
if "%REC_MAX%"=="0" goto :restore_verify
if defined FREED_LIST call "%LIB%" log namespaces that were deleted:%FREED_LIST%
call "%LIB%" log putting back every namespace this run changed
for /L %%n in (1,1,%REC_MAX%) do call :restore_ns %%n

:restore_verify
if not defined DESTROYED goto :restore_checks
call "%LIB%" case reset the controller so Windows enumerates the namespaces again
set "CMDLINE=%NVMEQ% reset %CTRL% %GLOBAL%"
call "%LIB%" run info

:restore_checks
call "%LIB%" case the active namespace list matches the recorded one
call :assert_active_list

call "%LIB%" case the primary namespace reports its recorded size again
call :assert_primary

if defined RESTORE_BAD goto :restore_manual
goto :done

:restore_manual
call "%LIB%" log ERROR: the namespace layout could not be restored completely
call "%LIB%" log ERROR: rebuild it by hand with the commands in %RESTOREF%
type "%RESTOREF%" 2>nul
type "%RESTOREF%" >> "%LOGFILE%" 2>nul
goto :done

:restore_listed
call "%LIB%" log list mode, nothing was changed and nothing has to be restored
goto :done

rem ------------------------------------------------------------- bail outs ----
:no_device
call "%LIB%" log ERROR: %CTRL% did not answer identify, check the device name
goto :done

:no_inventory
call "%LIB%" fail the active namespace list cannot be read, there is no safe record to restore from
goto :done

:no_new_nsid
call "%LIB%" fail the create succeeded but reported no namespace id, so the suite cannot tell which namespace is its own
call "%LIB%" log ERROR: a namespace was created and cannot be identified
call "%LIB%" log ERROR: the create output is in the log, remove that namespace by hand
set "RESTORE_BAD=1"
set "HAVE_TESTNS="
goto :restore

:nsid_clash
call "%LIB%" fail the controller returned namespace id %NEWNSID%, which is one of the namespaces that were kept
call "%LIB%" log ERROR: stopping before anything else is changed, the namespace id parse or the drive is wrong
set "HAVE_TESTNS="
set "RESTORE_BAD=1"
goto :restore

:done
call "%LIB%" summary
exit /b %ERRORLEVEL%

rem --------------------------------------------------------------- helpers ----
rem Run CMDLINE with its output redirected to REDIR and report the outcome.
rem MODE is "info" when a failure is only recorded, empty when it fails the
rem suite.  These are the read-only queries, so they run in list mode as well:
rem the case plan depends on what the drive reports.  A query that fails in list
rem mode is a skip, so that the plan can still be printed without the device.
:run_to_file
%CMDLINE% > "%REDIR%" 2>&1
set "RC=%ERRORLEVEL%"
echo   cmd: %CMDLINE%
>>"%LOGFILE%" echo   cmd: %CMDLINE%
call "%LIB%" log   rc: %RC%
type "%REDIR%" >> "%LOGFILE%" 2>nul
set "CMDLINE="
if "%RC%"=="0" goto :run_to_file_pass
if defined LIST_ONLY goto :run_to_file_listed
if /i "%MODE%"=="info" goto :run_to_file_info
call "%LIB%" fail exit code %RC%
set "MODE="
exit /b 0

:run_to_file_pass
call "%LIB%" pass
set "MODE="
exit /b 0

:run_to_file_listed
call "%LIB%" skip the query failed, the plan falls back to defaults
set "MODE="
exit /b 0

:run_to_file_info
call "%LIB%" skip exit code %RC%
set "MODE="
exit /b 0

rem The three commands that follow the create in every refusal section.
:refuse_cases
call "%LIB%" case delete is refused
set "CMDLINE=%NVMEQ% ns delete %CTRL% --namespace-id=0xfffffff0 --verbose %GLOBAL%"
set "EXPECT_TEXT=not supported"
call "%LIB%" run fail

call "%LIB%" case attach is refused
set "CMDLINE=%NVMEQ% ns attach %CTRL% --namespace-id=0xfffffff0 --controllers=%CNTLID% --verbose %GLOBAL%"
set "EXPECT_TEXT=not supported"
call "%LIB%" run fail

call "%LIB%" case detach is refused
set "CMDLINE=%NVMEQ% ns detach %CTRL% --namespace-id=0xfffffff0 --controllers=%CNTLID% --verbose %GLOBAL%"
set "EXPECT_TEXT=not supported"
call "%LIB%" run fail
exit /b 0

rem The block geometry used by the IO round trip when id-ns could not be read.
:geom_defaults
set "LBAF_INUSE=0"
set "LBAF_MS=0"
set "BLOCK_SIZE=512"
call "%LIB%" log the lba format in use could not be read, assuming lbaf 0 with 512 byte blocks
exit /b 0

rem Read the namespace id the namespace handle stands for out of ns get-id,
rem which prints "nvme0n1: namespace-id:1".
:parse_primary_nsid
set "PRIMARY_NSID="
if not defined NS_PRESENT exit /b 0
%NVMEQ% ns get-id %NS% %GLOBAL% > "%WORK%\get-id.txt" 2>&1
if errorlevel 1 exit /b 0
type "%WORK%\get-id.txt" >> "%LOGFILE%" 2>nul
for /f "usebackq tokens=3 delims=:" %%a in ("%WORK%\get-id.txt") do call :primary_try "%%a"
exit /b 0

:primary_try
if defined PRIMARY_NSID exit /b 0
set "__pv=%~1"
set "__pv=%__pv: =%"
if not defined __pv exit /b 0
set "PRIMARY_NSID=%__pv%"
exit /b 0

rem parse_ns_list <file>
rem
rem Reads the "[   0]:0x1" rows that nvme id ns-list prints and stores the
rem namespace ids as decimal in PLIST, with PCOUNT holding how many there were.
rem The header line carries no second token, so for /f skips it.
:parse_ns_list
set "PLIST="
set "PCOUNT=0"
if not exist "%~1" exit /b 1
for /f "usebackq tokens=2 delims=:" %%a in ("%~1") do call :ns_list_add "%%a"
exit /b 0

:ns_list_add
set "__nv=%~1"
set "__nv=%__nv: =%"
if not defined __nv exit /b 0
if /i not "%__nv:~0,2%"=="0x" exit /b 0
set "__nd="
set /a "__nd=%__nv%" >nul 2>&1
if not defined __nd exit /b 0
if "%__nd%"=="0" exit /b 0
set "PLIST=%PLIST% %__nd%"
set /a PCOUNT+=1
exit /b 0

rem in_list <value> <list>
:in_list
set "IN_LIST="
for %%i in (%~2) do if "%%i"=="%~1" set "IN_LIST=1"
exit /b 0

rem cmp_lists <list-a> <list-b> - sets LISTS_EQ when both hold the same ids
:cmp_lists
set "LISTS_EQ=1"
for %%i in (%~1) do call :cmp_have "%~2" %%i
for %%i in (%~2) do call :cmp_have "%~1" %%i
exit /b 0

:cmp_have
call :in_list %~2 "%~1"
if not defined IN_LIST set "LISTS_EQ="
exit /b 0

rem hexnorm <value> <var> - strips a 0x prefix and any leading zeros so that two
rem hex strings for the same number compare equal
:hexnorm
set "__hn=%~1"
if /i "%__hn:~0,2%"=="0x" set "__hn=%__hn:~2%"
:hexnorm_strip
if "%__hn:~1%"=="" goto :hexnorm_done
if not "%__hn:~0,1%"=="0" goto :hexnorm_done
set "__hn=%__hn:~1%"
goto :hexnorm_strip

:hexnorm_done
set "%~2=%__hn%"
exit /b 0

rem getns <nsid> <field> <var> - copies the recorded NS<nsid>_<field>
:getns
set "%~3="
call set "%~3=%%NS%~1_%~2%%"
exit /b 0

rem is_surviving <nsid> - set SURVIVING when the nsid belongs to a recorded
rem namespace that was not deleted by this run
:is_surviving
set "SURVIVING="
if not defined NS%~1_STATE exit /b 0
if defined NS%~1_FREED exit /b 0
set "SURVIVING=1"
exit /b 0

rem How many of the recorded namespaces this run has not deleted.
:count_survivors
set "SURV_COUNT=0"
for %%n in (%REC_LIST%) do call :survivor_count %%n
exit /b 0

:survivor_count
call :is_surviving %~1
if defined SURVIVING set /a SURV_COUNT+=1
exit /b 0

rem mark_freed <nsid>
:mark_freed
if not defined NS%~1_STATE exit /b 0
if defined NS%~1_FREED exit /b 0
set "NS%~1_FREED=1"
set "FREED_LIST=%FREED_LIST% %~1"
exit /b 0

rem read_ns <nsid> [--force]
rem
rem Runs identify namespace for one namespace id and stores the fields in R_*.
rem R_OK is set when the query worked.  An identify for a namespace id that is
rem not active answers success with a zero filled structure, so R_NSZE being 0
rem means "not attached to this controller" and nothing more: it does not tell
rem an unallocated namespace from an allocated one that is detached.  Only
rem CNS 11h, --force, can tell those apart.
:read_ns
set "R_OK="
set "R_NSZE="
set "R_NCAP="
set "R_FLBAS="
set "R_DPS="
set "R_NMIC="
if defined LIST_ONLY exit /b 1
%NVMEQ% id ns %CTRL% --namespace-id=%~1 %~2 %GLOBAL% > "%TMPNS%" 2>&1
set "NRC=%ERRORLEVEL%"
type "%TMPNS%" >> "%LOGFILE%" 2>nul
if "%NRC%"=="0" goto :read_ns_parse
rem The controller handle may be gone for a moment after an attach or a detach.
call :settle
%NVMEQ% id ns %CTRL% --namespace-id=%~1 %~2 %GLOBAL% > "%TMPNS%" 2>&1
set "NRC=%ERRORLEVEL%"
type "%TMPNS%" >> "%LOGFILE%" 2>nul
if not "%NRC%"=="0" exit /b 1

:read_ns_parse
call "%LIB%" field "%TMPNS%" nsze R_NSZE
call "%LIB%" field "%TMPNS%" ncap R_NCAP
call "%LIB%" field "%TMPNS%" flbas R_FLBAS
call "%LIB%" field "%TMPNS%" dps R_DPS
call "%LIB%" field "%TMPNS%" nmic R_NMIC
if not defined R_NSZE exit /b 1
if not defined R_NCAP set "R_NCAP=0"
if not defined R_FLBAS set "R_FLBAS=0"
if not defined R_DPS set "R_DPS=0"
if not defined R_NMIC set "R_NMIC=0"
set "R_OK=1"
exit /b 0

rem store_ns <nsid> <active or inactive> - records the R_* values just read and
rem appends the commands that would rebuild this namespace to the restore file
:store_ns
set "NS%~1_NSZE=%R_NSZE%"
set "NS%~1_NCAP=%R_NCAP%"
set "NS%~1_FLBAS=%R_FLBAS%"
set "NS%~1_DPS=%R_DPS%"
set "NS%~1_NMIC=%R_NMIC%"
set "NS%~1_STATE=%~2"
set /a REC_COUNT+=1
if %~1 GTR %REC_MAX% set "REC_MAX=%~1"
call "%LIB%" log namespace %~1 is %~2, nsze %R_NSZE% ncap %R_NCAP% flbas %R_FLBAS% dps %R_DPS% nmic %R_NMIC%
exit /b 0

rem The commands that rebuild the recorded layout by hand, for the case where
rem the restore at the end of the run does not manage it.  They have to be in
rem ascending namespace id order: create takes no namespace id, the controller
rem assigns the lowest one that is free.
:write_restore_file
> "%RESTOREF%" echo rem Commands that rebuild the namespace layout recorded by
>>"%RESTOREF%" echo rem nvme-ns-mgmt-test.bat.  Run them in this order.
>>"%RESTOREF%" echo rem controller: %CTRL%  controller id: %CNTLID%
if "%REC_MAX%"=="0" exit /b 0
for /L %%n in (1,1,%REC_MAX%) do call :restore_line %%n
exit /b 0

:restore_line
if not defined NS%~1_STATE exit /b 0
call :getns %~1 NSZE LNSZE
call :getns %~1 NCAP LNCAP
call :getns %~1 FLBAS LFLBAS
call :getns %~1 DPS LDPS
call :getns %~1 NMIC LNMIC
call :getns %~1 STATE LSTATE
>>"%RESTOREF%" echo rem namespace %~1, %LSTATE%
>>"%RESTOREF%" echo %NVMEQ% ns create %CTRL% --nsze=%LNSZE% --ncap=%LNCAP% --flbas=%LFLBAS% --dps=%LDPS% --nmic=%LNMIC% --verbose
if /i "%LSTATE%"=="active" >>"%RESTOREF%" echo %NVMEQ% ns attach %CTRL% --namespace-id=%~1 --controllers=%CNTLID% --verbose
exit /b 0

:record_active_one
if defined LIST_ONLY exit /b 0
call :read_ns %~1
if defined R_OK goto :record_active_store
call "%LIB%" case record namespace %~1
call "%LIB%" fail identify namespace failed for an active namespace id
exit /b 0

:record_active_store
call :store_ns %~1 active
exit /b 0

rem Decide whether identify allocated namespace works, using the first active
rem namespace id as the reference.
:force_probe
if defined FORCE_TRIED exit /b 0
set "FORCE_TRIED=1"
call :read_ns %~1 --force
if not defined R_OK exit /b 0
if "%R_NSZE%"=="0" exit /b 0
set "FORCE_OK=1"
exit /b 0

rem The namespace ids that may hold a namespace that is allocated but not
rem attached: the allocated list when the drive gives one, otherwise every id up
rem to nn, capped by --probe-max.
:build_cand_list
set "CAND_LIST="
if defined LIST_ONLY exit /b 0
if defined ALLOC_OK goto :cand_from_alloc
set "SCAN_MAX=%NN%"
if %SCAN_MAX% GTR %PROBEMAX% set "SCAN_MAX=%PROBEMAX%"
if %NN% GTR %PROBEMAX% call "%LIB%" log the drive can hold %NN% namespaces, only the first %PROBEMAX% are probed
for /L %%n in (1,1,%SCAN_MAX%) do call :cand_add %%n
exit /b 0

:cand_from_alloc
for %%n in (%ALLOC_LIST%) do call :cand_add %%n
exit /b 0

:cand_add
call :in_list %~1 "%ACTIVE_LIST%"
if defined IN_LIST exit /b 0
set "CAND_LIST=%CAND_LIST% %~1"
exit /b 0

:inactive_force_one
call :read_ns %~1 --force
if not defined R_OK exit /b 0
if "%R_NSZE%"=="0" exit /b 0
call :store_ns %~1 inactive
exit /b 0

rem An attach that succeeds means the namespace was allocated all along, so its
rem configuration is read while it is attached and it is detached again right
rem away.  An attach that fails means the namespace id holds nothing.
:inactive_attach_one
%NVMEQ% ns attach %CTRL% --namespace-id=%~1 --controllers=%CNTLID% %GLOBAL% > "%WORK%\probe-out.txt" 2>&1
if errorlevel 1 exit /b 0
type "%WORK%\probe-out.txt" >> "%LOGFILE%" 2>nul
call "%LIB%" log namespace %~1 is allocated but was not attached
call :settle
call :read_ns %~1
if defined R_OK call :store_ns %~1 inactive
call "%LIB%" case detach namespace %~1 again after the probe
set "CMDLINE=%NVMEQ% ns detach %CTRL% --namespace-id=%~1 --controllers=%CNTLID% --verbose %GLOBAL%"
call "%LIB%" run ok
call :settle
exit /b 0

rem Rebuild REC_LIST in ascending namespace id order, which is the order the
rem restore has to recreate them in.
:build_rec_list
set "REC_LIST="
if "%REC_MAX%"=="0" exit /b 0
for /L %%n in (1,1,%REC_MAX%) do call :rec_append %%n
exit /b 0

:rec_append
if not defined NS%~1_STATE exit /b 0
set "REC_LIST=%REC_LIST% %~1"
exit /b 0

rem A namespace id the controller assigns on create is the lowest one that is
rem free, so only a set that runs from 1 without gaps can be put back exactly.
:check_contiguous
if "%REC_MAX%"=="0" exit /b 0
set "REC_GAP="
for /L %%n in (1,1,%REC_MAX%) do call :gap_check %%n
if not defined REC_GAP exit /b 0
call "%LIB%" log WARNING: the recorded namespace ids are not contiguous from 1
call "%LIB%" log WARNING: create assigns the lowest free namespace id, so the restore cannot reproduce the original ids
exit /b 0

:gap_check
if not defined NS%~1_STATE set "REC_GAP=1"
exit /b 0

rem free_highest
rem
rem Deletes the highest recorded namespace that is still there, detaching it
rem first when it is attached.  Highest first keeps the namespaces that survive
rem contiguous, so recreating the deleted ones in ascending order gives them
rem their original namespace ids back.  Returns 1 when nothing is left to free.
:free_highest
set "FREE_NSID="
for %%n in (%REC_LIST%) do call :free_pick %%n
if not defined FREE_NSID exit /b 1
call :getns %FREE_NSID% STATE FSTATE
if /i not "%FSTATE%"=="active" goto :free_delete

call "%LIB%" case detach namespace %FREE_NSID% to free capacity
set "DESTROYED=1"
set "CMDLINE=%NVMEQ% ns detach %CTRL% --namespace-id=%FREE_NSID% --controllers=%CNTLID% --verbose %GLOBAL%"
call "%LIB%" run ok
if "%RC%"=="0" set "NS%FREE_NSID%_DETACHED=1"
call :settle

:free_delete
call "%LIB%" case delete namespace %FREE_NSID% to free capacity
set "DESTROYED=1"
set "CMDLINE=%NVMEQ% ns delete %CTRL% --namespace-id=%FREE_NSID% --verbose %GLOBAL%"
call "%LIB%" run ok
if not "%RC%"=="0" goto :free_delete_bad
call :mark_freed %FREE_NSID%
exit /b 0

rem A delete the controller refuses is not a reason to reach for the broadcast
rem namespace id: something about this namespace is different, and deleting
rem every namespace on the drive would be a much larger step than the one that
rem just failed.
:free_delete_bad
set "FREE_FAILED=1"
call "%LIB%" log the delete failed, no more capacity can be freed
exit /b 1

:free_pick
if defined NS%~1_FREED exit /b 0
if not defined FREE_NSID goto :free_pick_take
if %~1 GTR %FREE_NSID% goto :free_pick_take
exit /b 0

:free_pick_take
set "FREE_NSID=%~1"
exit /b 0

rem assert_ns_inactive <nsid>
rem
rem The active namespace list is what decides this.  The zero filled identify
rem only corroborates it, because a namespace that is allocated and detached
rem looks exactly the same as one that does not exist.
rem
rem The list is polled rather than read once: Windows removes the disk it had
rem enumerated for the namespace asynchronously, so the view can lag the command
rem that changed it by a moment.
:assert_ns_inactive
if defined LIST_ONLY goto :assert_listed
set "ATRY=0"

:inactive_poll
set /a ATRY+=1
call :refresh_active
if not defined ACT_OK goto :inactive_again
call :in_list %~1 "%ACT_LIST%"
if not defined IN_LIST goto :inactive_gone

:inactive_again
if %ATRY% GEQ %SETTLE_TRIES% goto :inactive_gave_up
call "%LIB%" wait 1
goto :inactive_poll

:inactive_gone
call "%LIB%" log namespace %~1 is absent from %ACT_SOURCE%
call :read_ns %~1
if not defined R_OK goto :inactive_no_id
if not "%R_NSZE%"=="0" goto :inactive_nonzero
call "%LIB%" pass
exit /b 0

:inactive_gave_up
if not defined ACT_OK goto :assert_no_list
call "%LIB%" fail namespace %~1 is still in %ACT_SOURCE%
exit /b 0

:inactive_no_id
call "%LIB%" fail identify namespace failed for namespace id %~1
exit /b 0

:inactive_nonzero
call "%LIB%" fail nsze for the inactive namespace %~1 is %R_NSZE% and not zero
exit /b 0

rem assert_ns_active <nsid> - the namespace is in the active list and reports
rem the size and format it was created with.  Polled for the same reason as
rem assert_ns_inactive above.
:assert_ns_active
if defined LIST_ONLY goto :assert_listed
set "ATRY=0"

:active_poll
set /a ATRY+=1
call :refresh_active
if not defined ACT_OK goto :active_again
call :in_list %~1 "%ACT_LIST%"
if defined IN_LIST goto :active_there

:active_again
if %ATRY% GEQ %SETTLE_TRIES% goto :active_gave_up
call "%LIB%" wait 1
goto :active_poll

:active_there
call "%LIB%" log namespace %~1 is in %ACT_SOURCE%
call :read_ns %~1
if not defined R_OK goto :active_no_id
call :assert_sizes
exit /b 0

:active_gave_up
if not defined ACT_OK goto :assert_no_list
call "%LIB%" fail namespace %~1 is not in %ACT_SOURCE%
exit /b 0

:active_no_id
call "%LIB%" fail identify namespace failed for namespace id %~1
exit /b 0

rem Compare the R_* values just read against what the test namespace was
rem created with.  CREATE_HEX is empty when --test-nsze was not given in hex, in
rem which case only a non-zero size can be checked.
:assert_sizes
if "%R_NSZE%"=="0" goto :sizes_zero
call "%LIB%" log nsze %R_NSZE% ncap %R_NCAP% flbas %R_FLBAS%
if not defined CREATE_HEX goto :sizes_loose
call :hexnorm "%R_NSZE%" GOT_NSZE
call :hexnorm "%R_NCAP%" GOT_NCAP
if /i not "%GOT_NSZE%"=="%CREATE_HEX%" goto :sizes_bad_nsze
if /i not "%GOT_NCAP%"=="%CREATE_HEX%" goto :sizes_bad_ncap
call "%LIB%" pass
exit /b 0

:sizes_loose
call "%LIB%" log the size was not given in hex, so only a non-zero size is checked
call "%LIB%" pass
exit /b 0

:sizes_zero
call "%LIB%" fail the namespace reports a size of zero
exit /b 0

:sizes_bad_nsze
call "%LIB%" fail nsze is %R_NSZE% and the namespace was created with %CREATE_NSZE%
exit /b 0

:sizes_bad_ncap
call "%LIB%" fail ncap is %R_NCAP% and the namespace was created with %CREATE_NSZE%
exit /b 0

:assert_listed
call "%LIB%" skip list mode, identify not executed
exit /b 0

:assert_no_list
call "%LIB%" skip the active namespace list is not available
exit /b 0

rem The active namespace list still holds exactly the namespace ids that were
rem recorded at the start.
:assert_active_list
if defined LIST_ONLY goto :assert_listed
call :refresh_active
if not defined ACT_OK goto :assert_no_list
call "%LIB%" log active namespaces now:%ACT_LIST% according to %ACT_SOURCE%
call :cmp_lists "%ACTIVE_LIST%" "%ACT_LIST%"
if not defined LISTS_EQ goto :active_list_bad
call "%LIB%" pass
exit /b 0

:active_list_bad
call "%LIB%" fail the active namespace list is%ACT_LIST% and was%ACTIVE_LIST%
set "RESTORE_BAD=1"
exit /b 0

rem The primary namespace is back with the size and format it started with.
:assert_primary
if defined LIST_ONLY goto :assert_listed
if not defined NS_PRESENT goto :primary_absent
call :getns %PRIMARY_NSID% NSZE PNSZE
call :getns %PRIMARY_NSID% FLBAS PFLBAS
if not defined PNSZE goto :primary_absent
call :read_ns %PRIMARY_NSID%
if not defined R_OK goto :primary_no_id
if not "%R_NSZE%"=="%PNSZE%" goto :primary_bad_size
if not "%R_FLBAS%"=="%PFLBAS%" goto :primary_bad_flbas
call "%LIB%" pass
exit /b 0

:primary_absent
call "%LIB%" skip no primary namespace was recorded
exit /b 0

:primary_no_id
call "%LIB%" fail identify namespace failed for the primary namespace %PRIMARY_NSID%
set "RESTORE_BAD=1"
exit /b 0

:primary_bad_size
call "%LIB%" fail the primary namespace reports nsze %R_NSZE% and had %PNSZE%
set "RESTORE_BAD=1"
exit /b 0

:primary_bad_flbas
call "%LIB%" fail the primary namespace reports flbas %R_FLBAS% and had %PFLBAS%
set "RESTORE_BAD=1"
exit /b 0

rem Wait until the controller handle can be opened again.
rem
rem An attach or a detach makes Windows rebuild its device tree, and while it
rem does, opening the controller by name fails with "No such file or directory":
rem the name is resolved by scanning the device tree, and the entry is briefly
rem not in it.  Every command that changes which namespaces are attached is
rem followed by this wait, so the next one does not land in that window.
:settle
if defined LIST_ONLY exit /b 0
set "STRY=0"

:settle_try
set /a STRY+=1
%NVMEQ% id ctrl %CTRL% %GLOBAL% > "%WORK%\settle.txt" 2>&1
if not errorlevel 1 goto :settle_back
if %STRY% GEQ %SETTLE_TRIES% goto :settle_gave_up
call "%LIB%" wait 1
goto :settle_try

:settle_back
if %STRY% GTR 1 call "%LIB%" log %CTRL% came back after %STRY% tries
exit /b 0

:settle_gave_up
type "%WORK%\settle.txt" >> "%LOGFILE%" 2>nul
call "%LIB%" log WARNING: %CTRL% cannot be opened after %STRY% tries
exit /b 1

rem Re-read the active namespace list into ACT_LIST.  ACT_OK is set when it could
rem be read at all and ACT_SOURCE says which view answered.
rem
rem The controller's own active namespace list is the primary source.  When
rem identify cannot be issued at all, the node names that nvme list prints are
rem used instead: they carry the namespace ids Windows has enumerated for this
rem controller, which is a weaker statement than what the controller reports as
rem active, but enough to see that a namespace is or is not there.
:refresh_active
set "ACT_OK="
set "ACT_LIST="
set "ACT_SOURCE="
if defined LIST_ONLY exit /b 1
%NVMEQ% id ns-list %CTRL% %GLOBAL% > "%NSLF%" 2>&1
set "ARC=%ERRORLEVEL%"
type "%NSLF%" >> "%LOGFILE%" 2>nul
if "%ARC%"=="0" goto :refresh_parse
call "%LIB%" log the active namespace list could not be read, waiting for the controller handle
call :settle
%NVMEQ% id ns-list %CTRL% %GLOBAL% > "%NSLF%" 2>&1
set "ARC=%ERRORLEVEL%"
type "%NSLF%" >> "%LOGFILE%" 2>nul
if "%ARC%"=="0" goto :refresh_parse
goto :refresh_from_list

:refresh_parse
call :parse_ns_list "%NSLF%"
set "ACT_LIST=%PLIST%"
set "ACT_OK=1"
set "ACT_SOURCE=the active namespace list"
exit /b 0

:refresh_from_list
call :parse_nvme_list
if not defined LIST_NSIDS exit /b 1
set "ACT_LIST=%LIST_NSIDS%"
set "ACT_OK=1"
set "ACT_SOURCE=the nodes nvme list prints"
call "%LIB%" log identify is not answering, taking the namespace ids from nvme list instead
exit /b 0

rem The Node column of nvme list holds the libnvme style names, so a row for this
rem controller reads "nvme0n4  \\.\PhysicalDrive4  ...".  Only that first token is
rem read: the serial and model columns can hold spaces.
rem
rem LIST_NSIDS is left empty when no row matches, which is also what a scan that
rem ran while Windows was rebuilding its device tree looks like, and what a --ctrl
rem given as a raw device path looks like.  Callers must read empty as "not known"
rem rather than as "no namespace is attached".
:parse_nvme_list
set "LIST_NSIDS="
%NVMEQ% list > "%WORK%\list-now.txt" 2>&1
if errorlevel 1 exit /b 1
type "%WORK%\list-now.txt" >> "%LOGFILE%" 2>nul
for /f "usebackq tokens=1" %%a in ("%WORK%\list-now.txt") do call :list_node "%%a"
exit /b 0

:list_node
set "__ln=%~1"
call set "__lr=%%__ln:%CTRL%n=%%"
if "%__lr%"=="%__ln%" exit /b 0
if not defined __lr exit /b 0
set "__ld="
set /a "__ld=%__lr%" >nul 2>&1
if not defined __ld exit /b 0
if "%__ld%"=="0" exit /b 0
set "LIST_NSIDS=%LIST_NSIDS% %__ld%"
exit /b 0

rem restore_ns <nsid> - put one namespace back: recreate it with the
rem configuration it was recorded with when it was deleted, and reattach it when
rem it was attached at the start.  A namespace that was detached to free
rem capacity but whose delete then failed is only reattached.
:restore_ns
if defined NS%~1_FREED goto :restore_ns_recreate
if not defined NS%~1_DETACHED exit /b 0
goto :restore_ns_attach

:restore_ns_recreate
call :getns %~1 NSZE RNSZE
call :getns %~1 NCAP RNCAP
call :getns %~1 FLBAS RFLBAS
call :getns %~1 DPS RDPS
call :getns %~1 NMIC RNMIC
if not defined RNSZE goto :restore_ns_unknown
call "%LIB%" case recreate namespace %~1
set "CMDLINE=%NVMEQ% ns create %CTRL% --nsze=%RNSZE% --ncap=%RNCAP% --flbas=%RFLBAS% --dps=%RDPS% --nmic=%RNMIC% --verbose %GLOBAL%"
call "%LIB%" run ok
if not "%RC%"=="0" goto :restore_ns_bad
set "GOTNSID="
call "%LIB%" field "%LASTOUT%" nsid GOTNSID
set "NS%~1_FREED="
call "%LIB%" case the recreated namespace kept namespace id %~1
if "%GOTNSID%"=="%~1" goto :restore_ns_id_ok
call "%LIB%" fail the controller returned namespace id %GOTNSID%
set "RESTORE_BAD=1"
goto :restore_ns_attach

:restore_ns_id_ok
call "%LIB%" pass

:restore_ns_attach
call :getns %~1 STATE RSTATE
if /i not "%RSTATE%"=="active" goto :restore_ns_detached
call "%LIB%" case reattach namespace %~1
set "CMDLINE=%NVMEQ% ns attach %CTRL% --namespace-id=%~1 --controllers=%CNTLID% --verbose %GLOBAL%"
call "%LIB%" run ok
if not "%RC%"=="0" set "RESTORE_BAD=1"
call :settle
if "%RC%"=="0" set "NS%~1_DETACHED="
exit /b 0

:restore_ns_detached
call "%LIB%" log namespace %~1 was allocated and not attached, leaving it detached
exit /b 0

:restore_ns_bad
set "RESTORE_BAD=1"
exit /b 0

:restore_ns_unknown
call "%LIB%" case recreate namespace %~1
call "%LIB%" fail the configuration of namespace %~1 was never read, it cannot be recreated
set "RESTORE_BAD=1"
exit /b 0

rem Write a pattern to the new namespace and read it back, which needs the
rem namespace to have shown up as a Windows disk: libnvme maps nvme0nX onto a
rem PhysicalDrive by SCSI logical unit, and that mapping only exists once
rem Windows has enumerated the namespace, which a controller reset triggers.
:io_section
if defined SKIPIO goto :io_skipped
if not "%LBAF_MS%"=="0" goto :io_meta
if defined LIST_ONLY goto :io_listed
set "TESTDEV=%CTRL%n%NEWNSID%"

call "%LIB%" case the attached namespace answers identify on its own handle
call :probe_testdev
if "%IRC%"=="0" goto :io_have_handle
call "%LIB%" log %TESTDEV% is not there yet, resetting the controller so Windows enumerates it
set "CMDLINE=%NVMEQ% reset %CTRL% %GLOBAL%"
call "%LIB%" run info
call :probe_testdev
if "%IRC%"=="0" goto :io_have_handle
call "%LIB%" skip %TESTDEV% did not appear, Windows has not enumerated the new namespace
exit /b 0

:io_have_handle
call "%LIB%" pass

call "%LIB%" case build the pattern file
call "%LIB%" mkpat "%PA1%" 15 %SZ1%
if "%PAT_SIZE%"=="%SZ1%" goto :io_pattern_ok
call "%LIB%" fail could not build the pattern file in %WORK%
exit /b 0

:io_pattern_ok
call "%LIB%" pass

call "%LIB%" case write and read back the first blocks of the new namespace
%NVMEQ% write %TESTDEV% --start-block=0 --block-count=%BC1% --data-size=%SZ1% --data="%PA1%" --force %GLOBAL% > "%WORK%\io-out.txt" 2>&1
set "WRC=%ERRORLEVEL%"
type "%WORK%\io-out.txt" >> "%LOGFILE%" 2>nul
if not "%WRC%"=="0" goto :io_write_bad
if exist "%RB%" del /f /q "%RB%" >nul 2>&1
%NVMEQ% read %TESTDEV% --start-block=0 --block-count=%BC1% --data-size=%SZ1% --data="%RB%" %GLOBAL% > "%WORK%\io-out.txt" 2>&1
set "RRC=%ERRORLEVEL%"
type "%WORK%\io-out.txt" >> "%LOGFILE%" 2>nul
if not "%RRC%"=="0" goto :io_read_bad
call "%LIB%" filecmp "%PA1%" "%RB%"
call "%LIB%" log   byte compare method: %CMP_METHOD%
if "%CMP_EQ%"=="1" goto :io_pass
if "%CMP_EQ%"=="0" goto :io_mismatch
call "%LIB%" skip neither fc nor certutil is available to compare files
exit /b 0

:io_pass
call "%LIB%" pass
exit /b 0

:io_write_bad
call "%LIB%" fail write returned exit code %WRC%
exit /b 0

:io_read_bad
call "%LIB%" fail read returned exit code %RRC%
exit /b 0

:io_mismatch
call "%LIB%" fail the data read back does not match the data written
exit /b 0

:io_skipped
call "%LIB%" case IO on the new namespace
call "%LIB%" skip --skip-io was given
exit /b 0

:io_meta
call "%LIB%" case IO on the new namespace
call "%LIB%" skip the lba format has metadata, the IO round trip needs a format with ms 0
exit /b 0

:io_listed
call "%LIB%" case IO on the new namespace
call "%LIB%" skip list mode, IO not executed
exit /b 0

:probe_testdev
%NVMEQ% id ns %TESTDEV% %GLOBAL% > "%WORK%\id-test-ns.txt" 2>&1
set "IRC=%ERRORLEVEL%"
type "%WORK%\id-test-ns.txt" >> "%LOGFILE%" 2>nul
exit /b 0

:usage
echo.
echo Usage: nvme-ns-mgmt-test.bat --yes [options]
echo.
echo   --ns DEV            namespace device, default nvme0n1
echo                       accepts nvme0n1 or a raw path such as
echo                       \\.\PhysicalDrive1
echo   --ctrl DEV          controller device, default nvme0
echo   --nsid N            namespace id the namespace device stands for,
echo                       default the one ns get-id reports
echo   --cntlid N          controller id to attach to, default the cntlid
echo                       that identify controller reports
echo   --test-nsze N       size of the test namespace in blocks, default
echo                       0x10000.  Give it in hex to have the size the
echo                       namespace reports checked against it
echo   --probe-max N       highest namespace id probed when the drive does
echo                       not report its allocated namespace list,
echo                       default 64
echo   --no-probe          do not probe for namespaces that are allocated
echo                       but not attached
echo   --skip-io           do not write to the test namespace
echo   --assume-winpe      expect the WinPE behaviour even when the MiniNT
echo                       registry key is not there
echo   --nvme PATH         nvme binary to test, default nvme from PATH
echo   --timeout MS        pass --timeout to every nvme command
echo   --out DIR           parent directory for the log and work files,
echo                       default the TEMP directory
echo   --list              print the commands without touching the device
echo   --yes               required, confirms that namespaces may be deleted
echo.
echo The namespace layout is recorded and restored, the data in a namespace
echo that has to be deleted is not.
echo.
exit /b 2

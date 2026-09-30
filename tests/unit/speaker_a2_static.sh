#!/bin/sh
# Static contracts for speaker A2 path (no saveAndSet; no periodic_30s; composition helpers exist).
# Includes fail-on-break checks for config-wait→recovery gating and pre_teardown bind snapshot order.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MAIN="$ROOT/src/main.m"
ENG="$ROOT/src/ABPassThroughEngine.m"
AGG="$ROOT/src/ABAggregateDevice.m"
DIAG="$ROOT/src/ABDiagSnapshot.m"

# Speaker streaming region must not call saveAndSet* (PCM path may still pin).
# Recovery calls must be control-gated by ABSpeakerConfigWaitSuppressesRecovery (not mere identifier presence).
# ABShutdownStreaming must emit pre_teardown before clearing bind globals.
python3 - <<PY || exit 1
import re
from pathlib import Path

main = Path("$MAIN").read_text()
diag = Path("$DIAG").read_text()

start = main.index("static int ABRunSpeakerStreaming")
end = main.index("static BOOL ABParseStrictPositiveDecimalInt")
region = main[start:end]

if "saveAndSet" in region:
    raise SystemExit("speaker path still calls saveAndSet*")
if "periodic_30s" in region:
    raise SystemExit("speaker path still references periodic_30s")

call_pat = re.compile(r"ABRunSharedRecoveryPipeline\s*\(")
calls = list(call_pat.finditer(region))
if not calls:
    raise SystemExit("speaker path missing ABRunSharedRecoveryPipeline (heartbeat recovery expected)")

# Named gate must exist and encode waiting ⇒ suppress (destruction of body must fail logic check).
gate_def = re.search(
    r"static\s+BOOL\s+ABSpeakerConfigWaitSuppressesRecovery\s*\(\s*BOOL\s+configWaiting\s*\)\s*\{([^}]*)\}",
    main,
)
if not gate_def:
    raise SystemExit("missing ABSpeakerConfigWaitSuppressesRecovery gate function")
gate_body = gate_def.group(1)
if not re.search(r"return\s+configWaiting\s*;", gate_body):
    raise SystemExit("ABSpeakerConfigWaitSuppressesRecovery must return configWaiting (wait ⇒ suppress)")

# Each speaker recovery call must be preceded, inside the nearest inactive block, by an early-return
# that invokes the gate. Mere nearby "configWaiting" tokens are not enough.
gate_return = re.compile(
    r"if\s*\(\s*ABSpeakerConfigWaitSuppressesRecovery\s*\([^;]*?\)\s*\)\s*\{\s*return\s*;\s*\}",
    re.S,
)
inactive_pat = re.compile(r"if\s*\(\s*!active\s*\)")

for m in calls:
    before = region[: m.start()]
    inactive = list(inactive_pat.finditer(before))
    if not inactive:
        raise SystemExit("ABRunSharedRecoveryPipeline in speaker path without if (!active) context")
    block = before[inactive[-1].start() :]
    if not gate_return.search(block):
        raise SystemExit(
            "inactive→recovery path missing ABSpeakerConfigWaitSuppressesRecovery early-return gate"
        )
    # Fail-on-break: if the gate return were deleted from this block, the check above fails.
    # Also require the gate call appears after inactive and before this recovery call with no
    # intervening ungated recovery (already true: we scan only this call's preceding inactive block).

# SCQA-001: pre_teardown snapshot must run while bind globals are still live.
shutdown_start = main.index("void ABShutdownStreaming(void)")
shutdown_end = main.index("static void ABStreamingHandleSignal", shutdown_start)
shutdown = main[shutdown_start:shutdown_end]
pre = shutdown.find('@"pre_teardown"')
if pre < 0:
    raise SystemExit("ABShutdownStreaming missing pre_teardown emit")
# Clearance of bind state must not precede pre_teardown.
for needle in (
    "g_streamingAggregate = nil",
    "g_streamingBoundDeviceID = kAudioObjectUnknown",
    "g_streamingConfigWaiting = NO",
):
    pos = shutdown.find(needle)
    if pos < 0:
        raise SystemExit(f"ABShutdownStreaming missing expected clear: {needle}")
    if pos < pre:
        raise SystemExit(f"{needle} clears bind state before pre_teardown snapshot")

# SCQA-003: runtime snapshot must not emit legacy pin_* contract fields.
if re.search(r'ABDiagAppendKV\s*\(\s*out\s*,\s*@"pin_in"', diag) or re.search(
    r'ABDiagAppendKV\s*\(\s*out\s*,\s*@"pin_out"', diag
):
    raise SystemExit("ABDiagSnapshot still emits legacy pin_in/pin_out fields")

# SIQA-003: config identity must survive unavailability via string and/or Device UID re-resolve.
# Fail if leaveConfigWaitAndReattach only gates on sticky AudioDeviceID alive without re-parse.
leave_fn = re.search(
    r"void\s*\(\s*\^\s*leaveConfigWaitAndReattach\s*\)\s*\([^)]*\)\s*=\s*\^\s*\([^)]*\)\s*\{",
    region,
)
if not leave_fn:
    raise SystemExit("missing leaveConfigWaitAndReattach block")
leave_start = leave_fn.end()
next_block = re.search(r"\n    (?:void|BOOL)\s*\(\s*\^", region[leave_start:])
leave_body = region[leave_start : leave_start + next_block.start()] if next_block else region[leave_start:]

if "ABSpeakerReresolveConfiguredIDs" not in leave_body and "resolveInputString" not in leave_body:
    raise SystemExit(
        "leaveConfigWaitAndReattach must re-resolve config identity "
        "(ABSpeakerReresolveConfiguredIDs / resolveInputString), not sticky AudioDeviceID only"
    )
# Identity capture + devices-list watch live as helpers adjacent to the speaker path.
if "deviceUIDForAudioDeviceID" not in main and "ABSpeakerCaptureDeviceUID" not in main:
    raise SystemExit("speaker path must capture Device UID for config identity across unavailability")
if "kAudioHardwarePropertyDevices" not in main:
    raise SystemExit(
        "speaker path must watch kAudioHardwarePropertyDevices to re-resolve after USB re-enumeration"
    )
# Fail-on-break: leaveConfigWait must not gate solely on sticky id alive without reresolve helper.
if re.search(
    r"leaveConfigWaitAndReattach[\s\S]*?ABDeviceIsAlive\s*\(\s*resolvedInputIDBlock\s*\)",
    region,
) and "ABSpeakerReresolveConfiguredIDs" not in leave_body:
    raise SystemExit("leaveConfigWaitAndReattach still gates only on sticky resolvedInputIDBlock alive")

# SIQA-004: hardware/default change must not unconditionally stop+rebuild when logical identity is unchanged.
hw_fn = re.search(
    r"void\s*\(\s*\^\s*onHardwareOrDefaultChange\s*\)\s*\([^)]*\)\s*=\s*\^\s*\([^)]*\)\s*\{",
    region,
)
if not hw_fn:
    raise SystemExit("missing onHardwareOrDefaultChange block")
hw_start = hw_fn.end()
hw_next = re.search(r"\n    (?:void|BOOL)\s*\(\s*\^|devicesWatch\s*=", region[hw_start:])
hw_body = region[hw_start : hw_start + hw_next.start()] if hw_next else region[hw_start:]

if "ABSpeakerResolveLogicalIO" not in hw_body:
    raise SystemExit(
        "onHardwareOrDefaultChange must re-resolve logical in/out before deciding to rebuild"
    )
# Must compare next logical ids to current and return without stop when unchanged.
if not re.search(
    r"nextLogicalIn\s*==\s*logicalInBlock\s*&&\s*nextLogicalOut\s*==\s*logicalOutBlock",
    hw_body,
):
    raise SystemExit(
        "onHardwareOrDefaultChange must skip stop/rebuild when nextLogicalIn/Out match current logical ids"
    )
# The identity-equal branch must return before stop+rebuild (fail if stop precedes the equal check).
eq_pos = hw_body.find("nextLogicalIn == logicalInBlock")
if eq_pos < 0:
    eq_pos = hw_body.find("nextLogicalIn==logicalInBlock")
stop_pos = hw_body.find("[passEngineBlock stop]")
rebuild_pos = hw_body.find("rebuildBindingAndStart")
if eq_pos < 0 or stop_pos < 0 or rebuild_pos < 0:
    raise SystemExit("onHardwareOrDefaultChange missing identity gate, stop, or rebuildBindingAndStart")
if not (eq_pos < stop_pos < rebuild_pos):
    raise SystemExit(
        "identity-unchanged gate must precede stop+rebuild (unconditional rebuild path is a SIQA-004 break)"
    )
# Rebuild failure must enter config wait (not leave non-waiting + destroyed bind for heartbeat recovery).
if "enterConfigWait" not in hw_body or not re.search(
    r"if\s*\(\s*!\s*rebuildBindingAndStart\s*\([^)]*\)\s*\)\s*\{[^}]*enterConfigWait",
    hw_body,
    re.S,
):
    raise SystemExit(
        "onHardwareOrDefaultChange must enterConfigWait when rebuildBindingAndStart fails"
    )

# SIQA-004: devices-list watch must coalesce with ~80ms quiet window (same class as default listeners).
devices_impl_start = main.find("@implementation ABSpeakerHardwareDevicesWatch")
if devices_impl_start < 0:
    raise SystemExit("missing ABSpeakerHardwareDevicesWatch implementation")
devices_impl_end = main.find("@end", devices_impl_start)
devices_impl = main[devices_impl_start:devices_impl_end]
if "NSEC_PER_SEC * 0.08" not in devices_impl and "NSEC_PER_SEC*0.08" not in devices_impl:
    raise SystemExit(
        "ABSpeakerHardwareDevicesWatch must debounce with 80ms quiet window (NSEC_PER_SEC * 0.08)"
    )
if "_debounceGeneration" not in devices_impl:
    raise SystemExit("ABSpeakerHardwareDevicesWatch must coalesce bursts via debounce generation token")

# A2 bind: same-AU skip of input CurrentDevice set is forbidden (resets to system default mic).
eng = Path("$ENG").read_text()
if re.search(
    r"inputUnit\s*!=\s*(?:NULL|nil)\s*&&\s*inputUnit\s*!=\s*outputUnit",
    eng,
):
    raise SystemExit(
        "ABPassThroughEngine must not skip input CurrentDevice bind when inputUnit==outputUnit"
    )
# Must materialize both nodes before bind writes (order contract: outputNode then inputNode before Set).
apply_fn = re.search(
    r"ab_applyBoundDeviceOnEngine[\s\S]*?ab_verifyActualCurrentDevice",
    eng,
)
if not apply_fn:
    raise SystemExit("missing ab_applyBoundDeviceOnEngine → ab_verifyActualCurrentDevice bind path")
apply_body = apply_fn.group(0)
if "engine.outputNode" not in apply_body or "engine.inputNode" not in apply_body:
    raise SystemExit("bind apply must materialize outputNode and inputNode")
# Readback of CurrentDevice is mandatory (no intent-only bind_ok).
if "AudioUnitGetProperty" not in eng or "kAudioOutputUnitProperty_CurrentDevice" not in eng:
    raise SystemExit("ABPassThroughEngine must AudioUnitGetProperty CurrentDevice for readback")
if "ab_verifyActualCurrentDevice" not in eng:
    raise SystemExit("missing ab_verifyActualCurrentDevice readback gate")
if "actual_out_device_id" not in eng or "actual_in_device_id" not in eng:
    raise SystemExit("device_bind_ok / speaker path must expose actual_out/in_device_id readback fields")
# prepare/start then apply+verify (post-start bind); cold Aggregate bind before first start is brittle.
connect_start = eng.find("- (BOOL)ab_connectPrepareStartEngine:")
if connect_start < 0:
    raise SystemExit("missing ab_connectPrepareStartEngine")
connect_end = eng.find("- (BOOL)startWithError:", connect_start)
connect_body = eng[connect_start:connect_end]
if "startAndReturnError" not in connect_body:
    raise SystemExit("connectPrepareStart missing startAndReturnError")
start_pos = connect_body.find("startAndReturnError")
if connect_body.find("ab_applyBoundDeviceOnEngine", start_pos) < 0:
    raise SystemExit("connectPrepareStart must apply bound device after initial start")
if "ab_verifyActualCurrentDevice" not in connect_body:
    raise SystemExit("connectPrepareStart must verify CurrentDevice after bind")
if "ab_emitDeviceBindOkOnEngine" not in connect_body:
    raise SystemExit("connectPrepareStart must emit device_bind_ok only after verified bind")

# Snapshot: system_default_* must not be named as engine input; actual_* is authority.
if '@"default_in_id"' in diag or '@"default_out_id"' in diag:
    raise SystemExit("ABDiagSnapshot must use system_default_in/out_* (not default_in/out_*)")
if '@"system_default_in_id"' not in diag or '@"system_default_out_id"' not in diag:
    raise SystemExit("ABDiagSnapshot missing system_default_in/out_id fields")
if '@"actual_device_id"' not in diag or '@"actual_in_device_id"' not in diag:
    raise SystemExit("ABDiagSnapshot engine section must emit actual_* CurrentDevice readback")

print("speaker_a2_static: speaker region ok")
PY

# Aggregate-bound routes must use HAL I/O (AVAudioEngine Aggregate CurrentDevice → -10875).
HAL="$ROOT/src/ABHALPassThroughIO.m"
HALH="$ROOT/src/ABHALPassThroughIO.h"
if [ ! -f "$HAL" ] || [ ! -f "$HALH" ]; then
    echo "missing ABHALPassThroughIO module for Aggregate I/O" >&2
    exit 1
fi
grep -Eq 'kAudioUnitSubType_HALOutput' "$HAL" || exit 1
grep -Eq 'deviceIsAggregate' "$HAL" || exit 1
grep -Eq 'saveAndSet|setDefaultInput|setDefaultOutput' "$HAL" && exit 1
# Engine must gate Aggregate → HAL (not AVAudioEngine warm/restart which fails -10875).
if ! grep -Eq 'deviceIsAggregate' "$ENG"; then
    echo "ABPassThroughEngine must route Aggregate via ABHALPassThroughIO" >&2
    exit 1
fi
if ! grep -Eq 'ab_startHALPassThroughWithError|ABHALPassThroughIO' "$ENG"; then
    echo "ABPassThroughEngine missing HAL Aggregate start path" >&2
    exit 1
fi
# SIQA-001: render callback must not heap-allocate; scratch is preallocated at start.
python3 - <<PY || exit 1
from pathlib import Path
import re
hal = Path("$HAL").read_text()
cb = re.search(r"static\s+OSStatus\s+ABHALRenderCallback\s*\([^)]*\)\s*\{", hal)
if not cb:
    raise SystemExit("missing ABHALRenderCallback")
# Brace-match callback body.
i = cb.end() - 1
depth = 0
end = None
for j in range(i, len(hal)):
    if hal[j] == "{":
        depth += 1
    elif hal[j] == "}":
        depth -= 1
        if depth == 0:
            end = j
            break
if end is None:
    raise SystemExit("failed to parse ABHALRenderCallback body")
body = hal[cb.end() : end]
if re.search(r"\bcalloc\s*\(|\bmalloc\s*\(|\brealloc\s*\(|\bfree\s*\(", body):
    raise SystemExit("ABHALRenderCallback must not calloc/malloc/realloc/free (SIQA-001)")
if "ABHALAllocateScratch" not in hal and "ABHALEnsureScratch" in hal:
    raise SystemExit("HAL scratch must be preallocated at start, not ensured in callback")
if "ABHALAllocateScratch" not in hal:
    raise SystemExit("missing ABHALAllocateScratch for start-time scratch preallocation")
# AllocateScratch must appear in startWithDeviceID, not only as a dead symbol.
start_fn = re.search(r"-\s*\(BOOL\)\s*startWithDeviceID:[^{]*\{", hal)
if not start_fn:
    raise SystemExit("missing startWithDeviceID")
si = start_fn.end() - 1
depth = 0
send = None
for j in range(si, len(hal)):
    if hal[j] == "{":
        depth += 1
    elif hal[j] == "}":
        depth -= 1
        if depth == 0:
            send = j
            break
start_body = hal[start_fn.end() : send]
if "ABHALAllocateScratch" not in start_body:
    raise SystemExit("startWithDeviceID must preallocate scratch via ABHALAllocateScratch")
if start_body.find("ABHALAllocateScratch") > start_body.find("AudioOutputUnitStart"):
    raise SystemExit("scratch preallocation must precede AudioOutputUnitStart")
print("speaker_a2_static: HAL realtime scratch ok")
PY
# Fail-on-break: Aggregate→HAL must not fall through to AV on success or failure; rebuild must match start.
python3 - <<PY || exit 1
from pathlib import Path
import re

eng = Path("$ENG").read_text()


def method_body(src: str, needle: str) -> str:
    idx = src.find(needle)
    if idx < 0:
        raise SystemExit(f"missing method marker: {needle}")
    brace = src.find("{", idx)
    if brace < 0:
        raise SystemExit(f"missing opening brace for {needle}")
    depth = 0
    for j in range(brace, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[brace + 1 : j]
    raise SystemExit(f"unbalanced braces for {needle}")


def extract_aggregate_if(body: str) -> str:
    """Return the Aggregate deviceIsAggregate if-block body (inner)."""
    m = re.search(
        r"if\s*\(\s*_boundDeviceID\s*!=\s*kAudioObjectUnknown\s*&&\s*"
        r"\[\s*ABHALPassThroughIO\s+deviceIsAggregate\s*:\s*_boundDeviceID\s*\]\s*\)\s*\{",
        body,
    )
    if not m:
        raise SystemExit("missing Aggregate deviceIsAggregate gate")
    brace = m.end() - 1
    depth = 0
    for j in range(brace, len(body)):
        if body[j] == "{":
            depth += 1
        elif body[j] == "}":
            depth -= 1
            if depth == 0:
                return body[brace + 1 : j]
    raise SystemExit("unbalanced Aggregate if")


def assert_hal_only_gate(method_name: str, body: str) -> None:
    agg = extract_aggregate_if(body)
    if "ab_startHALPassThroughWithError" not in agg:
        raise SystemExit(f"{method_name}: Aggregate gate missing ab_startHALPassThroughWithError")
    if "[[AVAudioEngine alloc] init]" in agg:
        raise SystemExit(f"{method_name}: Aggregate gate must not allocate AVAudioEngine (HAL-only)")
    # Failure must return NO before any fall-through.
    fail = re.search(
        r"if\s*\(\s*!\s*\[\s*self\s+ab_startHALPassThroughWithError\s*:[^]]+\]\s*\)\s*\{",
        agg,
    )
    if not fail:
        raise SystemExit(f"{method_name}: Aggregate HAL failure branch missing")
    fail_brace = fail.end() - 1
    depth = 0
    fail_end = None
    for j in range(fail_brace, len(agg)):
        if agg[j] == "{":
            depth += 1
        elif agg[j] == "}":
            depth -= 1
            if depth == 0:
                fail_end = j
                break
    fail_body = agg[fail_brace + 1 : fail_end]
    if not re.search(r"return\s+NO\s*;", fail_body):
        raise SystemExit(f"{method_name}: HAL failure must return NO (must not fall through to AV)")
    after_fail = agg[fail_end + 1 :]
    # Success path after failure branch must return YES before leaving Aggregate if.
    if not re.search(r"return\s+YES\s*;", after_fail):
        raise SystemExit(
            f"{method_name}: Aggregate HAL success must return YES "
            "(else success still falls through to AV — SIQA-002)"
        )
    # Nothing after the last return YES except whitespace/comments before end of Aggregate if.
    last_yes = list(re.finditer(r"return\s+YES\s*;", after_fail))[-1]
    trailing = after_fail[last_yes.end() :]
    trailing_code = re.sub(r"//.*?$|/\*.*?\*/", "", trailing, flags=re.M | re.S).strip()
    if trailing_code:
        raise SystemExit(
            f"{method_name}: code after Aggregate HAL return YES can still reach AV "
            f"(trailing={trailing_code[:80]!r})"
        )
    # AV alloc must exist outside Aggregate gate (duplex path) and after the gate in source order.
    av = body.find("[[AVAudioEngine alloc] init]")
    agg_pos = body.find("deviceIsAggregate")
    if av < 0:
        raise SystemExit(f"{method_name}: missing AVAudioEngine duplex fallback")
    if not (agg_pos < av):
        raise SystemExit(f"{method_name}: Aggregate HAL gate must precede AVAudioEngine alloc")


start_body = method_body(eng, "- (BOOL)startWithQuiet:")
rebuild_body = method_body(eng, "- (BOOL)rebuildForRouteChangeWithQuiet:")
assert_hal_only_gate("startWithQuiet", start_body)
assert_hal_only_gate("rebuildForRouteChangeWithQuiet", rebuild_body)
print("speaker_a2_static: Aggregate HAL gate ok (start+rebuild, no AV fall-through)")
PY

grep -Eq 'shouldBindDirectlyWithInputDeviceID' "$AGG" || exit 1
grep -Eq 'boundDeviceID' "$ENG" || exit 1
grep -Eq 'saveAndSet|setDefaultInput|setDefaultOutput' "$AGG" && exit 1
grep -Eq 'saveAndSet|setDefaultInput|setDefaultOutput' "$ENG" && exit 1
echo "speaker_a2_static: ok"
exit 0

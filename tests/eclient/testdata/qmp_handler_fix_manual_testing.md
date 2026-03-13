# Manual Testing: QMP Event Handler Fix

## Overview

This document describes how to manually test the fix for the QMP event handler issue that caused log flooding (~10,000 messages/sec) when a VM was stopped and restarted rapidly.

---

## Prerequisites

- Access to EVE device (SSH)
- Access to Cloud controller (to manage VMs)
- A VM deployed on the EVE device

---

## Test Procedure

### Step 1: Set Debug Log Level to INFO

Before testing, ensure the log level is set to capture INFO messages using **zcli**:

```bash
zcli edge-node update <device-name> --config debug.default.loglevel=info
```

Wait for the configuration to be applied to EVE.

### Step 2: Deploy or Use an Existing VM

Ensure you have a VM running on the EVE device. Any VM will work for this test.

### Step 3: Perform Multiple Stop/Start Cycles

Perform **5 or more** rapid stop/start cycles on the VM:

1. **Stop the VM** via the Cloud controller
2. **Wait for HALTED state** (typically 60-120 seconds for a graceful shutdown)
3. **Start the VM** via the Cloud controller  
4. **Wait for RUNNING state** (typically 30-60 seconds)
5. **Repeat** steps 1-4 at least 5 times

> **Tip**: The faster you cycle through stop/start, the more likely you are to trigger the issue if the bug is present.

### Step 4: Check EVE Logs for Results

SSH into the EVE device and check the logs.

#### Check for Success Indicators (Fix Working)

```bash
# Check collected device logs
cat /persist/newlog/collect/dev.log.* 2>/dev/null | grep -i "Event channel closed for socket"

# Also check archived logs
zcat /persist/newlog/keepSentQueue/*.gz 2>/dev/null | grep -i "Event channel closed for socket"
```

**Expected output if fix is working:**
```
Event channel closed for socket: /run/hypervisor/kube/<uuid>/qmp (QMP connection lost)
```

#### Check for Failure Indicators (Bug Present)

```bash
# Check for empty "Unhandled event" messages
cat /persist/newlog/collect/dev.log.* 2>/dev/null | grep "Unhandled event:  from QMP socket"
```

**Example of bug symptom** (note the empty event name - double space after "event:"):
```
qmpEventHandler: Unhandled event:  from QMP socket /run/hypervisor/kube/<uuid>/qmp
```

---

## Interpreting Results

| Result | Meaning |
|--------|---------|
| `Event channel closed for socket` messages found | ✅ **PASS** - Fix is working correctly |
| `Unhandled event:  from QMP socket` messages found | ❌ **FAIL** - Bug is present |
| Neither message found | ⚠️ **INCONCLUSIVE** - Repeat the test with more stop/start cycles |

---

## Quick Reference: Log Locations on EVE

| Path | Description |
|------|-------------|
| `/persist/newlog/collect/dev.log.*` | Current device logs |
| `/persist/newlog/keepSentQueue/*.gz` | Archived logs (gzipped) |

---

## Summary

1. Set log level to `info` using zcli
2. Stop/start a VM 5+ times rapidly
3. SSH to EVE and check logs:
   - **PASS**: `"Event channel closed for socket"` messages appear
   - **FAIL**: `"Unhandled event:  from QMP socket"` messages appear
   - **INCONCLUSIVE**: Neither message found - repeat the test

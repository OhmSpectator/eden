# Manual Test: Boot Retry with Global Configuration

## Overview

This test verifies that when a VM fails to boot and EVE automatically retries, the global device configuration settings are correctly applied during the retry.

### What We're Testing

We verify that the **VMM memory overhead** setting is correctly applied when EVE retries a failed boot:

- **Expected behavior**: The configured 800 MiB overhead is used during retry
- **Bug behavior**: EVE falls back to default overhead (~374 MiB) during retry

The difference (~400 MB in cgroup memory limit) is large enough to clearly detect the bug.

---

## Prerequisites

- EVE device running
- Access to EVE (SSH or console)
- Controller access (zcli or UI)
- ~30 minutes for the full test

---

## Test Procedure

### Step 1: Configure Global Settings (2 minutes + 2 minutes wait)

Set the boot retry timer to 120 seconds, VMM memory limit to 800 MiB, and enable debug logging.

**Using zcli:**

```bash
zcli edge-node update <device-name> --config timer.boot.retry=120
zcli edge-node update <device-name> --config memory.vmm.limit.MiB=800
zcli edge-node update <device-name> --config debug.default.loglevel=debug
```

**Wait 2 minutes** for EVE to receive and apply the configuration.

**Verify configuration was applied (run on EVE):**

```bash
cat /persist/status/zedagent/ConfigItemValueMap/global.json | grep -E 'timer.boot.retry|memory.vmm.limit'
```

Expected output should show:
- `timer.boot.retry` with `IntValue: 120`
- `memory.vmm.limit.MiB` with `IntValue: 800`

---

### Step 2: Deploy Test VM (5-10 minutes)

Using the controller, deploy a test VM:
- Memory: 1024 MB
- Any Linux VM image

Wait for the VM to reach **RUNNING** state.

---

### Step 3: Verify Initial Memory Limit (2 minutes)

Once the VM is RUNNING, verify the cgroup memory limit.

**Run on EVE:**

```bash
find /sys/fs/cgroup/memory/eve-user-apps -name 'memory.limit_in_bytes' -exec echo {} \; -exec cat {} \;
```

**Expected value**: approximately **1,887,436,800 bytes** (~1.8 GB)

**Record this value** - we'll compare it after the retry.

---

### Step 4: Delete the VM (2 minutes)

Delete the VM using the controller.

**Wait 2 minutes** for deletion to complete.

---

### Step 5: Make KVM State Directory Immutable (1 minute)

This will cause the VM boot to fail when we redeploy.

**Run on EVE:**

```bash
mkdir -p /run/hypervisor/kvm && chattr +i /run/hypervisor/kvm
```

**Verify (run on EVE):**

```bash
lsattr -d /run/hypervisor/kvm
```

Should show 'i' flag (immutable) in the output.

---

### Step 6: Deploy VM Again - This Will Fail (5 minutes)

Using the controller, deploy the same VM again (1024 MB memory).

**Wait up to 5 minutes** for the boot to be attempted. It will fail.

**Check for failure:** The VM should show an error state. 

**DO NOT proceed until you see a failure state!**

---

### Step 7: Remove Immutable Flag (1 minute)

Restore the directory so the retry can succeed.

**Run on EVE:**

```bash
chattr -i /run/hypervisor/kvm
```

**Verify (run on EVE):**

```bash
lsattr -d /run/hypervisor/kvm
```

Should NOT show 'i' flag anymore.

---

### Step 8: Wait for Automatic Retry (3-4 minutes)

EVE will automatically retry the boot after the configured retry interval (120 seconds).

**Wait 3-4 minutes** for the VM to automatically restart.

The VM should eventually show **RUNNING** state in the controller.

---

### Step 9: Verify Memory Limit After Retry - THE KEY TEST (2 minutes)

Once the VM is RUNNING again, check the cgroup memory limit.

**Run on EVE:**

```bash
find /sys/fs/cgroup/memory/eve-user-apps -name 'memory.limit_in_bytes' -exec echo {} \; -exec cat {} \;
```

#### Expected Results

| Scenario | Expected Memory Limit |
|----------|----------------------|
| **PASS** | ~1,887,436,800 bytes (~1.8 GB) |
| **FAIL** | ~1,440,000,000 bytes (~1.4 GB) |

**The test PASSES if the memory limit is approximately 1.8 GB (same as Step 3).**

**The test FAILS if the memory limit is approximately 1.4 GB or significantly different.**

---

### Step 10: Verify Logs - Confirm Retry Cycle (2 minutes)

Confirm that EVE went through the retry cycle by checking the logs.

**Run on EVE:**

```bash
logread | grep -iE 'maybeRetryBoot|BootFailed' | tail -30
```

**Expected log entries:**

1. **Boot failure detected** - look for lines containing:
   - `BootFailed` or `boot failed`
   - Error message about the immutable directory

2. **Retry triggered** - look for lines containing:
   - `maybeRetryBoot` - indicates the retry function was called
   - `DONE` after `maybeRetryBoot` - indicates retry completed successfully

Example of expected log pattern:
```
... BootFailed ...
... maybeRetryBoot(...) after ... at ...
... maybeRetryBoot(...) DONE for ...
```

**The presence of these log entries confirms the test exercised the retry path.**

---

## Quick Reference: Pass/Fail Criteria

| Check | PASS | FAIL |
|-------|------|------|
| Initial cgroup limit (Step 3) | ~1.8 GB | Any other value |
| Boot fails with immutable dir (Step 6) | Error state visible | RUNNING |
| VM restarts after retry (Step 8) | RUNNING state | Stuck in error |
| **Cgroup limit after retry (Step 9)** | **~1.8 GB** | **~1.4 GB or different** |
| Logs show retry cycle (Step 10) | `maybeRetryBoot` entries present | No retry entries |

---


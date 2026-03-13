# QMP Event Handler Log Flooding

## Problem

The `qmpEventHandler` floods logs with "Unhandled event: " messages at ~12,000/second during VM stop/start cycles with USB passthrough. The message shows an empty event name:

```
qmpEventHandler: Unhandled event:  from QMP socket: /run/hypervisor/kvm/.../listener.qmp
```

This causes Redis/Adam to become extremely slow (60+ seconds to fetch logs) and EVE's newlog to accumulate 7000+ files.

## Observed On

- **14.5-stable branch** - confirmed flooding during USB boot priority tests
- Trigger: VM stop/start cycle (e.g., TC-CTRL-2 in USB boot priority test)
- VM has USB passthrough configured (`--adapters USB2:1` with QEMU USB HARDDRIVE 46f4:0001)

Note: 13.4-stable and master have not shown the issue in testing so far. Further investigation needed to understand if this is branch-specific or timing-related.

## Evidence: Normal vs Flooding Behavior

### Normal VM Shutdown (no flooding)

From `newlog.txt` - healthy run showing complete QMP event sequence:

```
14:04:21.779 - RESUME (VM starts)
14:06:08.728 - POWERDOWN (shutdown initiated)
14:06:08.974 - DEVICE_DELETED (cleanup)
14:06:11.250 - SHUTDOWN (guest-shutdown) → handler calls quit
14:06:11.328 - STOP
14:06:11.330 - SHUTDOWN (host-qmp-quit) → handler calls quit again
14:06:11.454 - ERROR: broken pipe (write to executor socket fails)
14:06:29.457 - ERROR: executor socket "no such file"
14:06:29.457 - ERROR: listenerSocket "no such file" → handler exits gracefully
```

**Key observation**: Handler exits via `os.Stat(listenerSocket)` check - 18 seconds after broken pipe, the socket file is finally deleted. No empty events logged.

### Flooding Case (14.5-stable)

From earlier investigation - `log-no-up-to-now.txt` shows 90,689 empty event messages:

```
qmpEventHandler: Unhandled event:  from QMP socket: .../listener.qmp
```

**Key difference**: The go-qemu event channel closes BEFORE the socket file is deleted. Handler receives zero-value events from closed channel in tight loop.

## Likely Cause

When the QMP event channel closes (e.g., when VM stops), the current code doesn't detect it:

```go
case event := <-eventChan:  // No check for closed channel
```

Reading from a closed channel returns zero value (`Event{Event: ""}`) immediately without blocking, creating a tight infinite loop.

The go-qemu library closes the channel when the socket disconnects (`defer close(events)` in `listen()`).

### Why `os.Stat` Check Doesn't Help

The socket file check runs BETWEEN event reads:
```go
for {
    if _, err := os.Stat(listenerSocket); err != nil {
        return  // Only checked here
    }
    select {
    case event := <-eventChan:  // Tight loop here when channel closed
        // process event
    }
}
```

If channel closes while socket file still exists, the loop runs thousands of times before the next `os.Stat` check.

## Suspected Root Cause: Timing/Race Condition

The test setup involves nested USB passthrough (Host → EVE → Guest VM). Possible scenarios:

1. **Normal shutdown**: QEMU shuts down gracefully, socket file is deleted, handler exits via `os.Stat`
2. **Flooding case**: Something causes go-qemu's internal reader to close the channel (EOF, error, disconnect) while socket file still exists temporarily

The empty event name (`""`) confirms **channel closure** - not an actual QMP event like `GUEST_PANICKED` which would show its name.

## Theoretical Code Flow: How Flooding Occurs

### go-qemu library (socket.go)

```go
func (mon *SocketMonitor) listen(r io.Reader, events chan<- Event, stream chan<- streamResponse) {
    defer close(events)   // <-- Channel closed when listen() exits
    defer close(stream)

    scanner := bufio.NewScanner(r)
    for scanner.Scan() {  // <-- Exits when socket disconnects (EOF) or error
        // ... parse events ...
        events <- e
    }
    // Loop exits → defers run → events channel closed
}
```

**Key insight**: `scanner.Scan()` returns `false` when:
- Socket is closed (EOF)
- Read error occurs
- Scanner buffer overflow

When this happens, `listen()` exits and `defer close(events)` closes the events channel.

### EVE qmpEventHandler (original code)

```go
func qmpEventHandler(listenerSocket, executorSocket string) {
    // ... setup monitor, connect ...
    eventChan, _ := monitor.Events(context.Background())
    
    for {
        // Check 1: Is socket FILE still there?
        if _, err := os.Stat(listenerSocket); err != nil {
            return  // Exit if file gone
        }
        
        select {
        case event := <-eventChan:  // <-- BUG: No check for closed channel!
            switch event.Event {
            case "SHUTDOWN":
                // handle
            default:
                logrus.Warnf("Unhandled event: %s", event.Event)  // Logs empty string!
            }
        }
    }
}
```

### All Possible Reasons for `listen()` Goroutine to Exit

The `listen()` goroutine uses `bufio.Scanner` to read from the socket. It exits when `scanner.Scan()` returns `false`:

```go
scanner := bufio.NewScanner(r)
for scanner.Scan() {  // <-- Exits when Scan() returns false
    // ... process events ...
}
// defers run: close(events), close(stream)
```

**`scanner.Scan()` returns `false` when:**

1. **EOF (End of File)**
   - QEMU closes the socket connection gracefully
   - This is the normal case during VM shutdown

2. **Read Error (I/O error)**
   - Network/socket error
   - Connection reset by peer
   - Socket timeout (if configured)

3. **Buffer Overflow (`bufio.ErrTooLong`)**
   - A single line (JSON message) exceeds 64KB (default `MaxScanTokenSize`)
   - QEMU sends a very large response (complex state, error details, etc.)
   - **This would cause exit while VM is still running!**

4. **`monitor.Disconnect()` Called**
   - EVE calls `defer monitor.Disconnect()` in `qmpEventHandler`
   - This closes the underlying socket: `mon.c.Close()`
   - Causes `scanner.Scan()` to return `false` with EOF
   - **But this is called on handler exit, not while running**

### The Root Cause: Socket File Reuse on VM Restart (CONFIRMED)

**Detailed Timeline with Function Purposes:**

**Phase 1: VM Running Normally (16:17:13 - 16:29:41)**

```
16:17:13 - KvmContext.Start() launches QEMU for domain "42249309-...1.2"
           Creates socket directory: /run/hypervisor/kvm/42249309-...1.2/
           Creates two sockets:
           - qmp (executor) - for sending commands TO QEMU
           - listener.qmp - for receiving events FROM QEMU
           
16:17:19 - qmpEventHandler goroutine starts
           - Connects to listener.qmp socket
           - go-qemu library spawns listen() goroutine that reads events
           - Handler enters infinite loop waiting for events
           - Receives RESUME event (VM started successfully)
           
16:17:19 to 16:29:41 - VM runs normally
           Handler receives periodic events: NIC_RX_FILTER_CHANGED, RTC_CHANGE, etc.
```

**Phase 2: VM Shutdown Triggered (16:29:41)**

```
16:29:41.864 - STOP event received (QEMU preparing to shut down)

16:29:41.866 - SHUTDOWN event received with reason "host-qmp-quit"
               This triggers the handler's SHUTDOWN case:
               
               case "SHUTDOWN":
                   execStop(executorSocket)   // <-- BLOCKING CALL #1
                   execQuit(executorSocket)   // <-- BLOCKING CALL #2
```

**Why execStop() and execQuit() are called:**
- `execStop()` sends QMP `{"execute": "stop"}` command - pauses vCPUs (freezes the VM)
- `execQuit()` sends QMP `{"execute": "quit"}` command - terminates QEMU process
- These are called to ensure clean VM termination after receiving SHUTDOWN event
- Both call `execRawCmd(socket, cmd, true)` with `doRetry=true`

**Why they BLOCK for so long (~18 seconds each):**

Looking at `execRawCmd()`:

```go
const (
    sockTimeout   = 10 * time.Second  // Socket connection timeout
    qmpRetries    = 5                  // Number of retries
    qmpRetrySleep = 3 * time.Second   // Sleep between retries
)

func execRawCmd(socket, cmd string, doRetry bool) ([]byte, error) {
    var retry int
    if doRetry {
        retry = qmpRetries  // retry = 5
    }
    
    // LOOP 1: Try to create socket monitor (up to 5 retries)
    for retry >= 0 {
        monitor, err = qmp.NewSocketMonitor("unix", socket, sockTimeout)
        if err != nil {
            retry--
            time.Sleep(qmpRetrySleep)  // Sleep 3 seconds
            continue
        }
        break
    }
    // If socket file doesn't exist, each NewSocketMonitor() fails instantly
    // Then sleeps 3 sec, retries... Total: 5 retries × 3 sec = 15 seconds
    
    // LOOP 2: Try to connect (up to remaining retries)
    for retry >= 0 {
        if err = monitor.Connect(); err != nil {
            retry--
            time.Sleep(qmpRetrySleep)  // Sleep 3 seconds
            continue
        }
        defer monitor.Disconnect()
        break
    }
    
    return monitor.Run([]byte(cmd))
}
```

**The blocking happens because:**
- When SHUTDOWN is received, QEMU is already shutting down or has exited
- The `qmp` socket file (executor socket) is gone or about to be gone
- `NewSocketMonitor()` fails with "no such file or directory"
- Each failure → sleep 3 seconds → retry (up to 5 times)
- **Total blocking time per function: ~15-18 seconds**
- **Both functions combined: ~30-36 seconds**

**Critical observation:**
The functions use the `qmp` (executor) socket, NOT the `listener.qmp` socket.
But the handler holds a connection to `listener.qmp` which has its own go-qemu 
`listen()` goroutine that closes `eventChan` when the socket connection drops.

**Questionable design note:**
The SHUTDOWN event means QEMU is ALREADY shutting down (reason: "host-qmp-quit" or 
"guest-shutdown"). Calling `execStop()` + `execQuit()` at this point seems redundant:
- QEMU may already be gone (socket doesn't exist)
- These calls will just retry and timeout
- Meanwhile, the handler is blocked for 30+ seconds
- This creates the window for the race condition

This could be a secondary issue to investigate: should the handler just exit 
on SHUTDOWN instead of trying to send more commands?

**Phase 3: Parallel Cleanup (16:29:42 - 16:30:12)**

While the OLD handler is blocked in execStop()/execQuit(), OTHER parts of EVE are cleaning up:

```
16:29:42.907 - Cleanup() calls waitForQmp(domainName, false)
               Purpose: Wait until QMP socket disappears (confirms QEMU exited)
               
16:29:59.870 - OLD handler's execStop() finally fails after ~18 sec
               Error: "dial unix .../qmp: connect: no such file or directory"
               Now execQuit() starts its own 18-second retry loop...
               
16:30:12.915 - waitForQmp(false) completes - QMP socket is gone
               Cleanup() then calls: os.RemoveAll(kvmStateDir + domainName)
               This DELETES the entire socket directory!
               
               At this point:
               - OLD handler is STILL blocked in execQuit() (has 5 more seconds)
               - Socket directory is GONE
               - OLD handler's go-qemu channel is CLOSED (socket disappeared)
```

**Phase 4: VM Restart (16:30:15 - 16:30:16)**

```
16:30:15.xxx - Eden sends "pod start" command
               zedmanager receives config with Activate=true
               
16:30:16.564 - KvmContext.Start() launches NEW QEMU with SAME domain ID ".1.2"
               Creates NEW socket directory at SAME path:
               /run/hypervisor/kvm/42249309-...1.2/
               Creates NEW sockets: qmp, listener.qmp
               
16:30:16.831 - NEW qmpEventHandler goroutine starts
               Connects to NEW listener.qmp socket
               Receives RESUME event - new VM running!
               
16:30:17.345 - NEW handler receives RTC_CHANGE - new VM working fine
```

**Why domain ID ".1.2" is reused:**

Domain name format: `<UUID>.<Version>.<AppNum>` (from `GetTaskName()`)
- `42249309-29ae-4281-bef2-e0031d4a28ae` - App instance UUID (never changes)
- `.1` - Config Version from controller (changes only when controller updates config)
- `.2` - AppNum from networking (assigned once, stays same for app's lifetime)

On simple stop/start cycle (`eden pod stop` + `eden pod start`):
- UUID doesn't change (same app instance)
- Version doesn't change (no config update from controller)
- AppNum doesn't change (app keeps its network identity)
- Therefore, **domain name stays exactly the same!**

This means the socket path is **always** reused on stop/start:
`/run/hypervisor/kvm/42249309-...1.2/listener.qmp`

**Phase 5: OLD Handler Unblocks - FLOOD STARTS (16:30:17.874)**

```
16:30:17.874 - OLD handler's execQuit() finally fails after ~18 sec
               Error: "dial unix .../qmp: connect: no such file or directory"
               
               NOW the OLD handler continues to the next loop iteration:
               
               for {
                   // Check if socket file exists
                   if _, err := os.Stat(listenerSocket); err != nil {
                       return  // Would exit here if file gone
                   }
                   // BUT: NEW VM created the file! os.Stat SUCCEEDS!
                   
                   select {
                   case event := <-eventChan:
                       // OLD channel is CLOSED (was closed at ~16:29:42)
                       // Reading from closed channel returns ZERO VALUE instantly!
                       // event.Event = "" (empty string)
                       
                       switch event.Event {
                       case "SHUTDOWN":
                           // Not matched
                       default:
                           // MATCHED! Logs "Unhandled event: " with empty string
                           logrus.Warnf("Unhandled event: %s", event.Event)
                       }
                   }
                   // Immediately loops back, os.Stat passes, reads zero value again...
               }
               
16:30:17.874+ - INFINITE LOOP at ~10,000 messages/second
                58,530 empty event messages logged in ~5.4 seconds
                
16:30:18.345 - Meanwhile, NEW handler receives RTC_CHANGE normally
               (Two handlers running: OLD flooding, NEW working fine)
```

**Why the empty events are NOT from new QEMU:**

The OLD and NEW handlers are completely separate:
- OLD handler has `eventChan` from OLD go-qemu connection (CLOSED)
- NEW handler has `eventChan` from NEW go-qemu connection (ACTIVE)

When you read from a **closed** Go channel:
```go
event := <-eventChan  // Returns zero value immediately, never blocks
```
For `Event{Event: string, Data: map, Timestamp: struct}`:
- `event.Event` = `""` (empty string - zero value of string)
- This is NOT a QMP event, it's Go's closed-channel behavior!

**Why os.Stat cannot detect this:**

```go
os.Stat("/run/hypervisor/kvm/42249309-...1.2/listener.qmp")
```
This only checks: "Does a file exist at this path?"
It CANNOT distinguish between:
- "The socket I connected to" (OLD - deleted, recreated by NEW VM)
- "A different socket at the same path" (NEW - belongs to new QEMU)

The file exists (NEW VM created it), so os.Stat returns success!

**The ONLY fix - check channel closure:**

```go
case event, ok := <-eventChan:
    if !ok {
        // Channel closed - MY connection is dead
        // Doesn't matter if new VM created new socket
        return
    }
```

This works because:
- Each handler has its OWN channel
- Channel closure is handler-specific
- Cannot be fooled by socket file reuse

### Why This Happens on 14.5-stable (and Likely Others)

This is **NOT** 14.5-specific - it's a latent bug that can happen on any version when:
1. VM is stopped and restarted quickly
2. Domain ID is reused (same `.1.2` suffix)
3. Socket path is reused before old handler exits

The test on 14.5 exposed this because:
- USB boot priority tests do rapid stop/start cycles
- The timing happened to trigger the race condition
- Other branches may also have this bug but didn't hit the timing

## Root Cause Confirmed

The bug is **NOT** 14.5-specific. It's a race condition that occurs when:
1. A qmpEventHandler is running for a VM
2. VM shuts down → handler's go-qemu channel closes
3. VM restarts with same domain ID before handler exits
4. New VM creates new socket file at same path
5. Old handler's `os.Stat` check passes (new socket exists)
6. Old handler loops forever on closed channel

## Fix Required

The fix must check if the channel is closed:

```go
case event, ok := <-eventChan:
    if !ok {
        // Channel closed - QMP connection lost
        return
    }
```

This is the **ONLY** reliable way to detect connection loss, since `os.Stat(listenerSocket)` cannot distinguish between old and new socket files with the same path.

## Next Steps

1. ✅ Root cause identified and confirmed
2. Apply fix: Check channel closure in `qmpEventHandler`
3. Test fix with rapid VM stop/start cycles
4. Consider also checking for stale handlers when starting new VM

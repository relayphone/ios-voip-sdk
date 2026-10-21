# Fast-probe launcher acknowledgement

**Measured synthetic red:** a real child process emitted `done` before its delayed launcher PID header. The old supervisor invoked termination before the acknowledgement, received exit code 9, then replaced that failure with a PID mismatch. [The recorded receipt](red.json) identifies the runner base commit.

**Measured synthetic green:** all [56 harness controls](green.json) pass, including seven actual subprocess cases for a delayed acknowledgement, no acknowledgement before the deadline, mismatched and duplicate PIDs, EOF without an acknowledgement, termination failure and cleanup failure. Existing unbound runner cases still pass. The supervisor waits on output under the original deadline; it adds no delay. Primary errors remain visible when identity validation also fails. [Verification](verification.json) binds the outputs to the changed sources.

**Proposed hosted acceptance:** rerun the ABI lane on the integrated source. No native build or simulator was run for this supervisor fix.

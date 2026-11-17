import Darwin

// Own the simulator process group before replacing this executable with xctest.
let pid = getpid()
guard CommandLine.argc > 1, getpgrp() == pid || setpgid(0, 0) == 0 else { _exit(125) }
let receipt = "SIMULATOR_TEST_PROCESS \(pid)\n"
receipt.withCString { _ = write(STDOUT_FILENO, $0, strlen($0)) }
execv(CommandLine.arguments[1], CommandLine.unsafeArgv.advanced(by: 1))
_exit(126)

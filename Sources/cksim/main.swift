// The simulator runtime's command-line tool, which runs on the Mac that hosts the simulator.
#if os(macOS)
  import CKSimTool

  await CKSimTool.main()
#endif

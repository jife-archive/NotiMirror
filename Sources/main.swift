import AppKit

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.accessory)

    // pkill 등으로 SIGTERM을 받아도 applicationWillTerminate가 불리도록 해서
    // 배너 신호용 log stream 프로세스가 혼자 남지 않게 한다.
    signal(SIGTERM, SIG_IGN)
    let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    terminationSource.setEventHandler { app.terminate(nil) }
    terminationSource.resume()

    withExtendedLifetime((delegate, terminationSource)) {
        app.run()
    }
}

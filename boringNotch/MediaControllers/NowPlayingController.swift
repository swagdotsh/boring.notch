//
//  NowPlayingController.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import AppKit
import Combine
import Foundation

final class NowPlayingController: ObservableObject, MediaControllerProtocol {
    func updatePlaybackInfo() async {
        await fetchFavoriteStateIfSupported()
    }

    // MARK: - Properties
    @Published private(set) var playbackState: PlaybackState = .init(
        bundleIdentifier: "", title: "", artist: "", album: ""
    )

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool {
        let bundleID = playbackState.bundleIdentifier
        return bundleID == "com.apple.Music" || bundleID == "com.spotify.client"
    }

    var supportsFavorite: Bool {
        let bundleID = playbackState.bundleIdentifier
        return bundleID == "com.apple.Music"
    }

    func setFavorite(_ favorite: Bool) async {
        let bundleID = playbackState.bundleIdentifier
        
        if bundleID == "com.apple.Music" {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
            if !runningApps.isEmpty {
                let script = """
                tell application "Music"
                    try
                        set favorited of current track to \(favorite ? "true" : "false")
                    end try
                end tell
                """
                try? await AppleScriptHelper.executeVoid(script)
            }
        }
        
        // Update the favorite state locally and fetch updated info
        try? await Task.sleep(for: .milliseconds(150))
        await updatePlaybackInfo()
    }

    private var lastMusicItem:
        (title: String, artist: String, album: String, duration: TimeInterval, artworkData: Data?)?

    // MARK: - Media Remote Functions
    private let mediaRemoteBundle: CFBundle
    private let MRMediaRemoteSendCommandFunction: @convention(c) (Int, AnyObject?) -> Void
    private let MRMediaRemoteSetElapsedTimeFunction: @convention(c) (Double) -> Void
    private let MRMediaRemoteSetShuffleModeFunction: @convention(c) (Int) -> Void
    private let MRMediaRemoteSetRepeatModeFunction: @convention(c) (Int) -> Void

    private var process: Process?
    private var pipeHandler: JSONLinesPipeHandler?
    private var streamTask: Task<Void, Never>?

    // MARK: - Initialization
    init?() {
        guard
            let bundle = CFBundleCreate(
                kCFAllocatorDefault,
                NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")),
            let MRMediaRemoteSendCommandPointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSendCommand" as CFString),
            let MRMediaRemoteSetElapsedTimePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetElapsedTime" as CFString),
            let MRMediaRemoteSetShuffleModePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetShuffleMode" as CFString),
            let MRMediaRemoteSetRepeatModePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetRepeatMode" as CFString)
            
        else { return nil }

        mediaRemoteBundle = bundle
        MRMediaRemoteSendCommandFunction = unsafeBitCast(
            MRMediaRemoteSendCommandPointer, to: (@convention(c) (Int, AnyObject?) -> Void).self)
        MRMediaRemoteSetElapsedTimeFunction = unsafeBitCast(
            MRMediaRemoteSetElapsedTimePointer, to: (@convention(c) (Double) -> Void).self)
        MRMediaRemoteSetShuffleModeFunction = unsafeBitCast(
            MRMediaRemoteSetShuffleModePointer, to: (@convention(c) (Int) -> Void).self)
        MRMediaRemoteSetRepeatModeFunction = unsafeBitCast(
            MRMediaRemoteSetRepeatModePointer, to: (@convention(c) (Int) -> Void).self)

        Task { await setupNowPlayingObserver() }
    }

    deinit {
        streamTask?.cancel()
        
        if let pipeHandler = self.pipeHandler {
            Task { await pipeHandler.close()
            }
        }
        
        if let process = self.process {
            if process.isRunning {
                process.terminate()
            }
        }

        self.process = nil
        self.pipeHandler = nil
    }

    // MARK: - Protocol Implementation
    func play() async {
        MRMediaRemoteSendCommandFunction(0, nil)
    }

    func pause() async {
        MRMediaRemoteSendCommandFunction(1, nil)
    }

    func togglePlay() async {
        MRMediaRemoteSendCommandFunction(2, nil)
    }

    func nextTrack() async {
        MRMediaRemoteSendCommandFunction(4, nil)
    }

    func previousTrack() async {
        MRMediaRemoteSendCommandFunction(5, nil)
    }

    func seek(to time: Double) async {
        MRMediaRemoteSetElapsedTimeFunction(time)
    }

    func isActive() -> Bool {
        return true
    }
    
    func toggleShuffle() async {
        // MRMediaRemoteSendCommandFunction(6, nil)
        MRMediaRemoteSetShuffleModeFunction(playbackState.isShuffled ? 1 : 3)
        playbackState.isShuffled.toggle()
    }
    
    func toggleRepeat() async {
        // MRMediaRemoteSendCommandFunction(7, nil)
        let newRepeatMode = (playbackState.repeatMode == .off) ? 3 : (playbackState.repeatMode.rawValue - 1)
        playbackState.repeatMode = RepeatMode(rawValue: newRepeatMode) ?? .off
        MRMediaRemoteSetRepeatModeFunction(newRepeatMode)
    }
    
    func setVolume(_ level: Double) async {
        // MediaRemote framework doesn't provide direct volume control for the active audio session
        // As a workaround, try to control the currently active music app directly
        let clampedLevel = max(0.0, min(1.0, level))
        let volumePercentage = Int(clampedLevel * 100)
        
        let bundleID = playbackState.bundleIdentifier
        if !bundleID.isEmpty {
            if bundleID == "com.apple.Music" {
                let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
                if !runningApps.isEmpty {
                    let script = "tell application \"Music\" to set sound volume to \(volumePercentage)"
                    try? await AppleScriptHelper.executeVoid(script)
                }
            } else if bundleID == "com.spotify.client" {
                let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client")
                if !runningApps.isEmpty {
                    let script = "tell application \"Spotify\" to set sound volume to \(volumePercentage)"
                    try? await AppleScriptHelper.executeVoid(script)
                }
            }
        }
        
        playbackState.volume = clampedLevel
    }
    
    // MARK: - Setup Methods
    private func setupNowPlayingObserver() async {
        let process = Process()
        guard
            let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
            let frameworkPath = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework")
        else {
            NSLog("Now Playing: adapter resources are missing")
            return
        }
        
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkPath, "stream", "--no-diff"]
        
        let pipeHandler = JSONLinesPipeHandler()
        process.standardOutput = await pipeHandler.getPipe()
        
        self.process = process
        self.pipeHandler = pipeHandler

        do {
            try process.run()
            try await pipeHandler.closeWriter()
            streamTask = Task { [weak self, pipeHandler] in
                await pipeHandler.readJSONLines(as: NowPlayingUpdate.self) { [weak self] update in
                    await self?.handleAdapterUpdate(update)
                }
                await pipeHandler.close()
                guard !Task.isCancelled else { return }
                NSLog("Now Playing: adapter stream ended; reconnecting")
                if process.isRunning { process.terminate() }
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch { return }
                await self?.setupNowPlayingObserver()
            }
        } catch {
            NSLog("Now Playing: failed to launch adapter: %@", String(describing: error))
        }
    }

    @MainActor
    private func handleAdapterUpdate(_ update: NowPlayingUpdate) {
        playbackState = update.applying(to: playbackState)
    }

     private func fetchFavoriteStateIfSupported() async {
         let bundleID = playbackState.bundleIdentifier
        
         if bundleID == "com.apple.Music" {
             let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
             guard !runningApps.isEmpty else { return }
             
             let script = """
             tell application "Music"
                 try
                     return favorited of current track
                 on error
                     return false
                 end try
             end tell
             """
             if let result = try? await AppleScriptHelper.execute(script) {
                 var updated = self.playbackState
                 updated.isFavorite = result.booleanValue
                 self.playbackState = updated
             }
         }
     }
    
}

struct NowPlayingUpdate: Codable {
    let payload: NowPlayingPayload
    let diff: Bool?
}

struct NowPlayingPayload: Codable {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let shuffleMode: Int?
    let repeatMode: Int?
    let artworkData: String?
    let timestamp: String?
    let playbackRate: Double?
    let playing: Bool?
    let parentApplicationBundleIdentifier: String?
    let bundleIdentifier: String?
    let volume: Double?
}

extension NowPlayingUpdate {
    func applying(to previous: PlaybackState, at now: Date = Date()) -> PlaybackState {
        let isDiff = diff == true
        var state = isDiff ? previous : PlaybackState(bundleIdentifier: "")
        let payload = payload
        state.title = payload.title ?? (isDiff ? previous.title : "")
        state.artist = payload.artist ?? (isDiff ? previous.artist : "")
        state.album = payload.album ?? (isDiff ? previous.album : "")
        state.bundleIdentifier = payload.parentApplicationBundleIdentifier
            ?? payload.bundleIdentifier ?? (isDiff ? previous.bundleIdentifier : "")
        state.duration = payload.duration ?? (isDiff ? previous.duration : 0)
        state.isPlaying = payload.playing ?? (isDiff ? previous.isPlaying : false)
        state.playbackRate = payload.playbackRate ?? (isDiff ? previous.playbackRate : 1)
        state.lastUpdated = payload.timestamp.flatMap { ISO8601DateFormatter().date(from: $0) } ?? now

        if let elapsedTime = payload.elapsedTime {
            state.currentTime = elapsedTime
        } else if isDiff {
            let elapsed = previous.isPlaying
                ? max(0, state.lastUpdated.timeIntervalSince(previous.lastUpdated)) * previous.playbackRate : 0
            state.currentTime = previous.currentTime + elapsed
        } else {
            state.currentTime = 0
        }
        state.currentTime = max(0, state.currentTime)
        if state.duration > 0 {
            state.currentTime = min(state.currentTime, state.duration)
        }
        if let mode = payload.shuffleMode { state.isShuffled = mode != 1 }
        if let mode = payload.repeatMode { state.repeatMode = RepeatMode(rawValue: mode) ?? .off }
        if let artwork = payload.artworkData {
            state.artwork = Data(base64Encoded: artwork.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        state.volume = payload.volume ?? (isDiff ? previous.volume : 0.5)
        return state
    }
}

actor JSONLinesPipeHandler {
    private let pipe = Pipe()
    private var continuation: AsyncStream<Data>.Continuation?

    func getPipe() -> Pipe { pipe }

    func closeWriter() throws {
        try pipe.fileHandleForWriting.close()
    }

    func readJSONLines<T: Decodable>(as type: T.Type, onLine: @escaping (T) async -> Void) async {
        let handle = pipe.fileHandleForReading
        let stream = AsyncStream<Data> { continuation in
            self.continuation = continuation
            handle.readabilityHandler = { handle in
                do {
                    let data = try handle.read(upToCount: 65_536) ?? Data()
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        continuation.finish()
                    } else {
                        continuation.yield(data)
                    }
                } catch {
                    handle.readabilityHandler = nil
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
        var buffer = Data()
        for await chunk in stream {
            guard !Task.isCancelled else { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                await decode(line, as: type, onLine: onLine)
            }
        }
        if !Task.isCancelled && !buffer.isEmpty {
            await decode(buffer, as: type, onLine: onLine)
        }
        handle.readabilityHandler = nil
        continuation = nil
    }

    private func decode<T: Decodable>(_ data: Data, as type: T.Type, onLine: @escaping (T) async -> Void) async {
        guard !data.isEmpty else { return }
        do {
            await onLine(try JSONDecoder().decode(type, from: data))
        } catch {
            NSLog("Now Playing: could not decode adapter update: %@", String(describing: error))
        }
    }

    func close() {
        continuation?.finish()
        continuation = nil
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }
}

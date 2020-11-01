//
//  AudioPlayer.swift
//  AGAudioPlayer
//
//  Created by Jacob Farkas on 10/31/20.
//  Copyright © 2020 Alec Gorge. All rights reserved.
//

import Foundation
import AVFoundation

public class AudioPlayer : NSObject {
    
    // Defines what should happen when the user presses the << button
    public enum BackwardsPlayerStyle {
        case restartTrack       // Restart the track from the beginning
                                // (unless the current track has been playing for < 5s, in which case the previous track is selected)
        case alwaysPrevious     // Go to the previous track
    }

    public enum RedrawReason {
        case buffering
        case playing
        case stopped
        case paused
        case error
        case trackChanged
        case queueChanged
    }
    
    // MARK: Initializer
    public required init(queue: AGAudioPlayerUpNextQueue) {
        _queue = queue
        super.init()
        
        _queue.delegate = self
        setupBASS()
    }
    
    deinit {
        teardownBASS()
    }
    
    //MARK: - Public Vars
    public var queue : AGAudioPlayerUpNextQueue! { get { return _queue } }
    
    public weak var delegate : AudioPlayerDelegate? = nil
    public weak var loggingDelegate : LoggingDelegate? = nil
    
    //MARK: - Playback Properties
    public var shuffleEnabled: Bool = false {
        didSet {
            if (shuffleEnabled) {
                let idx = (currentIndex >= 0) ? UInt(currentIndex) : 0
                queue.shuffleStarting(at: idx)
            }
            
            // restore the current index to point to the right track for visual purposes
            if let currentlyPlayingGUID = currentItem?.playbackGUID {
                _currentIndex = queue.properPosition(for: currentlyPlayingGUID, forShuffleEnabled: shuffleEnabled)
            }
            
            bass.nextTrackMayHaveChanged()
        }
    }
    
    public var loopQueue: Bool = false {
        didSet {
            bass.nextTrackMayHaveChanged()
        }
    }
    public var loopItem: Bool = false {
        didSet {
            bass.nextTrackChanged()
        }
    }
    
    public var backwardStyle: BackwardsPlayerStyle = .restartTrack
    
    //MARK: - Playback Control
    public func resume() {
        if (!isPlaying) {
            bass.resume()
        }
    }
    
    public func pause() {
        if (isPlaying) {
            bass.pause()
        }
    }
    
    public func stop() {
        bass.stop()
    }
    
    public func forward() -> Bool {
        let nextIndex = self.nextIndex
        guard (nextIndex != NSNotFound) else {
            return false
        }
        
        bass.resume()
        currentIndex = nextIndex
        
        return true
    }
    
    public func backward() -> Bool {
        if (elapsed < 5.0 || backwardStyle == .alwaysPrevious) {
            let previousIndex = self.previousIndex
            guard (previousIndex != NSNotFound) else {
                return false
            }
            
            bass.resume()
            currentIndex = previousIndex
        } else {
            self.seek(to: 0.0)
        }
        return true
    }
    
    public func seek(to time : TimeInterval) {
        self.seek(to: Float(time) / Float(duration))
    }
    
    public func seek(to percent: Float) {
        bass.seek(toPercent: percent)
    }
    
    public func playItem(atIndex idx: UInt) {
        currentIndex = NSInteger(idx)
        self.resume()
    }
    
    public var volume : Float {
        get { return bass.volume }
        set(newVolume) { bass.volume = newVolume }
    }
    
    //MARK: - Playback State
    public var isPlaying : Bool { get { return bass.currentState == .playing } }
    public var isBuffering : Bool { get { return bass.currentState == .stalled } }
    public var isPlayingFirstItem : Bool {
        get {
            if (self.loopItem) {
                return false
            }
            
            guard let currentItem = self.currentItem else {
                return false
            }
            
            return queue.properPosition(for: currentItem.playbackGUID, forShuffleEnabled: shuffleEnabled) == (queue.count - 1)
        }
    }
    
    public var isPlayingLastItem : Bool {
        get {
            if (self.loopItem) {
                return false
            }
            
            guard let currentItem = self.currentItem else {
                return false
            }
            
            return queue.properPosition(for: currentItem.playbackGUID, forShuffleEnabled: shuffleEnabled) == 0
        }
    }
    
    public var duration: TimeInterval { get { return bass.currentDuration } }
    public var elapsed: TimeInterval { get { return bass.elapsed } }
    public var percentElapsed : Float { get { return Float(elapsed) / Float(duration) } }
    
    //MARK: - Queue position
    public var currentIndex: NSInteger {
        get { return _currentIndex }
        set(newCurrentIndex) {
            let queue = self.queue.properQueue(forShuffleEnabled: shuffleEnabled)
            if (newCurrentIndex < 0 || newCurrentIndex > queue.count) {
                return
            }
            
            let item = queue[newCurrentIndex]
            bass.play(item.playbackURL, withIdentifier: item.playbackGUID)
            _currentIndex = newCurrentIndex
            bass.nextTrackMayHaveChanged()
            
            self.delegate?.uiNeedsRedraw(audioPlayer: self, reason: .trackChanged)
        }
    }
    
    // returns NSNotFound when last item is playing
    public var nextIndex: NSInteger {
        get {
            return self.nextIndex(afterIndex:currentIndex)
        }
    }
    
    // returns NSNotFound when the first item playing
    public var previousIndex: NSInteger {
        get {
            // looping a single track
            if (loopItem) {
                return currentIndex;
            }
            
            // last song in the current queue
            if (currentIndex == 0) {
                // start the current queue from the end
                if(loopQueue) {
                    return queue.count - 1;
                }
                // reached the beginning of all tracks, accross both queues
                else {
                    return NSNotFound;
                }
            }
            
            // there are still songs in the current queue
            return currentIndex - 1;
        }
    }
    
    //MARK: - Queue Items
    public var currentItem: AGAudioItem? {
        get {
            if (currentIndex == -1 || currentIndex >= queue.count) {
                return nil
            }
            
            return queue.properQueue(forShuffleEnabled: shuffleEnabled)[currentIndex]
        }
    }
    
    // returns nil when last item is playing
    public var nextItem: AGAudioItem? {
        get {
            return nextItem(afterIndex: currentIndex)
        }
    }
    
    // returns nil when the first item is playing
    public var previousItem: AGAudioItem? {
        get {
            guard previousIndex != NSNotFound else {
                return nil
            }
            return queue[UInt(previousIndex)]
        }
    }
    
    //MARK: - Private item/index getters
    private func nextIndex(afterIndex idx: NSInteger) -> NSInteger {
        // looping a single track
        if (loopItem) {
            return idx;
        }
        
        // last song in the current queue
        if ((idx + 1) == queue.count) {
            // start the current queue from the beginning
            if(loopQueue) {
                return 0;
            }
            // reached the end of all tracks, accross both queues
            else {
                return NSNotFound;
            }
        }
        
        return (idx + 1);
    }
    
    private func nextItem(afterIndex idx: NSInteger) -> AGAudioItem? {
        let nextIndex = self.nextIndex(afterIndex: idx)
        
        if (nextIndex == NSNotFound || nextIndex >= queue.count) {
            return nil
        }
        
        return queue.properQueue(forShuffleEnabled: shuffleEnabled)[nextIndex]
    }
    
    private func nextIndex(afterIdentifier identifier: UUID) -> NSInteger {
        let idx = queue.properPosition(for: identifier, forShuffleEnabled: shuffleEnabled)
        guard (idx != NSNotFound) else { return NSNotFound }
        
        return nextIndex(afterIndex: idx)
    }
    
    private func nextItem(afterIdentifier identifier: UUID) -> AGAudioItem? {
        let idx = nextIndex(afterIdentifier: identifier)
        guard (idx != NSNotFound) else { return nil }
        
        return queue.properQueue(forShuffleEnabled: shuffleEnabled)[idx]
    }
    
    //MARK: - BASS Management
    private func setupBASS() {
        self.bass = ObjectiveBASS();
        
        self.bass.delegate = self;
        self.bass.dataSource = self;
    }

    private func prepareAudioSession() {
        self.bass.prepareAudioSession();
    }

    private func teardownBASS() {
        NotificationCenter.default.removeObserver(self)
        
        self.bass = nil;
    }
    
    //MARK: - Debugging
    private func debug(_ str : String) {
        loggingDelegate?.loggedLine(audioPlayer: self, line: str)
    }
    
    //MARK: - Private Vars
    private var bass: ObjectiveBASS!
    private var _queue : AGAudioPlayerUpNextQueue!
    private var _currentIndex: NSInteger = NSNotFound
    private var _shuffleEnabled: Bool = false
}

//MARK: - Description
extension AudioPlayer {
    public override var description: String {
        let stateString = stringForState(bass.currentState)
        let playbackString = String(format: "%.2f/%.2f (%.2f%%)", elapsed, duration, percentElapsed * 100.0)
        return "AudioPlayer \(String(format: "%p", self)): [state: \(stateString), shuffle: \(shuffleEnabled), loop: \(loopItem || loopQueue), currentItem (idx \(currentIndex)): \(currentItem?.description ?? "<none>"), playback: \(playbackString)"
    }
    
    private func stringForState(_ state: BassPlaybackState) -> String {
        switch (state) {
            case .stopped: return "Stopped"
            case .stalled: return "Buffering"
            case .playing: return "Playing"
            case .paused: return "Paused"
            default:
                return "Unknown state: \(state)"
        }
    }
}

//MARK: - Delegates
public protocol AudioPlayerDelegate : AnyObject {
    func uiNeedsRedraw(audioPlayer : AudioPlayer, reason : AudioPlayer.RedrawReason)
    func errorRaised(audioPlayer: AudioPlayer, error: Error, url : URL)
    func downloadedBytesForActiveTrack(audioPlayer: AudioPlayer, downloadedBytes: UInt64, totalBytes: UInt64)
    func progressChanged(audioPlayer: AudioPlayer, elapsed: TimeInterval, totalDuration: TimeInterval)
    func audioSessionSetUp(audioPlayer: AudioPlayer)
    
    // Optional
    func beginInterruption(audioPlayer: AudioPlayer)
    func endInterruption(audioPlayer: AudioPlayer, shouldResume: Bool)
}

public protocol LoggingDelegate : AnyObject {
    func loggedLine(audioPlayer: AudioPlayer, line: String)
    func loggedErrorLine(audioPlayer: AudioPlayer, line: String)
}

extension AudioPlayerDelegate {
    public func beginInterruption(audioPlayer: AudioPlayer) { }
    public func endInterruption(audioPlayer: AudioPlayer, shouldResume: Bool) { }
}


//MARK: - BASS DataSource
extension AudioPlayer : ObjectiveBASSDataSource {
    /// url and identifier are self.currentlyPlayingURL and currentlyPlayingIdentifier
    public func bassisPlayingLastTrack(_ bass: ObjectiveBASS, with url: URL, andIdentifier identifier: UUID) -> Bool {
        return (queue.count - 1) == queue.properPosition(for: identifier, forShuffleEnabled: shuffleEnabled)
    }
    
    public func bassNextTrackIdentifier(_ bass: ObjectiveBASS, after url: URL, withIdentifier identifier: UUID) -> UUID {
        return nextItem(afterIdentifier: identifier)?.playbackGUID ?? UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    }

    public func bassLoadNextTrackURL(_ bass: ObjectiveBASS, forIdentifier identifier: UUID) {
        let url = queue.item(for: identifier).playbackURL
        bass.nextTrackURLLoaded(url)
    }
}

//MARK: - BASS Delegate
extension AudioPlayer : ObjectiveBASSDelegate {
    public func bassDownloadProgressChanged(_ forActiveTrack: Bool, downloadedBytes: UInt64, totalBytes: UInt64) {
        delegate?.downloadedBytesForActiveTrack(audioPlayer: self, downloadedBytes: downloadedBytes, totalBytes: totalBytes)
    }
    
    public func bassPlaybackProgressChanged(_ elapsed: TimeInterval, withTotalDuration totalDuration: TimeInterval) {
        delegate?.progressChanged(audioPlayer: self, elapsed: elapsed, totalDuration: totalDuration)
    }
    
    public func bassDownloadPlaybackStateChanged(_ state: BassPlaybackState) {
        switch state {
            case .paused:
                delegate?.uiNeedsRedraw(audioPlayer: self, reason: .paused)
            case .playing:
                delegate?.uiNeedsRedraw(audioPlayer: self, reason: .playing)
            case .stalled:
                delegate?.uiNeedsRedraw(audioPlayer: self, reason: .buffering)
            case .stopped:
                delegate?.uiNeedsRedraw(audioPlayer: self, reason: .stopped)
        @unknown default:
            fatalError()
        }
    }
    
    public func bassErrorStartingStream(_ error: Error, for url: URL, withIdentifier identifier: UUID) {
        delegate?.errorRaised(audioPlayer: self, error: error, url: url)
    }
    
    public func bassFinishedPlayingGUID(_ identifier: UUID, for url: URL) {
        if (currentItem?.playbackGUID == identifier) {
            _currentIndex = self.nextIndex
            
            delegate?.uiNeedsRedraw(audioPlayer: self, reason: .trackChanged)
        } else {
            debug("Finished playing something that wasn't the active track!? \(identifier) \(url)")
        }
    }
    
    public func bassAudioSessionSetUp() {
        delegate?.audioSessionSetUp(audioPlayer: self)
    }
    
    public func bassLoggedLine(_ line: String) {
        debug(line)
    }

    public func bassLoggedFailedAssertion(_ line: String) {
        if let loggingDelegate = loggingDelegate {
            loggingDelegate.loggedErrorLine(audioPlayer: self, line: line)
        } else {
            debug(line)
        }
    }
}

//MARK: - UpNextQueue Delegate
extension AudioPlayer : AGAudioPlayerUpNextQueueDelegate {
    public func upNextQueue(_ queue: AGAudioPlayerUpNextQueue, addedItem item: AGAudioItem, at idx: Int) {
        if (idx <= currentIndex) {
            _currentIndex += 1
        }
        
        bass.nextTrackMayHaveChanged()
        delegate?.uiNeedsRedraw(audioPlayer: self, reason: .queueChanged)
    }
    
    public func upNextQueue(_ queue: AGAudioPlayerUpNextQueue, removedItem item: AGAudioItem, from idx: Int) {
        if (idx == currentIndex) {
            currentIndex = idx
        } else {
            bass.nextTrackMayHaveChanged()
        }
        
        delegate?.uiNeedsRedraw(audioPlayer: self, reason: .queueChanged)
    }

    public func upNextQueue(_ queue: AGAudioPlayerUpNextQueue, movedItem item: AGAudioItem, from oldIndex: Int, to newIndex: Int) {
        if(oldIndex == self.currentIndex) {
            _currentIndex = newIndex;
        }
        else if(oldIndex < self.currentIndex && newIndex > self.currentIndex) {
            _currentIndex -= 1;
        }
        else if(oldIndex > self.currentIndex && newIndex <= self.currentIndex) {
            _currentIndex += 1;
        }
        
        bass.nextTrackMayHaveChanged()
        delegate?.uiNeedsRedraw(audioPlayer: self, reason: .queueChanged)
    }

    public func upNextQueueRemovedAllItems(_ queue: AGAudioPlayerUpNextQueue) {
        _currentIndex = -1
        stop()
    }
}

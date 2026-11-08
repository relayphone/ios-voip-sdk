/*
 *  Declarations copied from WebRTC's sdk/objc/components/audio/RTCAudioSession.h.
 *
 *  Copyright 2016 The WebRTC Project Authors. All rights reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

// Only the subset ios-voip-sdk calls. The implementation comes from whichever
// WebRTC framework the app links; see README.md in this directory.

#pragma once

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#import "RTCAudioSessionConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

@protocol VoIPRTCAudioSession <NSObject>

@property(nonatomic, readonly) BOOL isActive;
@property(nonatomic, assign) BOOL useManualAudio;
@property(nonatomic, assign) BOOL isAudioEnabled;

- (void)lockForConfiguration;
- (void)unlockForConfiguration;

- (void)audioSessionDidActivate:(AVAudioSession *)session;
- (void)audioSessionDidDeactivate:(AVAudioSession *)session;

- (BOOL)overrideOutputAudioPort:(AVAudioSessionPortOverride)portOverride
                          error:(NSError **)outError;
- (BOOL)setConfiguration:(id<VoIPRTCAudioSessionConfiguration>)configuration
                   error:(NSError **)outError;

@end

/// Class messages are dispatched dynamically; neither WebRTC class is linked by this module.
@protocol VoIPRTCAudioSessionClass <NSObject>
+ (id<VoIPRTCAudioSession>)sharedInstance;
@end

static inline id<VoIPRTCAudioSession> VoIPRTCAudioSessionSharedInstance(Class type) {
  return [(Class<VoIPRTCAudioSessionClass>)type sharedInstance];
}

NS_ASSUME_NONNULL_END

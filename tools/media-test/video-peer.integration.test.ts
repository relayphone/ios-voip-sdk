import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { test } from 'node:test';
import { dispose, LocalVideoTrack, Room, RoomEvent, TrackKind, TrackPublishOptions, TrackSource, VideoBufferType, VideoCodec, VideoFrame, VideoSource, VideoStream } from '@livekit/rtc-node';
import { startHarness } from './harness.ts';
import { deadline } from './fixture-runtime.ts';
import { VideoPeer } from './video-peer.ts';
import { assessVideo, type VideoSourceReceipt } from './video-observation.ts';
import { decodeVideoMarker, videoLuma, type VideoMarker } from './video-marker.ts';

test('real VP8 uplink decode, reverse source, held production and joined stop', {skip:process.env.VIDEO_PEER_INTEGRATION!=='1',timeout:90000}, async () => {
  const directory=mkdtempSync(join(tmpdir(),'video-peer-'));
  let harness:Awaited<ReturnType<typeof startHarness>>|undefined,peer:VideoPeer|undefined;
  const app=new Room();const source=new VideoSource(160,120),fixture=randomUUID();
  const reverse=Promise.withResolvers<VideoMarker>();let reverseReader:ReadableStreamDefaultReader<import('@livekit/rtc-node').VideoFrameEvent>|undefined;
  app.on(RoomEvent.TrackSubscribed, track=>{
    if(track.kind!==TrackKind.KIND_VIDEO)return;
    reverseReader=new VideoStream(track).getReader();
    void (async()=>{const first=await reverseReader!.read();assert.ok(!first.done);const frame=first.value.frame.convert(VideoBufferType.I420);reverse.resolve(decodeVideoMarker(frame.data,frame.width,frame.height));})().catch(reverse.reject);
  });
  try {
    harness=await startHarness(directory,fixture);await harness.act({type:'publish',markerId:'video-audio-load'});
    const credentials=harness.credentials('app');await app.connect(credentials.url,credentials.token);
    peer=await harness.openVideo(randomUUID());await peer.observe('app',1);
    const track=LocalVideoTrack.createVideoTrack('synthetic-camera',source);
    const publication=await app.localParticipant!.publishTrack(track,new TrackPublishOptions({source:TrackSource.SOURCE_CAMERA,videoCodec:VideoCodec.VP8,simulcast:false}));
    const ledger:VideoSourceReceipt={participant:'app',publication:publication.sid!,clockID:'native-test',generated:[],pacingTaskJoined:false,postStopCaptureRejects:0,skippedTicks:0,rejectedSubmissions:0};
    let stopped=false;
    const capture=()=>{if(stopped){ledger.postStopCaptureRejects++;throw Error('Stopped');}const marker:VideoMarker={fixture,direction:0,epoch:1,counter:ledger.generated.length,sourceTimeUs:Math.floor(performance.now()*1000)};ledger.generated.push(marker);const data=new Uint8Array(160*120*3/2).fill(128);data.set(videoLuma(marker));source.captureFrame(new VideoFrame(data,160,120,VideoBufferType.I420),BigInt(marker.sourceTimeUs));};
    const anchor=performance.now();
    for(let i=0;i<30;i++){capture();await delay(100);}
    const stop=performance.now();stopped=true;ledger.stoppedAtUs=Math.ceil(stop*1000);ledger.finalCounter=ledger.generated.at(-1)!.counter;ledger.finalEpoch=1;ledger.pacingTaskJoined=true;
    assert.throws(capture);await app.localParticipant!.unpublishTrack(publication.sid!,false);await delay(1000);
    const receipt=peer.observation();assert.ok(receipt);
    const bracket={hostClockID:receipt.clockID,clockID:'native-test',nativeMs:anchor,sentMs:anchor,receivedMs:anchor};
    const result=assessVideo(receipt,ledger,{participant:'app',publication:publication.sid!,nativeAnchorMs:anchor,nativeBoundaryMs:stop,bracket,terminal:{...bracket,nativeMs:stop,sentMs:stop,receivedMs:stop}});
    assert.equal(result.onPassed,true,JSON.stringify(result));assert.equal(result.offPassed,true,JSON.stringify(result));
    await peer.publish(2);assert.equal((await deadline(5000,'Reverse decoded frame',()=>reverse.promise)).direction,1);
    await peer.hold();const generated=peer.sourceReceipt().generated.length;await delay(250);assert.ok(peer.sourceReceipt().generated.length>generated);
    const final=await peer.stop();assert.equal(final.pacingTaskJoined,true);assert.ok(final.postStopCaptureRejects>0);assert.equal(final.finalEpoch,2);
    const count=final.generated.length;await delay(150);assert.equal(peer.sourceReceipt().generated.length,count);
    await track.close(false);
  } finally {
    try {
      const results=await Promise.allSettled([reverseReader?.cancel(),harness?.stop(),app.disconnect(),source.close()]);
      assert.ok(results.every(r=>r.status==='fulfilled'),'Video integration cleanup failed');
    } finally { await dispose();rmSync(directory,{recursive:true,force:true}); }
  }
});

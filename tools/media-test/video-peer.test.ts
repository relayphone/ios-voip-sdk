import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { after, test } from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import { dispose, RoomEvent, TrackKind, TrackSource, type Room } from '@livekit/rtc-node';
import { VideoPeer } from './video-peer.ts';
after(async()=>{await dispose();});
function fixture(unpublish = async (_sid:string) => {}) {
  const pending=Promise.withResolvers<{sid:string}>(),unpublished:string[]=[];
  const handlers=new Map<string,(...args: unknown[])=>void>();
  const room={on(name:string,handler:(...args:unknown[])=>void){handlers.set(name,handler);},off(name:string){handlers.delete(name);},isConnected:true,localParticipant:{identity:'far-end',
    publishTrack:()=>pending.promise,unpublishTrack:async(sid:string)=>{unpublished.push(sid);await unpublish(sid);}}};
  return {peer:new VideoPeer(room as unknown as Room,randomUUID(),randomUUID()),pending,unpublished,handlers};
}
test('publish resolving during close is compensated and cannot start pacing', async()=>{
  const f=fixture();const publishing=f.peer.publish(1);const rejected=assert.rejects(publishing,/incomplete/);
  const closing=f.peer.close();f.pending.resolve({sid:'late'});
  await rejected;await closing;assert.deepEqual(f.unpublished,['late']);assert.equal(f.peer.status().publication,undefined);
  const generated=f.peer.status().generated;await delay(120);assert.equal(f.peer.status().generated,generated);
});
test('a publication resolving after failed bounded cleanup is still retired', async()=>{
  const f=fixture();const publishing=f.peer.publish(1);const rejected=assert.rejects(publishing,/incomplete/);
  await assert.rejects(f.peer.close(),/cleanup unconfirmed/);await rejected;
  f.pending.resolve({sid:'after-deadline'});await delay(30);
  assert.deepEqual(f.unpublished,['after-deadline']);assert.equal(f.peer.status().publication,undefined);
});
test('failed unpublish does not prevent disposal or allow another capture', async()=>{
  const f=fixture(async()=>{throw Error('Unpublish unavailable');});
  f.pending.resolve({sid:'published'});await f.peer.publish(1);
  await assert.rejects(f.peer.close(),/cleanup unconfirmed/);
  const generated=f.peer.status().generated;await delay(120);assert.equal(f.peer.status().generated,generated);
  assert.equal(f.peer.status().failed,true);assert.throws(()=>f.peer.sourceReceipt(),/failed/);
});

test('an invalid subscription permanently retires the armed phase', async()=>{
  const f=fixture();await f.peer.observe('app',1);
  const subscribed=f.handlers.get(RoomEvent.TrackSubscribed)!;
  subscribed({kind:TrackKind.KIND_VIDEO},{source:TrackSource.SOURCE_SCREENSHARE,sid:'wrong'},{identity:'app'});
  subscribed({kind:TrackKind.KIND_VIDEO},{source:TrackSource.SOURCE_CAMERA,sid:'later'},{identity:'app'});
  assert.equal(f.peer.status().failed,true);assert.equal(f.peer.observation(),undefined);await f.peer.close();
});

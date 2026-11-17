import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { test } from 'node:test';
import { decodeVideoMarker, inspectVideoImage, videoIdentity, videoLuma, type VideoMarker } from './video-marker.ts';
const marker: VideoMarker = {fixture:'01234567-89ab-cdef-0123-456789abcdef',direction:0,epoch:7,counter:0xffffffff,sourceTimeUs:Number.MAX_SAFE_INTEGER};
test('Swift and TypeScript share the exact pixel vector and digest', () => {
  assert.equal(createHash('sha256').update(videoLuma(marker)).digest('hex'),'94ba28480beb3d98dcb027a5bfca34428cdd0715b3a0a8c43ee54555e913f51a');
  for(const [width,height] of [[160,120],[320,240]]) {
    const y=videoLuma(marker,width,height),stride=width+16,padded=new Uint8Array(stride*height).fill(99);
    for(let row=0;row<height;row++) for(let x=0;x<width;x++){const value=y[row*width+x]!;padded[row*stride+x]=value<100?value+20:value>160?value-20:value;}
    assert.deepEqual(decodeVideoMarker(padded,width,height,stride),marker);
  }
});
test('corrupt cells, digest, orientation, unsafe time and partial planes fail', () => {
  const y=videoLuma(marker);y.fill(128);assert.throws(()=>decodeVideoMarker(y,160,120));
  const flipped=videoLuma(marker);for(let row=0;row<6;row++)flipped.fill(235,row*160+8,row*160+14);
  assert.throws(()=>decodeVideoMarker(flipped,160,120));
  assert.throws(()=>decodeVideoMarker(new Uint8Array(1),160,120));
  assert.throws(()=>videoIdentity({...marker,sourceTimeUs:Number.MAX_SAFE_INTEGER+1}));
  assert.throws(()=>videoIdentity({...marker,epoch:-1}));
});
test('content-free requires complete full planes, chroma and different source geometry', () => {
  const blank=new Uint8Array(96).fill(128);blank.fill(16,0,64);
  assert.equal(inspectVideoImage(blank,8,8).kind,'contentFree');
  blank[63]=21;assert.equal(inspectVideoImage(blank,8,8).kind,'ambiguous');blank[63]=16;
  blank[95]=150;assert.equal(inspectVideoImage(blank,8,8).kind,'ambiguous');blank[95]=128;
  assert.equal(inspectVideoImage(blank.subarray(0,95),8,8).kind,'ambiguous');
  assert.equal(inspectVideoImage(new Uint8Array(160*120*3/2).fill(16),160,120).kind,'ambiguous');
  const real=new Uint8Array(160*120*3/2).fill(128);real.set(videoLuma(marker));
  assert.equal(inspectVideoImage(real,160,120).kind,'source');real.fill(128,0,160*8);
  assert.equal(inspectVideoImage(real,160,120).kind,'ambiguous');
});

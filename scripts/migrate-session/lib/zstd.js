/**
 * zstd 帧级读写：DSH 会话日志的物理格式契约集中在这里。
 *
 * 背景（两处踩过的坑，勿删校验）：
 *  1. v0 布局为「每行独立成 zstd frame」，且**首个 frame 必须正好是 header 那一行**。
 *     用 zstd 整体重压缩会把数万帧合并成一帧，DSH 读取时报
 *     `corrupt Zstandard session log: first frame is not exactly one header line`。
 *  2. 因此「改 header」只能重建首帧，其余字节原样拼接，不能整体解压再压。
 *
 * 本模块不依赖 DSH 运行时，只用 node:zlib，可独立单测。
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { zstdCompressSync, zstdDecompressSync } from 'node:zlib';

/** zstd 魔数（帧起始标记） */
export const ZSTD_MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);

/** 统计文件中的 zstd frame 个数（按魔数出现次数） */
export function countFrames(buf) {
  let n = 0, pos = 0;
  while (true) {
    const i = buf.indexOf(ZSTD_MAGIC, pos);
    if (i < 0) break;
    n++; pos = i + 4;
  }
  return n;
}

/** 定位第二个 frame 的偏移（即第一个 frame 的结束位置）；单帧文件返回 -1 */
export function secondFrameOffset(buf) {
  return buf.indexOf(ZSTD_MAGIC, 1);
}

/** 把一行文本压成独立 frame */
export function frameLine(text) {
  return zstdCompressSync(Buffer.from(String(text) + '\n', 'utf8'));
}

/**
 * 解析 zstd 会话日志的 header。
 * @returns {{ head: object, frameCount: number, firstFrameBytes: number, restBytes: number }}
 * @throws 首帧不是恰好一行 header 时抛错（附排查提示）
 */
export function readHeader(path) {
  const buf = readFileSync(path);
  const off = secondFrameOffset(buf);
  const firstFrame = off > 0 ? buf.subarray(0, off) : buf;
  const rest = off > 0 ? buf.subarray(off) : Buffer.alloc(0);

  const text = zstdDecompressSync(firstFrame).toString('utf8');
  const nl = (text.match(/\n/g) || []).length;
  if (nl !== 1 || !text.endsWith('\n')) {
    throw new Error(
      `首帧不是恰好一行 header（换行数=${nl}）。\n` +
      `  这是 zstd 整体重压缩导致的多帧合并；须只重建首帧、其余字节原样保留。`
    );
  }
  const head = JSON.parse(text.trim());
  return { head, frameCount: countFrames(buf), firstFrameBytes: firstFrame.length, restBytes: rest.length };
}

/**
 * 只重建首帧：替换 header 的某些字段，其余 frame 字节原样保留。
 * @param {string} src 源文件
 * @param {string} dst 目标文件
 * @param {object} patch 要合并进 header 的字段
 * @returns {{ before: object, after: object, firstFrameBytes: [number, number], restBytes: number }}
 */
export function rewriteHeader(src, dst, patch) {
  const buf = readFileSync(src);
  const off = secondFrameOffset(buf);
  if (off <= 0) throw new Error('未找到第二个 frame（非多帧布局，无法安全重建）');
  const firstFrame = buf.subarray(0, off);
  const rest = buf.subarray(off);

  const text = zstdDecompressSync(firstFrame).toString('utf8');
  const lines = text.split('\n');
  if (lines.length < 2 || lines[1] !== '') throw new Error('首帧不是单行');
  const before = JSON.parse(lines[0]);
  const after = { ...before, ...patch };

  const newFrame = frameLine(JSON.stringify(after));
  writeFileSync(dst, Buffer.concat([newFrame, rest]));
  return {
    before, after,
    firstFrameBytes: [firstFrame.length, newFrame.length],
    restBytes: rest.length,
  };
}

/**
 * 明文 JSONL → zstd（首行单独一帧，其余每行各一帧）。
 * DSH 的 compression 配置决定物理编码；目标实例为 zstd 时必须转码。
 * @returns {{ lines: number, frames: number }}
 */
export function plaintextToZstd(src, dst) {
  const text = readFileSync(src, 'utf8');
  const lines = text.split('\n');
  if (lines.length && lines[lines.length - 1] === '') lines.pop();
  if (!lines.length) throw new Error('空文件');

  const head = JSON.parse(lines[0]);
  if (head.type !== 'session') throw new Error('首行不是 session header');

  const frames = [frameLine(lines[0])];
  for (let i = 1; i < lines.length; i++) {
    if (lines[i] === '') continue;
    frames.push(frameLine(lines[i]));
  }
  writeFileSync(dst, Buffer.concat(frames));
  return { lines: lines.length, frames: frames.length };
}

/** 读会话 header（自动识别 zstd / 明文） */
export function readHeaderAny(path) {
  if (path.endsWith('.zstd')) {
    const { head, frameCount } = readHeader(path);
    return { head, frameCount, plaintext: false };
  }
  const text = readFileSync(path, 'utf8');
  const lines = text.split('\n').filter(Boolean);
  const head = JSON.parse(lines[0]);
  if (head.type !== 'session') throw new Error('首行不是 session header');
  return { head, frameCount: lines.length, plaintext: true, lines: lines.length };
}

/** 是否明文 JSONL（非 .zstd 且首字节为 '{'） */
export function isPlaintext(path) {
  if (path.endsWith('.zstd')) return false;
  const b = readFileSync(path, { encoding: null, flag: 'r' });
  return b.length > 0 && b[0] === 0x7b;
}

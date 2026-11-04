import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, statSync } from 'node:fs';
import { resolve } from 'node:path';

const output = new URL('../dist/', import.meta.url);
const tokens = JSON.parse(readFileSync(new URL('../../design/darkroom_instrument_tokens_v3.json', import.meta.url), 'utf8'));
const pages = [
  { file: 'index.html', language: 'en', title: 'A darkroom. Of your own.', canonical: 'https://rankangkang.github.io/phosdeck/', download: 'Download preview' },
  { file: 'zh/index.html', language: 'zh-CN', title: '你的照片， 你的暗房。', canonical: 'https://rankangkang.github.io/phosdeck/zh/', download: '下载预览版' },
];

for (const page of pages) {
  const html = readFileSync(new URL(page.file, output), 'utf8');

  test(`${page.language}: static page, locale, and default theme`, () => {
    assert.match(html, new RegExp(`<html[^>]+lang="${page.language}"[^>]+data-theme="graphite"`));
    assert.equal((html.match(/<h1\b/g) ?? []).length, 1);
    const heading = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/)[1].replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
    assert.equal(heading, page.title);
    assert.ok(html.includes(`rel="canonical" href="${page.canonical}"`));
    assert.match(html, /hreflang="en"/);
    assert.match(html, /hreflang="zh-CN"/);
    assert.match(html, /hreflang="x-default"/);
    assert.equal((html.match(/<article\b[^>]*\bdata-workflow-panel/g) ?? []).length, 3);
    assert.equal((html.match(/<details>/g) ?? []).length, 4);
    const primary = html.match(/<a\b[^>]*class="[^"]*\bkey--primary\b[^"]*"[^>]*>[^<]*/)?.[0];
    assert.ok(primary?.includes('href="https://github.com/rankangkang/phosdeck/releases"'));
    assert.ok(primary?.endsWith(page.download));
    assert.ok(html.includes('synthetic test image') || html.includes('合成测试图'));
  });

  test(`${page.language}: anchors and all local assets resolve under the Pages base path`, () => {
    const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1]);
    assert.equal(new Set(ids).size, ids.length, 'duplicate element ID');
    for (const [, attribute, value] of html.matchAll(/\b(href|src|srcset)="([^"]+)"/g)) {
      const urls = attribute === 'srcset' ? value.split(',').map((part) => part.trim().split(/\s+/)[0]) : [value];
      for (const url of urls) {
        if (url.startsWith('#')) {
          assert.ok(ids.includes(url.slice(1)), `missing anchor: ${url}`);
        } else if (url.startsWith('/')) {
          assert.ok(url.startsWith('/phosdeck/'), `missing Pages prefix: ${url}`);
          const relative = decodeURIComponent(url.slice('/phosdeck/'.length)).split(/[?#]/)[0];
          let path = resolve(output.pathname, relative);
          if (existsSync(path) && statSync(path).isDirectory()) path = resolve(path, 'index.html');
          assert.ok(existsSync(path), `missing generated file: ${url}`);
        }
      }
    }
    for (const [, id] of html.matchAll(/\baria-(?:controls|labelledby)="([^"]+)"/g)) {
      assert.ok(ids.includes(id), `missing accessible target: ${id}`);
    }
  });

  test(`${page.language}: theme values come from the native token file`, () => {
    for (const [theme, { colors }] of Object.entries(tokens.themes)) {
      assert.ok(html.includes(`[data-theme="${theme}"]`));
      for (const [name, value] of Object.entries(colors)) {
        assert.ok(html.includes(`--${name.replaceAll('.', '-')}:${value};`), `missing native token: ${theme}/${name}`);
      }
    }
  });

  test(`${page.language}: direct GitHub access and one accessible page shortcut`, () => {
    const header = html.match(/<header\b[^>]*>([\s\S]*?)<\/header>/)[1];
    assert.ok(header.includes('href="https://github.com/rankangkang/phosdeck"'));
    assert.match(header, /<button[^>]*role="switch"[^>]*aria-checked="false"[^>]*data-toggle-theme/);
    assert.deepEqual([...html.matchAll(/\bhref="(#[^"]*)"/g)].map((m) => m[1]), ['#main']);
    assert.ok(!html.includes('data-theme-choice'), 'theme controls should have one owner');
  });
}

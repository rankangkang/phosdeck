import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://rankangkang.github.io',
  base: '/phosdeck',
  output: 'static',
  trailingSlash: 'always',
  devToolbar: { enabled: false },
});

import tokens from '../../design/darkroom_instrument_tokens_v3.json';

// The native token file remains the source of truth; only web sizing is adapted.
const variables = (values: Record<string, string | number>, unit = '') =>
  Object.entries(values).map(([key, value]) => `--${key.replaceAll('.', '-')}:${value}${unit};`).join('');

export const themeCSS = Object.entries(tokens.themes).map(([name, theme]) =>
  `[data-theme="${name}"]{${variables(theme.colors)}}`,
).join('\n') + `:root{${variables(Object.fromEntries(Object.entries(tokens.spacing).map(([k, v]) => [`space-${k}`, v])), 'px')}${variables(Object.fromEntries(Object.entries(tokens.motion).filter(([, v]) => typeof v === 'number').map(([k, v]) => [`motion-${k}`, v as number])), 'ms')}${variables(Object.fromEntries(Object.entries(tokens.components.toggle).filter(([, v]) => typeof v === 'number').map(([k, v]) => [`switch-${k}`, v as number])), 'px')}--radius-key:${tokens.radius.key}px;--radius-panel:${tokens.radius.structuralPanel}px;--header-switch-scale:${32 / tokens.components.toggle.height};}`;

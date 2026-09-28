export const wissaUI2 = {
  color: {
    navy: '#071A33',
    navyDeep: '#041225',
    blue: '#0866E5',
    blueStrong: '#0557C9',
    cyan: '#1CCBFF',
    cyanBright: '#42DEFF',
    success: '#20B26B',
    warning: '#F5A524',
    danger: '#E34D59',
    violet: '#8C6CFF',
  },
  radius: { sm: 12, md: 16, lg: 22, xl: 28, pill: 999 },
  spacing: { 1: 4, 2: 8, 3: 12, 4: 16, 5: 20, 6: 24, 8: 32, 10: 40 },
  motion: { fast: 140, normal: 220, slow: 360 },
  layout: { sidebar: 272, contentMax: 1600, header: 78 },
} as const;

export type WissaUI2Theme = 'light' | 'dark';
export type WissaUI2Status = 'success' | 'warning' | 'danger' | 'info' | 'neutral';

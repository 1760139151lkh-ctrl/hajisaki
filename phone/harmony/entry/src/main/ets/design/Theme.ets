// 公主的小客厅：与 studio/src/style.css、iPad TheaterPalette 同步。
// 夜为“月下”（午夜梅紫与烛光古金），昼为“春日”（瓷白腮红与玫瑰）。
export class Palette {
  background: string = '#17131F';
  surface: string = '#211B2B';
  raised: string = '#2B2337';
  text: string = '#F3E9E4';
  secondary: string = '#BBADB7';
  accent: string = '#EDA3B9';
  glow: string = '#B6C4F1';
  gold: string = '#E3C48E';
  border: string = '#3A3046';
  danger: string = '#C24864';
  light: boolean = false;
}

export function palette(theme: string, time: number = Date.now()): Palette {
  const hour = new Date(time).getHours();
  const light = theme === 'day' || (theme === 'auto' && hour >= 7 && hour < 19);
  const value = new Palette();
  if (light) {
    value.background = '#FBF4F1'; value.surface = '#F5E8E6'; value.raised = '#FFFCFA';
    value.text = '#2E2638'; value.secondary = '#6C5F75'; value.accent = '#B8506F';
    value.glow = '#4F68AE'; value.gold = '#A8844C'; value.border = '#EBDAD6'; value.light = true;
  }
  return value;
}

export class Palette {
  background: string = '#05070F';
  surface: string = '#0B1021';
  raised: string = '#111A30';
  text: string = '#EDF1FA';
  secondary: string = '#98A4C0';
  accent: string = '#8CB4F5';
  glow: string = '#B5CEFA';
  gold: string = '#D4AF67';
  border: string = '#24314A';
  danger: string = '#C24864';
  light: boolean = false;
}

export function palette(theme: string, time: number = Date.now()): Palette {
  const hour = new Date(time).getHours();
  const light = theme === 'day' || (theme === 'auto' && hour >= 7 && hour < 19);
  const value = new Palette();
  if (light) {
    value.background = '#F6F7FB'; value.surface = '#EEF2FA'; value.raised = '#FFFFFF';
    value.text = '#1B233A'; value.secondary = '#53627F'; value.accent = '#385B92';
    value.glow = '#4068A6'; value.gold = '#89682D'; value.border = '#D4DEEC'; value.light = true;
  }
  return value;
}

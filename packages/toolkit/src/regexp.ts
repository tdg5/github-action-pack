// Source: https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Regular_Expressions
export function escapePattern(pattern: string): string {
  return pattern.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

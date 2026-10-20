// What the kid screens call each fund (Dad, 2026-10-19, from the beta). The short name ("TSX")
// read like the index on the news, whose points are nothing like the fund's price, so the screens
// say which real fund it follows: "TSX fund (XIC)". Each label is also a glossary term, so
// <Explain term={fundLabel(id)} /> shows why the price isn't the index's points.
// Notices and history lines are written by the database and keep the short name.

const FUNDS: Record<string, { label: string; symbol: string }> = {
  dow: { label: 'Dow Jones fund (DIA)', symbol: 'DIA' },
  nasdaq100: { label: 'Nasdaq-100 fund (QQQ)', symbol: 'QQQ' },
  tsx: { label: 'TSX fund (XIC)', symbol: 'XIC' },
};

/** The fund's name on a kid screen, for example "TSX fund (XIC)". */
export function fundLabel(id: string | null | undefined, name?: string | null): string {
  return (id && FUNDS[id]?.label) || (name ? `${name} fund` : 'a fund');
}

/** The real fund it follows, for example "XIC" (null for an unknown fund). */
export function fundSymbol(id: string | null | undefined): string | null {
  return (id && FUNDS[id]?.symbol) || null;
}

/** "Price of one unit of XIC" (Graphs, a fund's price line). */
export function unitPriceLine(id: string | null | undefined): string | null {
  const s = fundSymbol(id);
  return s ? `Price of one unit of ${s}` : null;
}

/** A fund's label, or the name as it is for anything else (Savings, GICs). */
export function optionName(key: string, name: string): string {
  return FUNDS[key]?.label ?? name;
}
